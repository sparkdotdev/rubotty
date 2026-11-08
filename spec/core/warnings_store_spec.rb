# frozen_string_literal: true

require "spec_helper"
require "sequel"

# Sequel over migration 007's tables, with a Null for backends that have no
# database.
RSpec.describe Rubotty::Core::WarningsStore do
  describe ".for" do
    it "returns the Sequel store when the backend exposes a Sequel database" do
      db = Sequel.sqlite
      Rubotty::ControlPlane::Migrator.run(db)
      backend = Rubotty::Storage::SequelStore.new(db: db, description: "sqlite")
      expect(described_class.for(backend).durable?).to be(true)
    end

    it "returns the Null store for a backend with no database" do
      expect(described_class.for(Rubotty::Storage::Memory.new).durable?).to be(false)
    end
  end

  describe described_class::Null do
    subject(:store) { described_class.new }

    it "records nothing and reports an empty history" do
      expect(store.record_warning(community: "c", adapter: :tg, subject_native_id: "u1")).to be_nil
      expect(store.active_count(community: "c", adapter: :tg, subject_native_id: "u1")).to eq(0)
      expect(store.active_warnings(community: "c", adapter: :tg, subject_native_id: "u1")).to eq([])
      expect(store.record_sanction(community: "c", adapter: :tg, subject_native_id: "u1",
                                    action: :mute, until_at: Time.now)).to be_nil
      expect(store.find_sanction(community: "c", id: 1)).to be_nil
      expect(store.community_sanctions(community: "c")).to eq([])
    end
  end

  describe described_class::Sequel do
    let(:db) do
      db = Sequel.sqlite
      Rubotty::ControlPlane::Migrator.run(db)
      db
    end
    subject(:store) { described_class.new(db: db) }

    def warn(reason: "spam", issued_by: "Op", native_id: "u1")
      store.record_warning(
        community: "sample", adapter: :telegram, subject_native_id: native_id,
        subject_username: "ada", subject_display: "Ada", reason: reason, issued_by: issued_by
      )
    end

    describe "warnings" do
      it "records a strike and reads it back as active" do
        record = warn
        expect(record.id).to be_a(Integer)
        expect(record.reason).to eq("spam")
        expect(store.active_count(community: "sample", adapter: :telegram, subject_native_id: "u1")).to eq(1)
      end

      it "counts only active strikes, and only for the named subject" do
        warn
        warn(native_id: "u1")
        warn(native_id: "u2")
        expect(store.active_count(community: "sample", adapter: :telegram, subject_native_id: "u1")).to eq(2)
        expect(store.active_count(community: "sample", adapter: :telegram, subject_native_id: "u2")).to eq(1)
      end

      it "clears every active strike with scope :all, keeping the rows as history" do
        warn
        warn
        removed = store.deactivate_warnings(community: "sample", adapter: :telegram, subject_native_id: "u1", scope: :all)
        expect(removed).to eq(2)
        expect(store.active_count(community: "sample", adapter: :telegram, subject_native_id: "u1")).to eq(0)
      end

      it "removes only the most recent strike with scope :latest" do
        warn(reason: "first")
        warn(reason: "second")
        removed = store.deactivate_warnings(
          community: "sample", adapter: :telegram, subject_native_id: "u1", scope: :latest
        )
        expect(removed).to eq(1)
        remaining = store.active_warnings(community: "sample", adapter: :telegram, subject_native_id: "u1")
        expect(remaining.map(&:reason)).to eq(["first"])
      end

      it "records the issuing account, so a decay job can DM back through the same connection" do
        record = store.record_warning(
          community: "sample", adapter: :telegram, subject_native_id: "u1", account: "main"
        )
        expect(record.account).to eq("main")
      end

      describe "#deactivate_warning" do
        it "deactivates exactly the one warning named, leaving a sibling active" do
          first = warn(reason: "first")
          warn(reason: "second")
          expect(store.deactivate_warning(community: "sample", id: first.id)).to be(true)
          remaining = store.active_warnings(community: "sample", adapter: :telegram, subject_native_id: "u1")
          expect(remaining.map(&:reason)).to eq(["second"])
        end

        it "is false, not an error, for a warning already inactive" do
          first = warn
          store.deactivate_warning(community: "sample", id: first.id)
          expect(store.deactivate_warning(community: "sample", id: first.id)).to be(false)
        end
      end
    end

    describe "sanctions" do
      it "records a sanction with its endpoint list and reads it back" do
        record = store.record_sanction(
          community: "sample", adapter: :telegram, subject_native_id: "u1",
          action: :mute, until_at: Time.now + 3600, endpoints: %w[tg tg2]
        )
        found = store.find_sanction(community: "sample", id: record.id)
        expect(found.action).to eq("mute")
        expect(found.endpoints).to eq(%w[tg tg2])
        expect(found.active).to be(true)
      end

      it "accepts a nil until_at, for a permanent sanction with nothing scheduled to reverse it" do
        record = store.record_sanction(
          community: "sample", adapter: :telegram, subject_native_id: "u1", action: :mute, until_at: nil
        )
        expect(store.find_sanction(community: "sample", id: record.id).until_at).to be_nil
      end

      it "attaches an expiry job id after scheduling" do
        record = store.record_sanction(community: "sample", adapter: :telegram, subject_native_id: "u1",
                                       action: :ban, until_at: Time.now + 60, endpoints: %w[tg])
        store.attach_job(record.id, "job-99")
        expect(store.find_sanction(community: "sample", id: record.id).job_id).to eq("job-99")
      end

      it "lifts a sanction, deactivating it while keeping the row" do
        record = store.record_sanction(community: "sample", adapter: :telegram, subject_native_id: "u1",
                                       action: :mute, until_at: Time.now + 60, endpoints: %w[tg])
        store.lift_sanction(community: "sample", id: record.id)
        expect(store.find_sanction(community: "sample", id: record.id).active).to be(false)
        expect(store.active_sanctions(community: "sample", adapter: :telegram, subject_native_id: "u1")).to be_empty
      end

      describe "#community_sanctions" do
        it "returns every active sanction in a community across subjects and platforms, newest first" do
          first = store.record_sanction(community: "sample", adapter: :telegram, subject_native_id: "u1",
                                        action: :mute, until_at: Time.now + 60)
          second = store.record_sanction(community: "sample", adapter: :discord, subject_native_id: "u2",
                                         action: :ban, until_at: Time.now + 60)
          expect(store.community_sanctions(community: "sample").map(&:id)).to eq([second.id, first.id])
        end

        it "excludes a lifted sanction by default, and includes it when active: false" do
          record = store.record_sanction(community: "sample", adapter: :telegram, subject_native_id: "u1",
                                         action: :mute, until_at: Time.now + 60)
          store.lift_sanction(community: "sample", id: record.id)
          expect(store.community_sanctions(community: "sample")).to be_empty
          expect(store.community_sanctions(community: "sample", active: false).map(&:id)).to eq([record.id])
        end

        it "never returns another community's sanction" do
          store.record_sanction(community: "other", adapter: :telegram, subject_native_id: "u1",
                                action: :mute, until_at: Time.now + 60)
          expect(store.community_sanctions(community: "sample")).to be_empty
        end
      end
    end
  end
end
