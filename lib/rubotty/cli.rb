# frozen_string_literal: true

require "optparse"
require "json"

module Rubotty
  # Command line entry point, built on OptionParser from the standard library.
  # See COMMANDS and the banner in {#parse} for the full list.
  class CLI
    COMMANDS = %w[run check topology schema migrate seed feature dashboard datastore guest-portal api web
                  file-storage version].freeze

    # Tables whose rows only point at bytes, with the noun for one row of each.
    # A new Storage::ObjectStore caller belongs here too, or a transfer reports
    # clean and leaves its files behind.
    STORED_FILE_TABLES = {
      "rehosted_files" => "rehosted file",
      "guest_uploads" => "guest upload"
    }.freeze

    def self.run(argv, env: ENV, out: $stdout, err: $stderr)
      new(argv, env: env, out: out, err: err).run
    end

    def initialize(argv, env: ENV, out: $stdout, err: $stderr)
      @argv = argv.dup
      @env = env
      @out = out
      @err = err
      @options = { config: env["BRIDGE_CONFIG"] }
    end

    def run
      command = parse
      return 0 if command.nil?

      case command
      when "run" then command_run
      when "check" then command_check
      when "topology" then command_topology
      when "schema" then command_schema
      when "migrate" then command_migrate
      when "seed" then command_seed
      when "feature" then command_feature
      when "dashboard" then command_dashboard
      when "guest-portal" then command_guest_portal
      when "api" then command_api
      when "web" then command_web
      when "file-storage" then command_file_storage
      when "datastore" then command_datastore
      when "version" then command_version
      else
        @err.puts "unknown command #{command.inspect}. Try one of: #{COMMANDS.join(", ")}"
        2
      end
    rescue ControlPlane::FeatureControls::Invalid => e
      @err.puts e.message
      1
    rescue ConfigError => e
      @err.puts "Configuration is not usable:"
      @err.puts e.message
      1
    rescue StorageError, AdapterError => e
      @err.puts "Startup failed: #{e.message}"
      1
    end

    private

    def parse
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: rubotty [command] [options]\n\nCommands:\n" \
                      "    run       start the bridge\n" \
                      "    check     validate the configuration and exit\n" \
                      "    topology  print the resolved rooms and endpoints\n" \
                      "    schema    print the configuration reference\n" \
                      "    migrate   apply the control-plane migrations\n" \
                      "    seed      project the YAML config into the control plane\n" \
                      "    feature   read or edit per-community/per-room feature settings\n" \
                      "    dashboard serve the operator web dashboard\n" \
                      "    guest-portal serve the time-bounded guest chat portal\n" \
                      "    api       serve the REST admin API\n" \
                      "    web       serve the landing page, dashboard, guest portal and API on one host\n" \
                      "    file-storage serve a rehosted file's download route\n" \
                      "    datastore copy the whole datastore between backends\n" \
                      "    version   print the version\n\n" \
                      "Feature subcommands:\n" \
                      "    feature list    <community> [room]\n" \
                      "    feature enable  <community> <room|all> <feature>\n" \
                      "    feature disable <community> <room|all> <feature>\n" \
                      "    feature set     <community> <room|all> <feature> <key> <value>\n\n" \
                      "Datastore subcommands:\n" \
                      "    datastore migrate --from <spec> --to <spec> [--dry-run]\n" \
                      "      spec: sqlite:<path>, pg:<env-var-name>, pg:<postgres:// url>, " \
                      "or a bare postgres:// url\n" \
                      "    datastore export --to <path.yaml.gz> [--from <spec>]\n" \
                      "      writes a portable snapshot; --from defaults to the configured storage\n" \
                      "    datastore import --from <path.yaml.gz> [--to <spec>]\n" \
                      "      restores a snapshot into an EMPTY datastore; --to defaults to the " \
                      "configured storage\n\nOptions:"
        opts.on("-c", "--config PATH", "path to the YAML configuration " \
                                       "(optional, defaults to $BRIDGE_CONFIG)") do |value|
          @options[:config] = value
        end
        opts.on("-l", "--log-level LEVEL", "debug, info, warn, error or fatal") do |value|
          @options[:log_level] = value
        end
        opts.on("--community-slug SLUG", "control-plane community handle for seed and run " \
                                         "(default: slug of the config name, or " \
                                         "$RUBOTTY_COMMUNITY_SLUG)") do |value|
          @options[:slug] = value
        end
        opts.on("--from SPEC", "source for `datastore migrate`/`export` (a datastore spec) " \
                               "or `datastore import` (a .yaml.gz path)") do |value|
          @options[:from] = value
        end
        opts.on("--to SPEC", "target for `datastore migrate`/`import` (a datastore spec) " \
                             "or `datastore export` (a .yaml.gz path)") do |value|
          @options[:to] = value
        end
        opts.on("--dry-run", "for `datastore migrate`: report source counts without writing") do
          @options[:dry_run] = true
        end
        opts.on("-h", "--help") do
          @out.puts opts
          return nil
        end
      end
      parser.parse!(@argv)
      @argv.shift || "run"
    end

    # No repository-bundled example ships anymore, and none is required: an
    # empty config is a valid one, since accounts and topology can both live
    # entirely in the control-plane database instead (see
    # {ControlPlane::Accounts#live}). An operator who has not pointed -c or
    # $BRIDGE_CONFIG at a file is told so, on @err rather than raised, so a
    # deployment that manages everything through the dashboard boots clean.
    # Blank counts as unset too, since a copied .env.example leaves
    # BRIDGE_CONFIG= present but empty.
    def load_config
      Config::Loader.load_for_boot(@options[:config], env: @env, err: @err)
    end

    def command_run
      config = load_config
      # The bot needs the same ring buffer `api` and `web` build: without one,
      # Runtime's buffer is nil and the bot's logs route answers empty.
      log_buffer = RingBuffer.new
      logger = Log.build(level: @options[:log_level] || config.log_level, ring_buffer: log_buffer)
      Core::Runtime.new(
        config: config, logger: logger, env: @env, community_slug: @options[:slug], log_buffer: log_buffer
      ).run
      0
    end

    def command_check
      config = load_config
      # Run before storage opens: several of these probes fork a throwaway
      # child to measure what the kernel allows, and a fork taken while a
      # writable database connection is open trips sqlite3's fork safety
      # guard, which prints straight to stderr on an otherwise clean check.
      notes = host_capability_notes
      storage = build_storage(config)
      registry = live_registry(config, storage)
      topology = registry ? Core::LiveTopology.new(registry) : config.topology
      operators = registry ? Core::LiveOperators.new(registry) : config.operators
      people = registry ? Core::LivePeople.new(registry) : config.people
      @out.puts "Configuration at #{config.source} is valid."
      @out.puts config.summary(topology: topology)
      notes.concat(
        deployment_capability_notes(
          config, topology: topology, operators: operators, people: people, control_plane: !registry.nil?
        )
      )
      print_capability_notes(notes)
      0
    ensure
      storage&.close
    end

    def command_topology
      config = load_config
      storage = build_storage(config)
      registry = live_registry(config, storage)
      topology = registry ? Core::LiveTopology.new(registry) : config.topology
      topology.rooms.each do |room|
        @out.puts "room #{room.id}#{room.label == room.id ? "" : " (#{room.label})"}"
        room.endpoints.each do |endpoint|
          direction = [endpoint.receives? ? "in" : nil, endpoint.sends? ? "out" : nil].compact.join("+")
          @out.puts "  #{endpoint.id.ljust(24)} #{endpoint.adapter_name} [#{direction}] #{endpoint.settings.inspect}"
        end
      end
      0
    ensure
      storage&.close
    end

    # The control-plane Registry `check` and `topology` report against, so
    # either command is honest about a database-only deployment instead of
    # reading the static config's own accounts and rooms, empty by design once
    # the control plane holds them instead. nil for a backend with no database
    # (memory, pstore), which leaves both commands reading the static config
    # exactly as before.
    def live_registry(config, storage)
      return nil unless ControlPlane::Boot.available?(storage)

      slug = ControlPlane::Boot.slug_for(config, env: @env, override: @options[:slug])
      ControlPlane::Boot.prepare(storage: storage, config: config, slug: slug, logger: nil, env: @env)
    rescue StorageError => e
      @err.puts "Warning: control plane unavailable (#{e.message}); reporting the static config only."
      nil
    end

    def command_schema
      print_schema("(root)", Config::Definition.root_schema)
      print_schema("rooms[]", Config::Definition.room_schema)
      print_schema("rooms[].endpoints[] (core keys)", Config::Definition.endpoint_core_schema)
      print_schema("storage", Config::Definition.storage_schema)
      print_schema("behaviour", Config::Definition.behaviour_schema)
      Adapters::Registry.all.each do |name, klass|
        print_schema("accounts.<name> where adapter: #{name}", klass.account_schema)
        print_schema("rooms[].endpoints[] where adapter: #{name}", klass.endpoint_schema)
      end
      0
    end

    # Apply the control-plane migrations onto the message map's own database.
    def command_migrate
      config = load_config
      storage = build_storage(config)
      unless ControlPlane::Boot.available?(storage)
        @err.puts control_plane_unavailable_message(config)
        return 1
      end

      ControlPlane::Boot.migrate(storage: storage)
      @out.puts "Control-plane migrations applied; the schema is up to date."
      0
    ensure
      storage&.close
    end

    # Project the YAML config into the control plane. Idempotent: re-running
    # reconciles rather than duplicating.
    def command_seed
      config = load_config
      storage = build_storage(config)
      unless ControlPlane::Boot.available?(storage)
        @err.puts control_plane_unavailable_message(config)
        return 1
      end

      slug = ControlPlane::Boot.slug_for(config, env: @env, override: @options[:slug])
      ControlPlane::Boot.seed(storage: storage, config: config, slug: slug)
      @out.puts "Seeded the control plane from #{config.source} as community #{slug.inspect}."
      0
    ensure
      storage&.close
    end

    # Read or edit the per-community/per-room feature_settings that gate the
    # pipeline features. A write takes effect live, with no restart.
    def command_feature
      subcommand = @argv.shift
      config = load_config
      storage = build_storage(config)
      unless ControlPlane::Boot.available?(storage)
        @err.puts control_plane_unavailable_message(config)
        return 1
      end

      # Migrating is idempotent, so `feature` works on a freshly provisioned
      # database, though it still needs a seeded community.
      db = ControlPlane::Boot.db_of(storage)
      ControlPlane.migrate!(db)
      controls = ControlPlane::FeatureControls.new(
        models: ControlPlane.models(db), relay_claim_ttl: config.relay_claim_ttl
      )

      case subcommand
      when "list" then feature_list(controls)
      when "enable" then feature_enable(controls, enabled: true)
      when "disable" then feature_enable(controls, enabled: false)
      when "set" then feature_set(controls)
      else
        @err.puts "unknown feature subcommand #{subcommand.inspect}. " \
                  "Try one of: list, enable, disable, set."
        2
      end
    ensure
      storage&.close
    end

    def feature_list(controls)
      slug = @argv.shift
      return feature_usage("feature list <community> [room]") if slug.nil?

      community = controls.community!(slug)
      selector = @argv.shift
      entries = controls.list(community, selector: selector)
      scope_label = selector.nil? ? "all scopes" : selector.inspect
      @out.puts "feature settings for community #{community.slug.inspect} (#{scope_label}):"
      if entries.empty?
        @out.puts "  (none set; every feature runs at its code default, bridge on and the rest off)"
      else
        entries.each { |entry| @out.puts format_entry(entry) }
      end
      0
    end

    def feature_enable(controls, enabled:)
      slug, selector, feature = @argv.shift(3)
      verb = enabled ? "enable" : "disable"
      return feature_usage("feature #{verb} <community> <room|all> <feature>") if feature.nil?

      community = controls.community!(slug)
      rows = enabled ? controls.enable(community: community, selector: selector, feature: feature)
                     : controls.disable(community: community, selector: selector, feature: feature)
      @out.puts "#{enabled ? "enabled" : "disabled"} #{feature} for #{scope_summary(selector, rows)} " \
                "in community #{community.slug.inspect}."
      report_live_pickup
      0
    end

    def feature_set(controls)
      slug, selector, feature, key = @argv.shift(4)
      value = @argv.shift
      if value.nil?
        return feature_usage("feature set <community> <room|all> <feature> <key> <value>")
      end

      community = controls.community!(slug)
      rows = controls.set(community: community, selector: selector, feature: feature, key: key, value: value)
      coerced = controls.coerce_value(value, feature: feature, key: key)
      @out.puts "set #{feature}.#{key} = #{coerced.inspect} for #{scope_summary(selector, rows)} " \
                "in community #{community.slug.inspect}."
      report_live_pickup
      0
    end

    def format_entry(entry)
      scope = entry[:scope] == :community ? "all" : entry[:room_key]
      state = entry[:enabled] ? "enabled " : "disabled"
      config = entry[:config].empty? ? "" : "  #{JSON.generate(entry[:config])}"
      format("  [%-16s] %-18s %s%s", scope, entry[:feature], state, config)
    end

    # A short description of the scope a write hit, for the confirmation line.
    def scope_summary(selector, rows)
      if selector.to_s.casecmp?("all")
        "the community default"
      else
        keys = rows.map { |row| row[:room_key] }.compact
        keys.empty? ? "#{selector.inspect}" : "room #{keys.join(", ")}"
      end
    end

    def report_live_pickup
      @out.puts "The running bridge will pick this up live within about " \
                "#{ControlPlane::Watcher::DEFAULT_INTERVAL}s (no restart needed)."
    end

    def feature_usage(usage)
      @err.puts "usage: rubotty #{usage}"
      2
    end

    # Serve the operator web dashboard as its own process, over the same
    # control-plane datastore the bot uses.
    #
    # PORT sets the listen port; DASHBOARD_SECRET gates the login.
    def command_dashboard
      require "rubotty/dashboard"
      config = load_config
      # This process's own recent lines, for the Logs page's web source.
      log_buffer = RingBuffer.new
      logger = Log.build(level: @options[:log_level] || config.log_level, ring_buffer: log_buffer)
      storage = build_storage(config)
      unless ControlPlane::Boot.available?(storage)
        @err.puts control_plane_unavailable_message(config)
        return 1
      end

      db = ControlPlane::Boot.db_of(storage)
      ControlPlane.migrate!(db)
      # config is passed through so the Platforms admin page can show an
      # account's real settings and token_env name read only.
      deps = Dashboard::Deps.new(
        db: db, logger: logger, config: config, debug_logs: dashboard_debug_logs(log_buffer, logger)
      )
      app = Dashboard::App.assemble(deps: deps, env: @env, logger: logger)
      port = (@env["PORT"] || Dashboard::Server::DEFAULT_PORT).to_i
      report_web_start("Dashboard", port: port, paths: ["/"])
      Dashboard::Server.run(app, port: port, logger: logger)
      0
    ensure
      storage&.close
    end

    # Serve the guest portal as its own process, like `dashboard`.
    #
    # PORT sets the listen port. GUEST_PORTAL_RATE_MAX / GUEST_PORTAL_RATE_WINDOW
    # tune the per-session send limit.
    def command_guest_portal
      require "rubotty/guest_portal"
      config = load_config
      logger = Log.build(level: @options[:log_level] || config.log_level)
      storage = build_storage(config)
      unless ControlPlane::Boot.available?(storage)
        @err.puts control_plane_unavailable_message(config)
        return 1
      end

      db = ControlPlane::Boot.db_of(storage)
      ControlPlane.migrate!(db)
      deps = GuestPortal::Deps.new(
        db: db, logger: logger,
        rate_max: (@env["GUEST_PORTAL_RATE_MAX"] || GuestPortal::RateLimiter::DEFAULT_MAX).to_i,
        rate_window: (@env["GUEST_PORTAL_RATE_WINDOW"] || GuestPortal::RateLimiter::DEFAULT_WINDOW_SECONDS).to_i,
        retention_grace: config.guest_retention,
        file_store_path: config.file_store_path
      )
      app = GuestPortal::App.assemble(deps: deps, env: @env)
      port = (@env["PORT"] || GuestPortal::Server::DEFAULT_PORT).to_i
      report_web_start("Guest portal", port: port, paths: ["/"])
      GuestPortal::Server.run(app, port: port, logger: logger)
      0
    ensure
      storage&.close
    end

    # Serve the REST admin API as its own process, like `dashboard`.
    #
    # PORT sets the listen port. API_RATE_MAX / API_RATE_WINDOW tune the
    # per-key request budget.
    def command_api
      require "rubotty/api"
      config = load_config
      # This process's own recent lines, for the admin debug/logs endpoint's
      # source=web.
      log_buffer = RingBuffer.new
      logger = Log.build(level: @options[:log_level] || config.log_level, ring_buffer: log_buffer)
      storage = build_storage(config)
      unless ControlPlane::Boot.available?(storage)
        @err.puts control_plane_unavailable_message(config)
        return 1
      end

      db = ControlPlane::Boot.db_of(storage)
      ControlPlane.migrate!(db)
      deps = Api::Deps.new(
        db: db, logger: logger,
        rate_max: (@env["API_RATE_MAX"] || ControlPlane::ApiRateLimiter::DEFAULT_MAX).to_i,
        rate_window: (@env["API_RATE_WINDOW"] || ControlPlane::ApiRateLimiter::DEFAULT_WINDOW_SECONDS).to_i,
        log_buffer: log_buffer, bot_url: @env["RUBOTTY_BOT_INTERNAL_URL"],
        bot_secret: @env["RUBOTTY_INTERNAL_SECRET"], file_store_path: config.file_store_path, config: config,
        storage: storage
      )
      app = Api::App.assemble(deps: deps, env: @env, logger: logger)
      port = (@env["PORT"] || Api::Server::DEFAULT_PORT).to_i
      report_web_start("API", port: port, paths: ["/healthz"])
      Api::Server.run(app, port: port, logger: logger)
      0
    ensure
      storage&.close
    end

    # Serve every web surface from one process: the landing page at /, the
    # dashboard at /admin-panel, the guest portal at /guest-chat, the API at
    # /api and a rehosted file's download route at /filestorage.
    #
    # PORT sets the listen port. DASHBOARD_SECRET gates the dashboard login; set
    # GUEST_PORTAL_URL to the /guest-chat base so guest links and upload URLs
    # resolve under the mount, and RUBOTTY_FILE_STORAGE_URL to this
    # deployment's own public base so a rehosted file's download link does too.
    def command_web
      require "rubotty/web"
      config = load_config
      # This process's own recent lines, for the admin debug/logs endpoint's
      # source=web.
      log_buffer = RingBuffer.new
      logger = Log.build(level: @options[:log_level] || config.log_level, ring_buffer: log_buffer)
      storage = build_storage(config)
      unless ControlPlane::Boot.available?(storage)
        @err.puts control_plane_unavailable_message(config)
        return 1
      end

      db = ControlPlane::Boot.db_of(storage)
      ControlPlane.migrate!(db)
      dashboard_deps = Dashboard::Deps.new(
        db: db, logger: logger, config: config, debug_logs: dashboard_debug_logs(log_buffer, logger)
      )
      guest_deps = GuestPortal::Deps.new(
        db: db, logger: logger,
        rate_max: (@env["GUEST_PORTAL_RATE_MAX"] || GuestPortal::RateLimiter::DEFAULT_MAX).to_i,
        rate_window: (@env["GUEST_PORTAL_RATE_WINDOW"] || GuestPortal::RateLimiter::DEFAULT_WINDOW_SECONDS).to_i,
        retention_grace: config.guest_retention,
        file_store_path: config.file_store_path
      )
      api_deps = Api::Deps.new(
        db: db, logger: logger,
        rate_max: (@env["API_RATE_MAX"] || ControlPlane::ApiRateLimiter::DEFAULT_MAX).to_i,
        rate_window: (@env["API_RATE_WINDOW"] || ControlPlane::ApiRateLimiter::DEFAULT_WINDOW_SECONDS).to_i,
        log_buffer: log_buffer, bot_url: @env["RUBOTTY_BOT_INTERNAL_URL"],
        bot_secret: @env["RUBOTTY_INTERNAL_SECRET"], file_store_path: config.file_store_path, config: config,
        storage: storage
      )
      app = Web.assemble(
        dashboard_deps: dashboard_deps, guest_deps: guest_deps, api_deps: api_deps, env: @env, logger: logger
      )
      port = (@env["PORT"] || Web::Server::DEFAULT_PORT).to_i
      report_web_start("Web surfaces", port: port,
                                       paths: ["/", "/admin-panel", "/guest-chat", "/api", "/filestorage"])
      Web::Server.run(app, port: port, logger: logger)
      0
    ensure
      storage&.close
    end

    # Serve a rehosted file's download route as its own process, like
    # `dashboard`. Mounted at /filestorage (and the legacy /f), since a
    # download link is always built under that path wherever it resolves; see
    # {FileStorage.assemble}.
    #
    # PORT sets the listen port. Set RUBOTTY_FILE_STORAGE_URL to this
    # deployment's own public base, on this process as well as the bot's.
    def command_file_storage
      require "rubotty/file_storage"
      config = load_config
      logger = Log.build(level: @options[:log_level] || config.log_level)
      storage = build_storage(config)
      unless ControlPlane::Boot.available?(storage)
        @err.puts control_plane_unavailable_message(config)
        return 1
      end

      db = ControlPlane::Boot.db_of(storage)
      ControlPlane.migrate!(db)
      models = ControlPlane.models(db)
      rehosted_files =
        begin
          object_store = Storage::ObjectStore.new(root: config.file_store_path, logger: logger)
          object_store.ready!
          ControlPlane::RehostedFiles.new(models: models, store: object_store, logger: logger)
        rescue Storage::ObjectStore::Unavailable => e
          logger&.warn { "file store unavailable, so rehosted downloads are off: #{e.message}" }
          nil
        end
      app = FileStorage.assemble(rehosted_files: rehosted_files, logger: logger)
      port = (@env["PORT"] || FileStorage::Server::DEFAULT_PORT).to_i
      report_web_start("File storage", port: port, paths: [FileStorage::MOUNT, FileStorage::LEGACY_MOUNT])
      FileStorage::Server.run(app, port: port, logger: logger)
      0
    ensure
      storage&.close
    end

    # Copy the whole datastore between storage backends in either direction.
    # Storage::Transfer does the work; this parses the two specs and renders the
    # verification report.
    def command_datastore
      subcommand = @argv.shift
      case subcommand
      when "migrate" then datastore_migrate
      when "export" then datastore_export
      when "import" then datastore_import
      else
        @err.puts "unknown datastore subcommand #{subcommand.inspect}. Try one of: migrate, export, import."
        2
      end
    end

    def datastore_migrate
      from = @options[:from]
      to = @options[:to]
      if from.nil? || to.nil?
        @err.puts "usage: rubotty datastore migrate --from <spec> --to <spec> [--dry-run]"
        @err.puts "  spec: sqlite:<path>, pg:<env-var-name>, pg:<postgres:// url>, a bare postgres:// url, " \
                  "or mdb:<env-var-name> / mdb:<mysql:// url>"
        return 2
      end

      report = Storage::Transfer.new(
        source: Storage::Transfer.storage_config(from),
        target: Storage::Transfer.storage_config(to),
        env: @env, dry_run: @options[:dry_run]
      ).run
      print_datastore_report(report)
      report.ok? ? 0 : 1
    end

    # --to names the snapshot file to write; --from optionally names a
    # datastore spec to read instead of the configured storage, so an export
    # can run against a config file that is not the one about to boot.
    def datastore_export
      to = @options[:to]
      if to.nil?
        @err.puts "usage: rubotty datastore export --to <path.yaml.gz> [--from <spec>]"
        return 2
      end

      source = @options[:from] ? Storage::Transfer.storage_config(@options[:from]) : configured_storage_spec
      report = Storage::Snapshot.export(source: source, path: to, env: @env)
      print_snapshot_report(report, "Datastore export -> #{to}")
      warn_about_stored_files_snapshot(report)
      0
    rescue Storage::Snapshot::Invalid => e
      @err.puts "Export failed: #{e.message}"
      1
    end

    # --from names the snapshot file to read; --to optionally names a
    # datastore spec to write into instead of the configured storage.
    def datastore_import
      from = @options[:from]
      if from.nil?
        @err.puts "usage: rubotty datastore import --from <path.yaml.gz> [--to <spec>]"
        return 2
      end

      target = @options[:to] ? Storage::Transfer.storage_config(@options[:to]) : configured_storage_spec
      report = Storage::Snapshot.import(path: from, target: target, env: @env)
      print_snapshot_report(report, "Datastore import <- #{from}")
      warn_about_stored_files_snapshot(report)
      0
    rescue Storage::Snapshot::Invalid => e
      @err.puts "Import failed: #{e.message}"
      1
    end

    # The storage: block from -c/$BRIDGE_CONFIG, resolved the same way a live
    # boot would (honouring LIVE_DB_TYPE and friends), for export/import calls
    # that do not pass an explicit --from/--to spec.
    def configured_storage_spec
      Storage::Selector.live_config(load_config.storage, env: @env)
    end

    def print_snapshot_report(report, title)
      @out.puts title
      report.tables.each do |row|
        @out.puts format("  %-22s %9d", row[:table], row[:rows]) if row[:rows].positive?
      end
      @out.puts "#{report.total} rows across #{report.tables.count { |r| r[:rows].positive? }} non-empty tables."
    end

    def print_datastore_report(report)
      if report.dry_run
        @out.puts "Datastore migrate DRY RUN: #{report.source_label} -> #{report.target_label}"
        @out.puts "No data will be written. Source row counts:"
        report.rows.each { |row| @out.puts format("  %-22s %9d", row[:table], row[:source]) }
        @out.puts "#{report.total_source} rows across #{report.rows.size} tables would be copied."
        return
      end

      @out.puts "Datastore migrate: #{report.source_label} -> #{report.target_label}"
      report.rows.each do |row|
        @out.puts format("  %-22s %9d -> %-9d %s", row[:table], row[:source], row[:target],
                         row[:ok] ? "ok" : "MISMATCH")
      end
      if report.ok?
        @out.puts "Verification passed: source and target row counts match for all " \
                  "#{report.rows.size} tables (#{report.total_source} rows)."
        warn_about_stored_files(report)
      else
        tables = report.mismatches.map { |row| row[:table] }.join(", ")
        @err.puts "Verification FAILED: row-count mismatch on #{tables}. " \
                  "The source was not modified; inspect the target before using it."
      end
    end

    # A row-count match says every table came across, but the bytes behind a
    # rehosted file or a guest upload live on disk in Storage::ObjectStore and
    # this command cannot copy them.
    def warn_about_stored_files(report)
      counted = STORED_FILE_TABLES.filter_map do |table, noun|
        row = report.rows.find { |candidate| candidate[:table].to_s == table }
        count = row ? row[:source].to_i : 0
        "#{count} #{noun}#{"s" unless count == 1}" if count.positive?
      end
      return if counted.empty?

      @out.puts
      @out.puts "#{counted.join(" and ")} came across as metadata only. The bytes are in the object " \
                "store directory (#{Storage::ObjectStore::PATH_VAR}, or behaviour.file_store_path), " \
                "which this command cannot reach."
      @out.puts "Copy that directory to the new deployment as well, or every download link will 404."
    end

    # Same warning as warn_about_stored_files, against a Snapshot::Report's
    # {table:, rows:} shape instead of Transfer::Report's {table:, source:}.
    def warn_about_stored_files_snapshot(report)
      counted = STORED_FILE_TABLES.filter_map do |table, noun|
        row = report.tables.find { |candidate| candidate[:table].to_s == table }
        count = row ? row[:rows].to_i : 0
        "#{count} #{noun}#{"s" unless count == 1}" if count.positive?
      end
      return if counted.empty?

      @out.puts
      @out.puts "#{counted.join(" and ")} came across as metadata only. The bytes are in the object " \
                "store directory (#{Storage::ObjectStore::PATH_VAR}, or behaviour.file_store_path), " \
                "which this command cannot reach."
      @out.puts "Copy that directory to the new deployment as well, or every download link will 404."
    end

    def command_version
      @out.puts Rubotty::VERSION
      0
    end

    # Honour the env-driven backend selection (LIVE_DB_TYPE and the per-backend
    # connection vars) so every command targets the database the bot runs on.
    def build_storage(config)
      Storage::Selector.build_live(config.storage, env: @env, logger: nil)
    end

    def control_plane_unavailable_message(config)
      "The control plane needs a Sequel-backed store (storage.driver sqlite, pg or mdb). " \
        "storage.driver is #{config.storage_driver}, which has no database to migrate or seed."
    end

    # What the dashboard's Logs page reads: this process's own buffer, plus the
    # bot's lines over the same internal hop the deploy-drift header makes.
    def dashboard_debug_logs(log_buffer, logger)
      Dashboard::DebugLogs.new(
        log_buffer: log_buffer,
        bot_logs: Api::BotLogsClient.new(
          bot_url: @env["RUBOTTY_BOT_INTERNAL_URL"], secret: @env["RUBOTTY_INTERNAL_SECRET"], logger: logger
        )
      )
    end

    def report_web_start(name, port:, paths:)
      @out.puts "#{name} starting on port #{port}."
      @out.puts "Paths: #{paths.join(", ")}."
    end

    def print_schema(title, schema)
      @out.puts
      @out.puts title
      @out.puts "-" * title.length
      schema.fields.each_value do |field|
        flags = []
        flags << "required" if field.required
        flags << "default #{field.default.inspect}" unless field.default.nil?
        flags << "one of #{field.one_of.join(", ")}" if field.one_of
        @out.puts format("  %-26s %-9s %s", field.name, field.type, flags.join(", "))
        @out.puts "  #{" " * 36}#{field.description}" if field.description
      end
    end

    # The host-only half of {#deployment_capability_notes}: nothing here reads
    # the topology, so it runs the same regardless of a static config or a
    # live control-plane one, and {#command_check} calls it before storage
    # opens for that reason.
    def host_capability_notes
      notes = []

      unless Util::ImageShrinker.available?
        notes << "No #{Util::ImageShrinker::BINARIES.join(" or ")} on PATH, so file_rehosting's " \
                 "shrink and shrink_then_link strategies will link an oversized image instead of " \
                 "shrinking it. Install ImageMagick to have the picture cross as a picture."
      end

      unless Util::VideoTranscoder.available?
        notes << "No #{Util::VideoTranscoder.missing.join(" or ")} on PATH, so file_rehosting's " \
                 "shrink and shrink_then_link strategies will link an oversized video instead of " \
                 "shrinking it. Install ffmpeg to have the video cross smaller."
      end

      unless Util::QrDecoder.available?
        notes << "No libzbar found, so link_filter and word_filter will not decode a QR code out " \
                 "of an inbound photo, even in a room that enables them. Install libzbar (e.g. " \
                 "libzbar0) to have a QR-coded invite link caught the same way a typed one is " \
                 "(issue #857)."
      end

      unless Util::OcrReader.available?
        notes << "No tesseract binary found, so a photo attachment's OCR pass will not run even " \
                 "where a filter's ocr field asks for it. Install tesseract-ocr to read text off " \
                 "an inbound photo (issue #858)."
      end

      unless guest_portal_url_configured?
        notes << "GUEST_PORTAL_URL is not set to a full http(s) address, so /guest and /upload " \
                 "replies and the dashboard's guest invites cannot build a working URL. Set it to " \
                 "this deployment's public base under the /guest-chat mount, e.g. " \
                 "https://bridge.example.com/guest-chat."
      end

      unless file_storage_url_configured?
        notes << "RUBOTTY_FILE_STORAGE_URL is not set to a full http(s) address, so file_rehosting's " \
                 "download links cannot build a working URL; rehosting will refuse the file rather " \
                 "than send a broken link. Set it to this deployment's own public base, e.g. " \
                 "https://bridge.example.com: the /filestorage segment is added for you."
      end

      notes.concat(Scripting::Confined.describe)
      unless Scripting::Isolation.reachable?(Scripting::Child::SANDBOX)
        notes << "The script account cannot read #{Scripting::Child::SANDBOX}, so every script " \
                 "would start a child that exits before it says anything. Make the application " \
                 "directory readable, or point RUBOTTY_SCRIPT_USER at an account that can."
      end

      notes
    end

    # Surface the platform limits that would otherwise look like bugs, at
    # `check` time rather than once the bridge is running.
    #
    # topology, operators and people default to the static config's own, but
    # `check` passes the live control-plane view instead where available, so
    # a database-only deployment is judged on what it will actually run with.
    # +control_plane+ says which of those two it got, since the moderation
    # note below reads differently either way.
    def deployment_capability_notes(config, topology: config.topology, operators: config.operators,
                                     people: config.people, control_plane: false)
      notes = []

      adapters = topology.endpoints.map(&:adapter_name).uniq
      if adapters.include?(:telegram)
        notes << "Telegram sends no delete event, so removals out of Telegram rely on the " \
                 "unsend gesture (edit a message to a single full stop) or on /delete."
        notes << "Telegram reactions require the bot to be an ADMINISTRATOR in the chat, and a " \
                 "bot may hold only one reaction per message."
      end
      if adapters.include?(:discord)
        notes << "Discord needs the MESSAGE_CONTENT privileged intent enabled in the Developer " \
                 "Portal, or every message arrives with an empty body."
        notes << "Discord needs the SERVER_MEMBERS privileged intent enabled in the Developer " \
                 "Portal, or a join and a leave never reach greetings or anti-raid on that " \
                 "platform."
      end

      # A false supports_admin_dm? can mean two different things, so ask
      # capability_status rather than the bare boolean: an operator reachable
      # only on an unwritten platform is a gap to close, reachable only on an
      # incapable one is not.
      by_admin_dm_status = adapters.group_by { |name| Adapters::Registry[name]&.capability_status(:admin_dm) }
      unwritten = by_admin_dm_status[:not_written_here] || []
      incapable = by_admin_dm_status[:platform_cannot] || []
      unless unwritten.empty?
        notes << "rubotty has not implemented an admin DM for #{unwritten.sort.join(", ")} yet, so an " \
                 "operator reachable only there gets no startup DM and no other admin DM."
      end
      unless incapable.empty?
        notes << "#{incapable.sort.join(", ")} cannot carry an admin DM at all, so an operator " \
                 "reachable only there gets no startup DM and no other admin DM."
      end

      # Recognition and permission are separate questions, the same split
      # Core::Runtime#commands_enabled? makes: with a control plane the verbs
      # are read whatever the directory holds, and an unknown issuer is refused
      # rather than told the verb does not exist.
      commands_on = config.commands.fetch(:enabled, true)
      recognised = commands_on && (control_plane || !operators.empty?)
      if recognised && !operators.empty?
        notes << "Moderation commands are enabled for #{operators.operators.size} operator(s)."
      elsif recognised
        notes << "No operators are configured yet, so every moderation command is recognised and " \
                 "then refused as not permitted. The unsend gesture (edit a message to a single " \
                 "full stop) still works."
      elsif operators.empty?
        notes << "No operators configured, so /delete and the other commands are disabled. " \
                 "The unsend gesture (edit a message to a single full stop) still works."
      end

      if people.empty?
        notes << "No people configured, so mentions cross as plain text and never ping."
      end

      notes
    end

    def print_capability_notes(notes)
      return if notes.empty?

      @out.puts
      @out.puts "Worth knowing before you deploy:"
      notes.each { |note| @out.puts "  - #{note}" }
    end

    def guest_portal_url_configured?
      @env["GUEST_PORTAL_URL"].to_s.sub(%r{/+\z}, "").match?(%r{\Ahttps?://\S+\z})
    end

    # The same http(s)-or-nothing validation {Core::AttachmentRehoster} itself
    # applies before building a download link off RUBOTTY_FILE_STORAGE_URL.
    # Checked here too so a deployment learns of the gap at `check` time,
    # rather than only from a warning buried in the running bridge's own log
    # once a room first tries to rehost a file.
    def file_storage_url_configured?
      @env["RUBOTTY_FILE_STORAGE_URL"].to_s.sub(%r{/+\z}, "").match?(%r{\Ahttps?://\S+\z})
    end
  end
end
