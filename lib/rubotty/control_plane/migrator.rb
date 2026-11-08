# frozen_string_literal: true

require "sequel"

module Rubotty
  module ControlPlane
    # Runs the versioned control-plane migrations with Sequel::Migrator.
    #
    # Two migration regimes coexist in one database: the message map
    # (storage/schema.rb) keeps its ad-hoc, boot-idempotent Schema.apply, and the
    # control plane, the system of record, uses numbered migrations.
    class Migrator
      MIGRATIONS_DIR = File.expand_path("../../../db/migrations", __dir__)

      # Apply every pending migration. Idempotent: re-running when up to date is
      # a no-op.
      #
      # @param db [Sequel::Database]
      # @param dir [String] migrations directory
      # @return [Sequel::Database]
      def self.run(db, dir: MIGRATIONS_DIR)
        new(db, dir: dir).run
      end

      # Roll every control-plane migration back to +target+ (0 = fully down).
      def self.rollback(db, target: 0, dir: MIGRATIONS_DIR)
        new(db, dir: dir).run(target: target)
      end

      # True when the database is already at the latest migration.
      def self.current?(db, dir: MIGRATIONS_DIR)
        new(db, dir: dir).current?
      end

      def initialize(db, dir: MIGRATIONS_DIR)
        @db = db
        @dir = dir
      end

      def run(target: nil)
        Sequel.extension :migration
        if target.nil?
          Sequel::Migrator.run(@db, @dir)
        else
          Sequel::Migrator.run(@db, @dir, target: target)
        end
        @db
      rescue Sequel::Error => e
        raise StorageError, "could not run control-plane migrations: #{e.message}"
      end

      def current?
        Sequel.extension :migration
        Sequel::Migrator.is_current?(@db, @dir)
      end
    end
  end
end
