# frozen_string_literal: true

require "fileutils"

module Rubotty
  module Storage
    # Builds the configured storage backend: the only place in the codebase
    # that may require a database driver. Drivers are required lazily, so a
    # deployment never loads a library it did not choose, and every one is
    # precompiled, standard library or pure Ruby, so none needs a compiler
    # on any mainstream platform.
    module Factory
      DEFAULT_SQLITE_PATH = "data/message_map.sqlite3"
      DEFAULT_PSTORE_PATH = "data/message_map.pstore"

      # Friendly spellings of the MariaDB driver, all resolving to :mdb.
      MARIADB_ALIASES = %i[mdb mariadb mysql].freeze

      # The env var an operator sets to run a file-based backend on purpose.
      ALLOW_EPHEMERAL_VAR = "ALLOW_EPHEMERAL_STORAGE"

      # The file-based drivers. On a container with no persistent volume the
      # file is empty again after every restart and all history is gone.
      EPHEMERAL_DRIVERS = %i[sqlite pstore].freeze

      module_function

      # Pin every DateTime column to UTC, on the way in and on the way out:
      # unset, Sequel keeps a column's wall-clock digits and returns them
      # tagged with the reading process's zone, so every expiry gate holds
      # only while all containers agree on TZ. Process-wide, since Sequel's
      # application_timezone is.
      def use_utc!
        require "sequel"
        Sequel.default_timezone = :utc
      end

      # @param config [Hash] the validated `storage:` block
      # @param env [Hash]
      # @param logger [#info]
      # @param guard_ephemeral [Boolean] refuse a file-based backend (sqlite or
      #   pstore) unless ALLOW_EPHEMERAL_STORAGE opts in. The LIVE callers set
      #   it; the datastore transfer and the boot import leave it false, because
      #   copying data OFF a file is exactly their job.
      # @return [Base]
      def build(config, env: ENV, logger: nil, guard_ephemeral: false)
        driver = (config[:driver] || :sqlite).to_sym
        driver = :mdb if MARIADB_ALIASES.include?(driver)
        guard_ephemeral!(driver) if guard_ephemeral
        use_utc! unless driver == :memory
        case driver
        when :memory then Memory.new
        when :sqlite then build_sqlite(config, logger)
        when :pg then build_postgres(config, env, logger)
        when :mdb then build_mariadb(config, env, logger)
        when :pstore then build_pstore(config, logger)
        else
          raise ConfigError, ["storage.driver: unknown driver #{driver.inspect}"]
        end
      end

      # Refuse to hand back a file-based LIVE backend unless the operator has
      # opted in: sqlite and pstore lose ALL data when the container filesystem
      # is ephemeral, the default on Coolify and Heroku. memory is exempt.
      def guard_ephemeral!(driver)
        return unless EPHEMERAL_DRIVERS.include?(driver)
        return if ephemeral_allowed?

        raise StorageError,
              "#{driver} storage is file-based and loses ALL data on restart in an ephemeral " \
              "container. Set #{ALLOW_EPHEMERAL_VAR}=1 to use it deliberately (local dev, or a " \
              "persistent volume is mounted), or use a persistent backend (pgsql or mdb)."
      end

      # Truthy per the documented set (1, true or yes, in any case). Read from
      # the real process environment deliberately: a safety switch must not be
      # flipped by a value carried in a config block.
      def ephemeral_allowed?
        %w[1 true yes].include?(ENV[ALLOW_EPHEMERAL_VAR].to_s.strip.downcase)
      end

      # SQLite through Sequel's own adapter, so it shares {SequelStore} with
      # PostgreSQL and MariaDB.
      def build_sqlite(config, logger)
        path = config[:path] || DEFAULT_SQLITE_PATH
        require "sequel"
        require "sqlite3"

        directory = File.dirname(path)
        FileUtils.mkdir_p(directory) unless directory == "."

        db = Sequel.sqlite(path, max_connections: config[:max_connections] || 4,
                                                logger: logger)
        # Room workers write concurrently. Without WAL a reader blocks a writer.
        db.run("PRAGMA journal_mode=WAL")
        db.run("PRAGMA busy_timeout=5000")

        store = SequelStore.new(db: db, logger: logger,
                                description: "sqlite message map at #{path}")
        store.migrate! if config.fetch(:auto_migrate, true)
        store
      rescue LoadError => e
        raise StorageError, missing_driver_message("sqlite3", "default", e)
      rescue Sequel::Error => e
        raise StorageError, "could not open the SQLite database at #{path}: #{e.message}"
      end

      def build_postgres(config, env, logger)
        # The require comes first, before anything that can raise: the rescue
        # clauses below name Sequel::Error, so raising before Sequel is loaded
        # would surface as a NameError.
        require "sequel"
        require "pg"

        url = connection_url(config, env)
        if url.nil?
          raise ConfigError,
                ["storage: driver pg needs a connection URL. Set storage.url_env to the name " \
                 "of an environment variable holding it (DATABASE_URL is conventional on " \
                 "Heroku and Coolify)."]
        end

        db = Sequel.connect(
          normalise_postgres_url(url),
          max_connections: config[:max_connections] || 4,
          logger: logger
        )
        store = SequelStore.new(db: db, logger: logger, description: "postgres message map")
        store.migrate! if config.fetch(:auto_migrate, true)
        store
      rescue LoadError => e
        raise StorageError, missing_driver_message("pg", "postgres", e)
      rescue Sequel::Error => e
        raise StorageError, "could not connect to Postgres: #{e.message}"
      end

      # MariaDB / MySQL through Sequel's `mysql` adapter, which binds the
      # pure-Ruby `ruby-mysql` gem. {Dialect.prepare} extends the connection
      # so MariaDB keeps the TEXT column defaults the shared adapter would
      # strip.
      def build_mariadb(config, env, logger)
        require "sequel"
        require "mysql"

        url = connection_url(config, env)
        if url.nil?
          raise ConfigError,
                ["storage: driver mdb needs a connection URL. Set storage.url_env to the name " \
                 "of an environment variable holding it (MDB_DATABASE_URL is the convention here)."]
        end

        db = Sequel.connect(
          normalise_mysql_url(url),
          max_connections: config[:max_connections] || 4,
          # Talk utf8mb4 on the wire so 4-byte characters (emoji in the reaction
          # column) round-trip; Dialect.prepare pins the same charset on the tables.
          encoding: "utf8mb4",
          logger: logger
        )
        Dialect.prepare(db)
        store = SequelStore.new(db: db, logger: logger, description: "mariadb message map")
        store.migrate! if config.fetch(:auto_migrate, true)
        store
      rescue LoadError => e
        raise StorageError, missing_driver_message("ruby-mysql", "mariadb", e)
      rescue Sequel::Error => e
        raise StorageError, "could not connect to MariaDB: #{e.message}"
      end

      # stdlib PStore. No gem, no service, no compiler, no server.
      def build_pstore(config, logger)
        path = config[:path] || DEFAULT_PSTORE_PATH
        store = PStoreStore.new(path: path, logger: logger)
        store.migrate!
        logger&.warn do
          "storage driver pstore rewrites its whole file on every write and is safe for one " \
            "process only. Move to driver: sqlite or driver: pg before traffic grows."
        end
        store
      end

      def connection_url(config, env)
        if config[:url_env]
          value = env[config[:url_env].to_s]
          return value unless value.nil? || value.empty?

          raise ConfigError,
                ["storage.url_env: environment variable #{config[:url_env]} is not set"]
        end
        config[:url]
      end

      # Sequel expects `postgres://`, but some tooling rewrites it to
      # `postgresql://`, which Sequel does not recognise.
      def normalise_postgres_url(url)
        url.sub(%r{\Apostgresql://}, "postgres://")
      end

      # mariadb://, mysql:// and mysql2:// all name the same database, so rewrite
      # them to mysql://: mysql2:// would pull in the C-extension adapter we
      # deliberately do not require.
      def normalise_mysql_url(url)
        url.sub(%r{\A(?:mariadb|mysql2|mysql)://}, "mysql://")
      end

      def missing_driver_message(gem_name, group, error)
        base = "storage driver gem #{gem_name} is not available: #{error.message}. "
        return "#{base}Run `bundle install`." if group == "default"

        "#{base}Enable its bundle group and reinstall: " \
          "`bundle config set --local with #{group} && bundle install`, " \
          "or choose a different storage.driver."
      end
    end
  end
end
