# frozen_string_literal: true

module Rubotty
  module Storage
    # The env-driven, one-boot datastore import: point the app at a new LIVE
    # backend, set LIVE_DB_IMPORT_FROM to the old one, and reboot to copy
    # every row across before running on the new database. Refuses to
    # clobber: the copy runs only when the live database is empty, unless
    # LIVE_DB_IMPORT_FORCE=1 is set, so a stray LIVE_DB_IMPORT_FROM left in
    # the environment on a later boot is a loud no-op.
    module BootImport
      IMPORT_FROM_VAR = Selector::IMPORT_FROM_VAR
      FORCE_VAR = "LIVE_DB_IMPORT_FORCE"

      module_function

      # Run the import when LIVE_DB_IMPORT_FROM names a source that differs from
      # the live backend. A no-op (returns nil) when the variable is unset.
      #
      # @param target_config [Hash] the LIVE storage config ({Selector.live_config})
      # @param env [Hash]
      # @param logger [#info, #warn, nil]
      # @return [Transfer::Report, nil]
      def run(target_config:, env: ENV, logger: nil)
        from = Selector.presence(env[IMPORT_FROM_VAR])
        return nil if from.nil?

        source_config = Selector.config_for(from, env: env, var: IMPORT_FROM_VAR)
        if source_config == target_config
          logger&.warn { "#{IMPORT_FROM_VAR}=#{from} names the live backend itself; nothing to import." }
          return nil
        end

        unless Selector.presence(env[FORCE_VAR]) == "1" || target_empty?(target_config, env: env, logger: logger)
          logger&.warn do
            "#{IMPORT_FROM_VAR}=#{from} is set but the live database already holds data. Refusing to " \
              "import over it. Set #{FORCE_VAR}=1 to override, or unset #{IMPORT_FROM_VAR} for a normal boot."
          end
          return nil
        end

        import(source_config, target_config, env: env, logger: logger)
      end

      # True when the live datastore carries no rows in any migrated table. The
      # target is migrated first, so "empty" means "schema present, zero rows".
      def target_empty?(target_config, env:, logger:)
        store = Factory.build(target_config.merge(auto_migrate: true), env: env, logger: logger)
        db = require_sequel(store)
        ControlPlane::Migrator.run(db)
        Transfer::TABLES.none? { |table| Transfer.occupied?(db, table) }
      ensure
        store&.close
      end

      def import(source_config, target_config, env:, logger:)
        logger&.info do
          "#{IMPORT_FROM_VAR}: importing #{Transfer.safe_label(source_config)} into " \
            "#{Transfer.safe_label(target_config)} on boot."
        end
        report = Transfer.new(source: source_config, target: target_config, env: env, logger: logger).run
        report.rows.each do |row|
          logger&.info do
            format("  %-22s %9d -> %-9d %s", row[:table], row[:source], row[:target], row[:ok] ? "ok" : "MISMATCH")
          end
        end
        raise verification_error(report) unless report.ok?

        logger&.info do
          "boot import complete: #{report.total_target} rows across #{report.rows.size} tables. " \
            "Remove #{IMPORT_FROM_VAR} for later boots."
        end
        report
      end

      def require_sequel(store)
        db = ControlPlane::Boot.db_of(store)
        return db if db.is_a?(Sequel::Database)

        raise StorageError,
              "the live datastore (#{store.describe}) is not Sequel-backed, so a boot import cannot " \
              "run against it. Use LIVE_DB_TYPE pgsql, mdb or sqlite on both ends."
      end

      def verification_error(report)
        tables = report.mismatches.map { |row| row[:table] }.join(", ")
        StorageError.new(
          "boot import verification failed: row-count mismatch on #{tables}. The source " \
          "(#{report.source_label}) was not modified; inspect the live database before use."
        )
      end
    end
  end
end
