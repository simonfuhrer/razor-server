require 'sinatra'

require_relative './lib/razor/initialize'
require_relative './lib/razor'

class Razor::App < Sinatra::Base
  configure do
    # FIXME: This turns off template caching alltogether since I am not
    # sure that the caching won't interfere with how we lookup
    # templates. Need to investigate whether this really is an issue, and
    # hopefully can enable template caching (which does not happen in
    # development mode anyway)
    set :reload_templates, true
  end

  before do
    # We serve static files from /svc/repo and will therefore let that
    # handler determine the most appropriate content type
    pass if request.path_info.start_with?("/svc/repo")
    # Set our content type: like many people, we simply don't negotiate.
    content_type 'application/json'
  end

  before %r'/api($|/)'i do
    # Ensure that we can happily talk application/json with the client.
    # At least this way we tell you when we are going to be mean.
    #
    # This should read `request.accept?(application/json)`, but
    # unfortunately for us, https://github.com/sinatra/sinatra/issues/731
    # --daniel 2013-06-26
    request.preferred_type('application/json') or
      halt [406, {"error" => "only application/json content is available"}.to_json]
  end

  #
  # Server/node API
  #
  helpers do
    def error(status, body = {})
      halt status, body.to_json
    end

    def json_body
      if request.content_type =~ %r'application/json'i
        return JSON.parse(request.body.read)
      else
        error 415, :error => "only application/json is accepted here"
      end
    rescue => e
      error 415, :error => "unable to parse JSON", :details => e.to_s
    end

    def compose_url(*parts)
      escaped = '/' + parts.compact.map{|x|URI::escape(x.to_s)}.join('/')
      url escaped.gsub(%r'//+', '/')
    end

    def file_url(template, raw = false)
      if raw
        url "/svc/file/#{@node.id}/raw/#{URI::escape(template)}"
      else
        url "/svc/file/#{@node.id}/#{URI::escape(template)}"
      end
    end

    def unc_path
      Razor.config['unc_path']
    end

    def log_url(msg, severity=:info)
      q = ::URI::encode_www_form(:msg => msg, :severity => severity)
      url "/svc/log/#{@node.id}?#{q}"
    end

    def store_url(vars)
      # We intentionally do not URL escape here; users need to be able to
      # say '$node_ip' in the URL vars and have the shell interpolate that.
      q = vars.map { |k,v| "#{k}=#{v}" }.join("&")
      url "/svc/store/#{@node.id}?#{q}"
    end

    def broker_install_url
      url "/svc/broker/#{@node.id}/install"
    end

    def node_url
      url "/api/nodes/#{@node.id}"
    end

    # Produce a URL to +path+ within the current repo; this is done by
    # appending +path+ to the repo's URL. Note that that this is simply a
    # string append, and does not do proper URI concatenation in the sense
    # of +URI::join+
    def repo_url(path = "")
      if @repo.url
        url = URI::parse(@repo.url)
        url.path = (url.path + "/" + path).gsub(%r'//+', '/')
        url.to_s
      else
        compose_url "/svc/repo", @repo.name, path
      end
    end

    def repo_file(path = "")
      root = File.expand_path(@repo.name, Razor.config['repo_store_root'])
      if path.empty?
        root
      else
        TorqueBox::Logger.new.info("repo_file(#{path.inspect})")
        Razor::Data::Repo.find_file_ignoring_case(root, path)
      end
    end

    # @todo lutter 2013-08-21: all the installers need to be adapted to do
    # a 'curl <%= stage_done_url %> to signal that they are ready to
    # proceed to the next stage in the boot sequence
    def stage_done_url(name = "")
      url "/svc/stage-done/#{@node.id}?name=#{name}"
    end

    def config
      @config ||= Razor::Util::TemplateConfig.new
    end

    # Construct the URL that our iPXE bootstrap script should use to call
    # /svc/boot. Attempt to include as much information about the node as
    # iPXE can give us
    def ipxe_boot_url
      vars = {}
      (1..@nic_max).each do |index|
        net_id = "net#{index - 1}"
        vars[net_id] = "${#{net_id}/mac:hexhyp}"
      end
      ["dhcp_mac", "serial", "asset", "uuid"].each { |k| vars[k] = "${#{k}}" }
      q = vars.map { |k,v| "#{k}=#{v}" }.join("&")
      url "/svc/boot?#{q}"
    end

    # Information to include on the microkernel kernel command line that
    # the MK agent uses to identify the node
    def microkernel_kernel_args
      "razor.register=#{url("/svc/checkin/#{@node.id}")} #{Razor.config["microkernel.kernel_args"]}"
    end
  end

  # Client API helpers
  helpers Razor::View

  # Error handlers for node API
  error Razor::TemplateNotFoundError do
    status [404, env["sinatra.error"].message]
  end

  error Razor::Util::ConfigAccessProhibited do
    status [500, env["sinatra.error"].message]
  end

  # Convenience for /svc/boot and /svc/file
  def render_template(name)
    locals = { :installer => @installer, :node => @node, :repo => @repo }
    content_type 'text/plain'
    template, opts = @installer.find_template(name)
    erb template, opts.merge(locals: locals, layout: false)
  end

  # FIXME: We report various errors without a body. We need to include both
  # human-readable error indications and some sort of machine-usable error
  # messages, possibly along the lines of
  # http://www.mnot.net/blog/2013/05/15/http_problem

  # API for MK

  # Receive the current facts from a node running the Microkernel, and update
  # our internal records. This also returns, synchronously, the next action
  # that the MK client should perform.
  #
  # The request should be POSTed, and contain `application/json` content.
  # The object MUST be a map, and MUST contain the following fields:
  #
  # * `hw_id`: the "hardware" ID value for the machine; this is a
  #   transformation of Ethernet-ish looking interface MAC values as
  #   discovered by the Linux MK client.
  # * `facts`: a map of fact names to fact values.
  #
  # @todo danielp 2013-07-29: ...and we don't, yet, actually return anything
  # meaningful.  In practice, I strongly suspect that we should be splitting
  # out "do this" from "register me", as this presently forbids multiple
  # actions being queued for the MK, and so on.  (At least, without inventing
  # a custom bundling format for them...)
  #
  # @todo lutter 2013-09-04: this code assumes that we can tell an MK its
  # unique checkin URL, which is true for MK's that boot through
  # +installers/microkernel/boot.erb+. If we need to allow booting of MK's
  # by other means, we'd need to convince facter to send us the same
  # hw_info that iPXE does and identify the node via +Node.lookup+
  post '/svc/checkin/:id' do
    TorqueBox::Logger.new.info("checkin by node #{params[:id]}")
    return 400 if request.content_type != 'application/json'
    begin
      json = JSON::parse(request.body.read)
    rescue JSON::ParserError
      return 400
    end
    return 400 unless json['facts']
    begin
      node = Razor::Data::Node[params["id"]] or return 404
      node.checkin(json).to_json
    rescue Razor::Matcher::RuleEvaluationError => e
      Razor.logger.error("during checkin of #{node.name}: " + e.message)
      { :action => :none }.to_json
    end
  end

  # Take a hardware ID bundle, match it to a node, and return the unique
  # node ID.  This is for the benefit of the Windows installer client, which
  # can't take any dynamic content from the boot loader, and potentially any
  # future installer (or other utility) which can identify the hardware
  # details, but not the node ID, to get that ID.
  #
  # GET the URL, with `netN` keys for your network cards, and optionally a
  # `dhcp_mac`, serial, asset, and uuid DMI data arguments.  These are used
  # for the same node matching as done in the `/svc/boot` process.
  #
  # The return value is a JSON object with one key, `id`, containing the
  # unique node ID used for further transactions.
  #
  # Typically this will then be used to access `/srv/file/$node_id/...`
  # content from the service.
  get '/svc/nodeid' do
    return 400 if params.empty?
    begin
      if node = Razor::Data::Node.lookup(params)
        TorqueBox::Logger.new.info("/svc/nodeid: #{params.inspect} mapped to #{node.id}")
        { :id => node.id }.to_json
      else
        TorqueBox::Logger.new.info("/svc/nodeid: #{params.inspect} not found")
        404
      end
    rescue Razor::Data::DuplicateNodeError => e
      TorqueBox::Logger.new.info("/svc/nodeid: #{params.inspect} multiple nodes")
      e.log_to_nodes!
      Razor.logger.error(e.message)
      return 400
    end
  end

  get '/svc/boot' do
    begin
      @node = Razor::Data::Node.lookup(params)
    rescue Razor::Data::DuplicateNodeError => e
      e.log_to_nodes!
      Razor.logger.error(e.message)
      return 400
    end

    @installer = @node.installer

    if @node.policy
      @repo = @node.policy.repo
    else
      # @todo lutter 2013-08-19: We have no policy on the node, and will
      # therefore boot into the MK. This is a gigantic hack; all we need is
      # an repo with the right name so that the repo_url helper generates
      # links to the microkernel directory in the repo store.
      #
      # We do not have API support yet to set up MK's, and users therefore
      # have to put the kernel and initrd into the microkernel/ directory
      # in their repo store manually for things to work.
      @repo = Razor::Data::Repo.new(:name => "microkernel",
                                    :iso_url => "file:///dev/null")
    end
    template = @installer.boot_template(@node)

    @node.log_append(:event => :boot, :installer => @installer.name,
                     :template => template, :repo => @repo.name)
    @node.save
    render_template(template)
  end

  get '/svc/file/:node_id/raw/:filename' do
    TorqueBox::Logger.new.info("#{params[:node_id]}: raw file #{params[:filename]}")

    halt 404 if params[:filename] =~ /\.erb$/i # no raw template access

    @node = Razor::Data::Node[params[:node_id]]
    halt 404 unless @node

    halt 409 unless @node.policy

    @installer = @node.installer
    @repo = @node.policy.repo

    @node.log_append(:event => :get_raw_file, :template => params[:filename],
                     :url => request.url)

    fpath = @installer.find_file(params[:filename]) or halt 404
    content_type nil
    send_file fpath, :disposition => nil
  end

  get '/svc/file/:node_id/:template' do
    TorqueBox::Logger.new.info("request from #{params[:node_id]} for #{params[:template]}")
    @node = Razor::Data::Node[params[:node_id]]
    halt 404 unless @node

    halt 409 unless @node.policy

    @installer = @node.installer
    @repo = @node.policy.repo

    @node.log_append(:event => :get_file, :template => params[:template],
                     :url => request.url)

    render_template(params[:template])
  end

  # If we support more than just the `install` script in brokers, this should
  # expand to take the template identifier like the file service does.
  get '/svc/broker/:node_id/install' do
    node = Razor::Data::Node[params[:node_id]]
    halt 404 unless node
    halt 409 unless node.policy

    content_type 'text/plain'   # @todo danielp 2013-09-24: ...or?
    node.policy.broker.install_script_for(node)
  end

  get '/svc/log/:node_id' do
    node = Razor::Data::Node[params[:node_id]]
    halt 404 unless node

    node.log_append(:event => :node_log,
                    :msg=> params[:msg], :severity => params[:severity])
    node.save
    [204, {}]
  end

  get '/svc/store/:node_id' do
    node = Razor::Data::Node[params[:node_id]]
    halt 404 unless node
    halt 400 unless params[:ip]

    # We only allow setting the ip address for now
    node.ip_address = params[:ip]
    node.log_append(:event => :store, :vars => { :ip => params[:ip] })
    node.save
    [204, {}]
  end

  get '/svc/stage-done/:node_id' do
    Razor::Data::Node.stage_done(params[:node_id], params[:name])
    [204, {}]
  end

  get '/svc/repo/*' do |path|
    root = File.expand_path(Razor.config['repo_store_root'])

    # Unfortunately, we face some complexities.  The ISO9660 format only
    # supports upper-case filenames, but some installers assume they will be
    # mapped to lower-case automatically.  If that doesn't happen, we can
    # hit trouble.  So, to make this more user friendly we look for a
    # case-insensitive match on the file.
    fpath = Razor::Data::Repo.find_file_ignoring_case(root, path)
    if fpath and fpath.start_with?(root) and File.file?(fpath)
      content_type nil
      send_file fpath, :disposition => nil
    else
      [404, { :error => "File #{path} not found" }.to_json ]
    end
  end

  # The collections we advertise in the API
  #
  # @todo danielp 2013-06-26: this should be some sort of discovery, not a
  # hand-coded list, but ... it will do, for now.
  COLLECTIONS = [:brokers, :repos, :tags, :policies, :nodes]

  #
  # The main entry point for the public/management API
  #
  get '/api' do
    # `rel` is the relationship; by RFC5988 (Web Linking) -- which is
    # designed for HTTP, but we abuse in JSON -- this is the closest we can
    # get to a conformant identifier for a custom relationship type, and
    # since we expect to consume one per command to avoid clients just
    # knowing the URL, we get this nastiness.  At least we can turn it into
    # something useful by putting documentation about how to use the
    # command or query interface behind it, I guess. --daniel 2013-06-26
    {
      "commands" => @@commands.dup.map { |c| c.update("id" => url(c["id"])) },
      "collections" => COLLECTIONS.map do |coll|
        { "name" => coll, "rel" => spec_url("/collections/#{coll}"),
          "id" => url("/api/collections/#{coll}")}
      end
    }.to_json
  end

  # Command handling and query API: this provides navigation data to allow
  # clients to discover which URL namespace content is available, and access
  # the query and command operations they desire.

  @@commands = []

  # A helper to wire up new commands and enter them into the list of
  # commands we return from /api. The actual command handler will live
  # at '/api/commands/#{name}'. The block will be passed the body of the
  # request, already parsed into a Ruby object.
  #
  # Any exception the block may throw will lead to a response with status
  # 400. The block should return an object whose +view_object_reference+
  # will be returned in the response together with status code 202
  def self.command(name, &block)
    name = name.to_s.tr("_", "-")
    path = "/api/commands/#{name}"
    # List this command when clients ask for /api
    @@commands << {
      "name" => name,
      "rel" => Razor::View::spec_url("commands", name),
      "id" => path
    }

    # Handler for the command
    post path do
      data = json_body
      data.is_a?(Hash) or error 415, :error => "body must be a JSON object"
      # @todo lutter 2013-08-18: tr("_", "-") in all keys in data
      # (recursively) so that we do not use '_' in the API (i.e., this also
      # requires fixing up view.rb)
      begin
        result = instance_exec(data, &block)
      rescue => e
        error 400, :details => e.to_s
      end
      result = view_object_reference(result) unless result.is_a?(Hash)
      [202, result.to_json]
    end
  end

  command :create_repo do |data|
    # Create our shiny new repo.  This will implicitly, thanks to saving
    # changes, trigger our loading saga to begin.  (Which takes place in the
    # same transactional context, ensuring we don't send a message to our
    # background workers without also committing this data to our database.)
    data["iso_url"] = data.delete("iso-url")
    repo = Razor::Data::Repo.new(data).save.freeze

    # Finally, return the state (started, not complete) and the URL for the
    # final repo to our poor caller, so they can watch progress happen.
    repo
  end

  command :delete_repo do |data|
    data["name"] or error 400,
      :error => "Supply 'name' to indicate which repo to delete"
    if repo = Razor::Data::Repo[:name => data['name']]
      repo.destroy
      action = "repo destroyed"
    else
      action = "no changes; repo #{data["name"]} does not exist"
    end
    { :result => action }
  end

  command :delete_node do |data|
    data['name'] or error 400,
      :error => "Supply 'name' to indicate which node to delete"
    if node = Razor::Data::Node.find_by_name(data['name'])
      node.destroy
      action = "node destroyed"
    else
      action = "no changes; node #{data['name']} does not exist"
    end
    { :result => action }
  end

  command :unbind_node do |data|
    data['name'] or error 400,
      :error => "Supply 'name' to indicate which node to unbind"
    if node = Razor::Data::Node.find_by_name(data['name'])
      if node.policy
        policy_name = node.policy.name
        node.log_append(:event => :unbind, :policy => policy_name)
        node.policy = nil
        node.save
        action = "node unbound from #{policy_name}"
      else
        action = "no changes; node #{data['name']} is not bound"
      end
    else
      action = "no changes; node #{data['name']} does not exist"
    end
    { :result => action }
  end

  command :create_installer do |data|
    # If boot_seq is not a Hash, the model validation for installers
    # will catch that, and will make saving the installer fail
    if (boot_seq = data["boot_seq"]).is_a?(Hash)
      # JSON serializes integers as strings, undo that
      boot_seq.keys.select { |k| k.is_a?(String) and k =~ /^[0-9]+$/ }.
        each { |k| boot_seq[k.to_i] = boot_seq.delete(k) }
    end

    Razor::Data::Installer.new(data).save.freeze
  end

  command :create_tag do |data|
    Razor::Data::Tag.find_or_create_with_rule(data)
  end

  command :create_broker do |data|
    if type = data.delete("broker-type")
      begin
        data["broker_type"] = Razor::BrokerType.find(type)
      rescue Razor::BrokerTypeNotFoundError
        halt [400, "Broker type '#{type}' not found"]
      rescue => e
        halt 400, e.to_s
      end
    end

    Razor::Data::Broker.new(data).save
  end

  command :create_policy do |data|
    tags = (data.delete("tags") || []).map do |t|
      Razor::Data::Tag.find_or_create_with_rule(t)
    end

    if data["repo"]
      name = data["repo"]["name"] or
        error 400, :error => "The repo reference must have a 'name'"
      data["repo"] = Razor::Data::Repo[:name => name] or
        error 400, :error => "Repo '#{name}' not found"
    end

    if data["broker"]
      name = data["broker"]["name"] or
        halt [400, "The broker reference must have a 'name'"]
      data["broker"] = Razor::Data::Broker[:name => name] or
        halt [400, "Broker '#{name}' not found"]
    end

    if data["installer"]
      data["installer_name"] = data.delete("installer")["name"]
    end
    data["hostname_pattern"] = data.delete("hostname")

    policy = Razor::Data::Policy.new(data).save
    tags.each { |t| policy.add_tag(t) }
    policy.save

    policy
  end

  def toggle_policy_enabled(data, enabled, verb)
    data['name'] or error 400,
      :error => "Supply 'name' to indicate which policy to #{verb}"
    policy = Razor::Data::Policy[:name => data['name']] or error 404,
      :error => "Policy #{data['name']} does not exist"
    policy.enabled = enabled
    policy.save

    { :result => "Policy #{policy.name} #{verb}d" }
  end

  command :enable_policy do |data|
    toggle_policy_enabled(data, true, 'enable')
  end

  command :disable_policy do |data|
    toggle_policy_enabled(data, false, 'disable')
  end

  #
  # Query/collections API
  #
  get '/api/collections/tags' do
    Razor::Data::Tag.all.map {|t| view_object_reference(t)}.to_json
  end

  get '/api/collections/tags/:name' do
    tag = Razor::Data::Tag[:name => params[:name]] or
      error 404, :error => "no tag matched id=#{params[:name]}"
    tag_hash(tag).to_json
  end

  get '/api/collections/brokers' do
    Razor::Data::Broker.all.map {|t| view_object_reference(t)}.to_json
  end

  get '/api/collections/brokers/:name' do
    broker = Razor::Data::Broker[:name => params[:name]] or
      halt 404, "no broker matched id=#{params[:name]}"
    broker_hash(broker).to_json
  end

  get '/api/collections/policies' do
    Razor::Data::Policy.order(:rule_number).all.map do |p|
      view_object_reference(p)
    end.to_json
  end

  get '/api/collections/policies/:name' do
    policy = Razor::Data::Policy[:name => params[:name]] or
      error 404, :error => "no policy matched id=#{params[:name]}"
    policy_hash(policy).to_json
  end

  # FIXME: Add a query to list all installers

  get '/api/collections/installers/:name' do
    begin
      installer = Razor::Installer.find(params[:name])
    rescue Razor::InstallerNotFoundError => e
      error 404, :error => "Installer #{params[:name]} does not exist",
        :details => e.to_s
    end
    installer_hash(installer).to_json
  end

  get '/api/collections/repos' do
    Razor::Data::Repo.all.map { |repo| view_object_reference(repo)}.to_json
  end

  get '/api/collections/repos/:name' do
    repo = Razor::Data::Repo[:name => params[:name]] or
      error 404, :error => "no repo matched name=#{params[:name]}"
    repo_hash(repo).to_json
  end

  get '/api/collections/nodes' do
    Razor::Data::Node.all.map {|node| view_object_reference(node) }.to_json
  end

  get '/api/collections/nodes/:name' do
    node = Razor::Data::Node.find_by_name(params[:name]) or
      error 404, :error => "no node matched name=#{params[:name]}"
    node_hash(node).to_json
  end

  get '/api/collections/nodes/:name/log' do
    # @todo lutter 2013-08-20: There are no tests for this handler
    # @todo lutter 2013-08-20: Do we need to send the log through a view ?
    node = Razor::Data::Node.find_by_name(params[:name]) or
      error 404, :error => "no node matched hw_id=#{params[:hw_id]}"
    node.log.to_json
  end

  # @todo lutter 2013-08-18: advertise this in the entrypoint; it's neither
  # a command not a collection.
  get '/api/microkernel/bootstrap' do
    params["nic_max"].nil? or params["nic_max"] =~ /\A[1-9][0-9]*\Z/ or
      error 400,
        :error => "The nic_max parameter must be an integer not starting with 0"

    # How many NICs ipxe should probe for DHCP
    @nic_max = params["nic_max"].nil? ? 4 : params["nic_max"].to_i

    @installer = Razor::Installer.mk_installer

    render_template("bootstrap")
  end
end
