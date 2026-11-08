# frozen_string_literal: true

require "spec_helper"
require "sequel"

# ControlPlane.migrate! itself, as opposed to the migrations it runs. The
# bot and rubotty-web both call this on boot against the SAME shared
# database, so a simultaneous deploy must serialize through the dialect's
# advisory lock rather than race the same DDL.
RSpec.describe Rubotty::ControlPlane do
  let(:db) { Sequel.sqlite }

  describe ".migrate!" do
    it "acquires the lock, runs the migrator, then releases the lock, in that order" do
      dialect = instance_spy(Rubotty::Storage::Dialect::Sqlite)
      allow(Rubotty::Storage::Dialect).to receive(:for).with(db).and_return(dialect)

      expect(dialect).to receive(:migration_lock!).ordered
      expect(Rubotty::ControlPlane::Migrator).to receive(:run).with(db).ordered
      expect(dialect).to receive(:migration_unlock!).ordered

      described_class.migrate!(db)
    end

    it "releases the lock even when the migration run raises" do
      dialect = instance_spy(Rubotty::Storage::Dialect::Sqlite, migration_lock!: true)
      allow(Rubotty::Storage::Dialect).to receive(:for).with(db).and_return(dialect)
      allow(Rubotty::ControlPlane::Migrator).to receive(:run).and_raise(Rubotty::StorageError, "boom")

      expect { described_class.migrate!(db) }.to raise_error(Rubotty::StorageError, "boom")
      expect(dialect).to have_received(:migration_unlock!)
    end

    it "never runs migrations, and never tries to unlock, when the lock cannot be acquired" do
      dialect = instance_spy(Rubotty::Storage::Dialect::Sqlite)
      allow(Rubotty::Storage::Dialect).to receive(:for).with(db).and_return(dialect)
      allow(dialect).to receive(:migration_lock!).and_raise(Rubotty::StorageError, "timed out waiting for the lock")
      allow(Rubotty::ControlPlane::Migrator).to receive(:run)

      expect { described_class.migrate!(db) }.to raise_error(Rubotty::StorageError, "timed out waiting for the lock")
      expect(Rubotty::ControlPlane::Migrator).not_to have_received(:run)
      # A lock this caller never held must never be "released": that would
      # release the WINNER's lock out from under it.
      expect(dialect).not_to have_received(:migration_unlock!)
    end

    it "migrates through the real SQLite dialect (its lock degrades to a safe no-op)" do
      expect { described_class.migrate!(db) }.not_to raise_error

      expect(Rubotty::ControlPlane::Migrator.current?(db)).to be(true)
      expect(db.table_exists?(:communities)).to be(true)
    end
  end
end
