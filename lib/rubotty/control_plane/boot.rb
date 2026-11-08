# frozen_string_literal: true

require "sequel"

module Rubotty
  module ControlPlane
    # The control-plane boot lifecycle, shared by the runtime and the CLI so
    # there is exactly one place that decides "migrate, then seed if empty".
    # The message map keeps its own ad-hoc, boot-idempotent Schema.apply
    # since it is derived, droppable, TTL state, while the control plane is
    # the system of record with versioned migrations; both live in the SAME
    # database. The connection is the SequelStore's own Sequel::Database
    # (#db); the pstore and memory backends have none, so the control plane
    # is unavailable there and the runtime falls back to the config-derived topology.
    module Boot
      module_function

      # Can this storage backend host the control plane? True only when it exposes
      # a Sequel::Database, which is the connection the control plane reuses.
      def available?(storage)
        db_of(storage).is_a?(Sequel::Database)
      end

      # The Sequel connection to reuse, or nil for a backend that has none.
      def db_of(storage)
        storage.respond_to?(:db) ? storage.db : nil
      end

      # Prepare the control plane for a running instance: migrate, seed the
      # community from config the first time it's empty, then return a
      # Registry. Nil when the storage cannot host the control plane, so the
      # runtime falls back to the legacy path. Accounts are never seeded
      # here; the accounts table's only source is the dashboard or `rubotty
      # seed`.
      #
      # @return [Registry, nil]
      def prepare(storage:, config:, slug:, logger: nil, seed: true, env: ENV)
        db = db_of(storage)
        return nil unless db.is_a?(Sequel::Database)

        ControlPlane.migrate!(db)
        models = ControlPlane.models(db)
        if seed && empty?(models)
          Seed.from_model(config, models: models, slug: slug)
          logger&.info { "seeded the control plane from #{config.source} as community #{slug.inspect}" }
        elsif seed && config.name_declared?
          # The config-seeded community's NAME is reconciled from the config on
          # every boot after the first. Scoped to this ONE slug, so a
          # dynamically-onboarded community is never touched by this, and
          # skipped entirely for a configuration that named nothing.
          reconciled = Seed.reconcile_identity(config, models: models, slug: slug)
          if reconciled
            logger&.info { "reconciled community #{slug.inspect}'s name from #{config.source}" }
          end
        end
        Registry.build(models: models, accounts: config.accounts, env: env)
      end

      # Import the YAML's `accounts:` entries for any gateway not already there
      # by (adapter, name), never overwriting an existing row. Only `rubotty
      # seed` calls this, for an operator explicitly asking to bring file
      # entries into the accounts table. Never fatal: a failed import still
      # lets the rest of `rubotty seed` finish.
      def seed_accounts(config, models:, logger: nil)
        created = Accounts.new(models: models, logger: logger).seed_from_config(config)
        return if created.empty?

        logger&.info do
          "imported #{created.size} account(s) from #{config.source}: " \
            "#{created.map { |row| "#{row.adapter}/#{row.name}" }.join(", ")}"
        end
      rescue StandardError => e
        logger&.warn { "accounts: could not import from #{config.source}: #{e.message}" }
      end

      # Apply pending control-plane migrations, for the `rubotty migrate` CLI
      # command. Raises StorageError when the backend cannot host the plane, so
      # the CLI reports it rather than silently doing nothing.
      def migrate(storage:)
        db = require_db(storage)
        ControlPlane.migrate!(db)
      end

      # Migrate (to guarantee the schema exists) and then seed from the config,
      # for the `rubotty seed` CLI command. The seed itself is idempotent, so
      # re-running reconciles rather than duplicating.
      #
      # @return [Integer] the seeded community id
      def seed(storage:, config:, slug:)
        db = require_db(storage)
        ControlPlane.migrate!(db)
        models = ControlPlane.models(db)
        # Accounts too: the only place YAML accounts still reach the table,
        # for an operator explicitly asking to import them.
        seed_accounts(config, models: models)
        Seed.from_model(config, models: models, slug: slug)
      end

      # A stable community slug for the config: an explicit override wins (env
      # RUBOTTY_COMMUNITY_SLUG), otherwise a slug of the config name. Stable
      # across boots so seeding stays idempotent.
      def slug_for(config, env: ENV, override: nil)
        chosen = override || env["RUBOTTY_COMMUNITY_SLUG"]
        return slugify(chosen) if chosen && !chosen.to_s.empty?

        slugify(config.name)
      end

      def slugify(text)
        slug = text.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
        slug = "community" if slug.empty?
        slug[0, 64]
      end

      def empty?(models)
        models.community.count.zero?
      end

      def require_db(storage)
        db = db_of(storage)
        return db if db.is_a?(Sequel::Database)

        raise StorageError,
              "the control plane needs a Sequel-backed store (storage.driver sqlite, pg or mdb); " \
              "#{storage.describe} has no database connection to reuse."
      end
    end
  end
end
