# frozen_string_literal: true

module Rubotty
  module Storage
    # Env-driven backend selection.
    #
    # LIVE_DB_TYPE plus the per-backend connection vars take PRECEDENCE over the
    # YAML storage: block. Each backend reads its OWN connection var, so an
    # operator can flip the live backend by changing a single variable.
    module Selector
      LIVE_TYPE_VAR = "LIVE_DB_TYPE"
      IMPORT_FROM_VAR = "LIVE_DB_IMPORT_FROM"

      # The backend tokens LIVE_DB_TYPE and LIVE_DB_IMPORT_FROM accept.
      TOKENS = %w[pgsql mdb sqlite pstore memory].freeze

      module_function

      # The storage config for the LIVE backend: the env-selected one when
      # LIVE_DB_TYPE is set, otherwise the YAML storage: block unchanged.
      #
      # @param yaml_config [Hash] the validated storage: block
      # @param env [Hash]
      # @return [Hash] a config Factory.build accepts
      def live_config(yaml_config, env: ENV)
        token = presence(env[LIVE_TYPE_VAR])
        return yaml_config if token.nil?

        config_for(token, env: env, var: LIVE_TYPE_VAR)
      end

      # Build the live store, honouring the env selection: the single seam
      # the runtime and the rackup entry points call, so every process
      # resolves the same backend from the same variables. Does NOT run the
      # boot import; that is the runtime's job.
      def build_live(yaml_config, env: ENV, logger: nil)
        # This is THE live backend, so a file-based driver here must be a
        # deliberate opt-in (ALLOW_EPHEMERAL_STORAGE).
        Factory.build(live_config(yaml_config, env: env), env: env, logger: logger, guard_ephemeral: true)
      end

      # Whether the env layer is steering the backend at all.
      def env_selected?(env: ENV)
        !presence(env[LIVE_TYPE_VAR]).nil?
      end

      # Resolve a backend token (from LIVE_DB_TYPE or LIVE_DB_IMPORT_FROM) to a
      # Factory config hash, reading that backend's own connection var.
      #
      # @param token [String]
      # @param env [Hash]
      # @param var [String] the variable the token came from, for the error
      # @return [Hash]
      def config_for(token, env: ENV, var: LIVE_TYPE_VAR)
        case token.to_s.strip.downcase
        when "pgsql" then { driver: :pg, url_env: "PGSQL_DATABASE_URL" }
        when "mdb" then { driver: :mdb, url_env: "MDB_DATABASE_URL" }
        when "sqlite" then sqlite_config(env)
        when "pstore" then pstore_config(env)
        when "memory" then { driver: :memory }
        else
          raise ConfigError,
                ["#{var}: unknown backend #{token.inspect}. Use one of: #{TOKENS.join(", ")}."]
        end
      end

      def sqlite_config(env)
        path = presence(env["SQLITE_FILENAME"])
        path ? { driver: :sqlite, path: path } : { driver: :sqlite }
      end

      def pstore_config(env)
        path = presence(env["PSTORE_FILENAME"])
        path ? { driver: :pstore, path: path } : { driver: :pstore }
      end

      # nil for a nil-or-blank value, so an env var set to "" reads as unset.
      def presence(value)
        return nil if value.nil?

        stripped = value.to_s.strip
        stripped.empty? ? nil : stripped
      end
    end
  end
end
