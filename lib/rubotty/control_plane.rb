# frozen_string_literal: true

module Rubotty
  # The durable, foreign-keyed system of record the multi-tenant core reads through
  # an immutable Snapshot.
  #
  # Typical wiring:
  #
  #   models = ControlPlane.models(db)   # after ControlPlane.migrate!(db)
  #   ControlPlane::Seed.from_model(config, models: models, slug: "sample")
  #   ControlPlane::Registry.build(models: models, accounts: config.accounts).current
  module ControlPlane
    module_function

    # Apply all pending control-plane migrations. Idempotent.
    #
    # Serialized across processes with a DB advisory lock through the
    # {Storage::Dialect} seam, because two processes running a simultaneous ADD
    # COLUMN crash-loop on "Duplicate column name" where DDL auto-commits.
    def migrate!(db)
      # Every control-plane database goes through here, including the ones a spec
      # opens directly, so this is where UTC reaches all of them.
      Storage::Factory.use_utc!
      dialect = Storage::Dialect.for(db)
      dialect.migration_lock!
      begin
        Migrator.run(db)
      ensure
        dialect.migration_unlock!
      end
    end

    # Build the model classes for an already-migrated database.
    def models(db)
      Models.new(db)
    end
  end
end
