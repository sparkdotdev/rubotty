# frozen_string_literal: true

require "spec_helper"
require "sequel"

# The migration lock seam. Only the SQLite side is exercisable without a real
# server, since Postgres and MySQL/MariaDB issue pg_try_advisory_lock and GET_LOCK
# against a live connection; CI's storage jobs prove those.
RSpec.describe Rubotty::Storage::Dialect do
  describe ".for" do
    it "resolves a sqlite connection to the Sqlite dialect" do
      expect(described_class.for(Sequel.sqlite)).to be_a(described_class::Sqlite)
    end
  end

  describe Rubotty::Storage::Dialect::Sqlite do
    subject(:dialect) { described_class.new(Sequel.sqlite) }

    # SQLite allows one writer at a time, so a second migrator blocks behind its
    # file lock and there is nothing for an advisory lock to add. A documented
    # no-op, never an accidental gap.
    it "#migration_lock! is a safe no-op that reports success" do
      expect(dialect.migration_lock!).to be(true)
    end

    it "#migration_unlock! is a safe no-op" do
      expect(dialect.migration_unlock!).to be_nil
    end

    it "accepts (and ignores) explicit name/timeout, matching the other dialects' signature" do
      expect(dialect.migration_lock!(name: "custom", timeout: 1)).to be(true)
      expect(dialect.migration_unlock!(name: "custom")).to be_nil
    end
  end

  describe "the base Dialect class" do
    subject(:dialect) { described_class.new(Sequel.sqlite) }

    # An unrecognised backend falls through .for to the generic Dialect, which must
    # fail loudly rather than let a caller proceed unlocked against a backend nobody
    # has taught this class to lock.
    it "#migration_lock! raises rather than silently allowing an unlocked migration" do
      expect { dialect.migration_lock! }.to raise_error(NotImplementedError)
    end

    it "#migration_unlock! raises for the same reason" do
      expect { dialect.migration_unlock! }.to raise_error(NotImplementedError)
    end

    it "#with_advisory_lock raises for the same reason" do
      expect { dialect.with_advisory_lock("x") { nil } }.to raise_error(NotImplementedError)
    end
  end

  # The named app lock, proven exactly on Sequel.mock (acquire, guarded block, release)
  # so a regression is caught without waiting for CI's live servers. Real mutual
  # exclusion is proven in advisory_lock_spec.rb.
  describe Rubotty::Storage::Dialect::Pgsql, "#with_advisory_lock" do
    let(:db) { Sequel.mock(host: "postgres") }
    subject(:dialect) { described_class.new(db) }

    it "acquires with pg_try_advisory_lock, runs the block, then releases with pg_advisory_unlock" do
      db.fetch = { v: true }
      ran = false

      result = dialect.with_advisory_lock("demo") { ran = true; :done }

      expect(ran).to be(true)
      expect(result).to eq(:done)
      sqls = db.sqls.join(" ")
      expect(sqls).to include("pg_try_advisory_lock")
      expect(sqls).to include("pg_advisory_unlock")
    end

    it "still releases the lock when the block raises" do
      db.fetch = { v: true }
      expect { dialect.with_advisory_lock("demo") { raise "boom" } }.to raise_error("boom")
      expect(db.sqls.join(" ")).to include("pg_advisory_unlock")
    end

    it "raises LockUnavailable, and never runs the block, when pg_try_advisory_lock keeps failing" do
      db.fetch = { v: false }
      ran = false

      expect { dialect.with_advisory_lock("demo", timeout: 0.05) { ran = true } }
        .to raise_error(Rubotty::LockUnavailable, /demo/)
      expect(ran).to be(false)
      expect(db.sqls.join(" ")).not_to include("pg_advisory_unlock")
    end
  end

  describe Rubotty::Storage::Dialect::Mysql, "#with_advisory_lock" do
    let(:db) { Sequel.mock(host: "mysql") }
    subject(:dialect) { described_class.new(db) }

    def stub_get_lock(result)
      db.fetch = ->(sql) { sql.include?("version") ? { v: "10.5.0-MariaDB" } : { v: result } }
    end

    it "acquires with GET_LOCK, runs the block, then releases with RELEASE_LOCK" do
      stub_get_lock(1)
      ran = false

      result = dialect.with_advisory_lock("demo") { ran = true; :done }

      expect(ran).to be(true)
      expect(result).to eq(:done)
      sqls = db.sqls.join(" ")
      expect(sqls).to include("get_lock")
      expect(sqls).to include("release_lock")
    end

    it "still releases the lock when the block raises" do
      stub_get_lock(1)
      expect { dialect.with_advisory_lock("demo") { raise "boom" } }.to raise_error("boom")
      expect(db.sqls.join(" ")).to include("release_lock")
    end

    it "raises LockUnavailable, and never runs the block, when GET_LOCK returns 0" do
      stub_get_lock(0)
      ran = false

      expect { dialect.with_advisory_lock("demo") { ran = true } }
        .to raise_error(Rubotty::LockUnavailable, /demo/)
      expect(ran).to be(false)
      expect(db.sqls.join(" ")).not_to include("release_lock")
    end
  end
end
