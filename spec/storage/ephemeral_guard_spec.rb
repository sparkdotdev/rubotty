# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# The startup guardrail against silent data loss on file-based storage. sqlite and pstore
# keep the whole datastore in one local file, which a container with no persistent volume
# wipes on every restart, losing all message history without a word. spec_helper sets
# ALLOW_EPHEMERAL_STORAGE for the whole run, so these examples toggle it and restore it.
RSpec.describe "the ephemeral-storage guard" do
  # Run the block with ALLOW_EPHEMERAL_STORAGE set to value (nil deletes it),
  # restoring what the suite had set however the block exits.
  def with_flag(value)
    saved = ENV["ALLOW_EPHEMERAL_STORAGE"]
    value.nil? ? ENV.delete("ALLOW_EPHEMERAL_STORAGE") : ENV["ALLOW_EPHEMERAL_STORAGE"] = value
    yield
  ensure
    saved.nil? ? ENV.delete("ALLOW_EPHEMERAL_STORAGE") : ENV["ALLOW_EPHEMERAL_STORAGE"] = saved
  end

  # The guard predicate on its own, so the driver matrix is proved without standing
  # up a real database, pg and mdb shipping in opt-in bundle groups.
  describe "Rubotty::Storage::Factory.guard_ephemeral!" do
    it "refuses sqlite when the flag is unset, naming the flag and the fix" do
      with_flag(nil) do
        expect { Rubotty::Storage::Factory.guard_ephemeral!(:sqlite) }
          .to raise_error(Rubotty::StorageError,
                          /sqlite storage is file-based.*ALLOW_EPHEMERAL_STORAGE.*pgsql or mdb/m)
      end
    end

    it "refuses pstore when the flag is unset" do
      with_flag(nil) do
        expect { Rubotty::Storage::Factory.guard_ephemeral!(:pstore) }
          .to raise_error(Rubotty::StorageError, /pstore storage is file-based/)
      end
    end

    it "accepts sqlite for every documented truthy spelling, case-insensitively" do
      %w[1 true yes TRUE Yes].each do |value|
        with_flag(value) do
          expect { Rubotty::Storage::Factory.guard_ephemeral!(:sqlite) }.not_to raise_error
        end
      end
    end

    it "still refuses on a non-truthy flag value" do
      with_flag("0") do
        expect { Rubotty::Storage::Factory.guard_ephemeral!(:sqlite) }
          .to raise_error(Rubotty::StorageError)
      end
    end

    it "never fires for the exempt in-process memory backend, flag or no flag" do
      with_flag(nil) do
        expect { Rubotty::Storage::Factory.guard_ephemeral!(:memory) }.not_to raise_error
      end
    end

    it "never fires for the real-database backends pg and mdb" do
      with_flag(nil) do
        expect { Rubotty::Storage::Factory.guard_ephemeral!(:pg) }.not_to raise_error
        expect { Rubotty::Storage::Factory.guard_ephemeral!(:mdb) }.not_to raise_error
      end
    end
  end

  # build_live is what the bot, the dashboard and the guest portal all call, so this
  # proves the guard is wired on there and not merely defined.
  describe "Rubotty::Storage::Selector.build_live" do
    it "refuses to boot the default sqlite backend when the flag is unset" do
      with_flag(nil) do
        expect { Rubotty::Storage::Selector.build_live({ driver: :sqlite }, env: {}) }
          .to raise_error(Rubotty::StorageError, /ALLOW_EPHEMERAL_STORAGE/)
      end
    end

    it "refuses to boot pstore when the flag is unset" do
      with_flag(nil) do
        expect { Rubotty::Storage::Selector.build_live({ driver: :pstore }, env: {}) }
          .to raise_error(Rubotty::StorageError, /ALLOW_EPHEMERAL_STORAGE/)
      end
    end

    it "boots sqlite when the flag is set" do
      Dir.mktmpdir("rubotty-guard") do |dir|
        store = Rubotty::Storage::Selector.build_live(
          { driver: :sqlite, path: File.join(dir, "map.sqlite3") }, env: {}
        )
        expect(store).to be_a(Rubotty::Storage::SequelStore)
        store.close
      end
    end

    it "boots pstore when the flag is set" do
      Dir.mktmpdir("rubotty-guard") do |dir|
        store = Rubotty::Storage::Selector.build_live(
          { driver: :pstore, path: File.join(dir, "map.pstore") }, env: {}
        )
        expect(store).to be_a(Rubotty::Storage::PStoreStore)
        store.close
      end
    end

    it "boots the exempt memory backend even when the flag is unset" do
      with_flag(nil) do
        store = Rubotty::Storage::Selector.build_live({ driver: :memory }, env: {})
        expect(store).to be_a(Rubotty::Storage::Memory)
        store.close
      end
    end
  end
end
