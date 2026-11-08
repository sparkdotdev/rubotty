# frozen_string_literal: true

require "spec_helper"

# Hot-path code, driven against a real migrated directory so the author-to-row
# extraction is end to end: a chatty author must not cost an upsert per message, and
# a failed recording must not break message handling.
RSpec.describe Rubotty::ControlPlane::IdentityRecorder, :control_plane do
  let(:db) { migrated_db }
  let(:models) { build_models(db) }
  let(:directory) { Rubotty::ControlPlane::IdentityDirectory.new(models: models) }

  # A controllable monotonic clock, so the throttle window is deterministic.
  let(:mono) { [1000.0] }

  subject(:recorder) do
    described_class.new(directory: directory, logger: Rubotty::Log.null,
                        throttle: 60, clock: -> { mono[0] })
  end

  let(:community_id) do
    stamp = Time.now
    db[:communities].insert(slug: "alpha", name: "Alpha", status: "active",
                            settings: "{}", created_at: stamp, updated_at: stamp)
  end

  # The recorder only reads community.id, so the double supplies nothing else.
  let(:community) { instance_double(Rubotty::ControlPlane::Snapshot::Community, id: community_id) }

  let(:tg) { endpoint("tg", adapter: :telegram) }

  def entries = models.observed_identity.where(community_id: community_id).all

  describe "#record" do
    it "records the author of an inbound message into the community directory" do
      recorder.record(message(tg, author: author(native_id: "111", username: "Ada", first_name: "Ada", last_name: "Lovelace")), community)
      expect(entries.size).to eq(1)
      row = entries.first
      expect(row.adapter).to eq("telegram")
      expect(row.native_id).to eq("111")
      expect(row.username).to eq("ada")
      expect(row.display_name).to eq("Ada Lovelace")   # profile_name from full_name
    end

    it "throttles a repeat, unchanged sighting within the window to a single write" do
      msg = message(tg, author: author(native_id: "111", username: "ada", first_name: "Ada"))
      recorder.record(msg, community)
      first_seen = entries.first.last_seen_at

      mono[0] += 30            # still inside the 60s window
      recorder.record(msg, community)
      expect(entries.size).to eq(1)
      # No second write: last_seen_at is unchanged.
      expect(entries.first.last_seen_at).to eq(first_seen)
    end

    it "writes through again once the throttle window elapses" do
      msg = message(tg, author: author(native_id: "111", username: "ada", first_name: "Ada"))
      recorder.record(msg, community)
      mono[0] += 61            # past the window
      recorder.record(msg, community)
      # An upsert, so the second write-through still leaves one row.
      expect(entries.size).to eq(1)
    end

    it "writes through IMMEDIATELY when the handle changes, even inside the window" do
      recorder.record(message(tg, author: author(native_id: "111", username: "ada", first_name: "Ada")), community)
      mono[0] += 5
      recorder.record(message(tg, author: author(native_id: "111", username: "ada_renamed", first_name: "Ada")), community)
      expect(entries.first.username).to eq("ada_renamed")
    end

    it "writes through immediately when the display name changes, even inside the window" do
      recorder.record(message(tg, author: author(native_id: "111", username: "ada", first_name: "Ada")), community)
      mono[0] += 5
      recorder.record(message(tg, author: author(native_id: "111", username: "ada", first_name: "Adabelle")), community)
      expect(entries.first.display_name).to eq("Adabelle")
    end

    it "records identities on different platforms as separate entries" do
      dc = endpoint("dc", adapter: :discord)
      recorder.record(message(tg, author: author(native_id: "111", username: "ada", first_name: "Ada")), community)
      recorder.record(message(dc, author: author(native_id: "999", username: "ada", display_name: "Ada")), community)
      expect(entries.map(&:adapter)).to contain_exactly("telegram", "discord")
    end

    it "is a no-op when no community resolved (no control plane / unknown origin)" do
      recorder.record(message(tg, author: author(native_id: "111")), nil)
      expect(models.observed_identity.count).to eq(0)
    end

    it "skips a system author (a bridge notice), which is not a room member" do
      recorder.record(message(tg, author: Rubotty::Core::Author.new(kind: :system)), community)
      expect(models.observed_identity.count).to eq(0)
    end

    it "skips a bot or webhook author, whose displayed handle may name somebody else" do
      recorder.record(message(tg, author: author(native_id: "hook", username: "ada", bot: true)), community)
      expect(models.observed_identity.count).to eq(0)
    end

    it "skips an author with no native id (nothing stable to key on)" do
      recorder.record(message(tg, author: author(native_id: nil, username: "ada")), community)
      expect(models.observed_identity.count).to eq(0)
    end

    it "never lets a directory failure propagate to message handling" do
      exploding = instance_double(Rubotty::ControlPlane::IdentityDirectory)
      allow(exploding).to receive(:record).and_raise(Sequel::DatabaseError, "boom")
      safe = described_class.new(directory: exploding, logger: Rubotty::Log.null)
      expect do
        safe.record(message(tg, author: author(native_id: "111", username: "ada")), community)
      end.not_to raise_error
    end
  end

  describe "#record_sighting" do
    it "records a bare identity tuple into the community directory" do
      recorder.record_sighting(community_id: community_id, adapter: "discord", native_id: "88",
                               username: "quill", display: "Quill Marlowe")
      expect(entries.size).to eq(1)
      row = entries.first
      expect(row.adapter).to eq("discord")
      expect(row.native_id).to eq("88")
      expect(row.username).to eq("quill")
      expect(row.display_name).to eq("Quill Marlowe")
    end

    it "throttles a repeat, unchanged sighting within the window to a single write" do
      recorder.record_sighting(community_id: community_id, adapter: "discord", native_id: "88",
                               username: "quill", display: "Quill Marlowe")
      first_seen = entries.first.last_seen_at

      mono[0] += 30            # still inside the 60s window
      recorder.record_sighting(community_id: community_id, adapter: "discord", native_id: "88",
                               username: "quill", display: "Quill Marlowe")
      expect(entries.size).to eq(1)
      # No second write: last_seen_at is unchanged.
      expect(entries.first.last_seen_at).to eq(first_seen)
    end

    it "is a no-op, and never raises, for a nil community_id, native_id, or adapter" do
      expect do
        recorder.record_sighting(community_id: nil, adapter: "discord", native_id: "88", username: "quill")
        recorder.record_sighting(community_id: community_id, adapter: "discord", native_id: nil, username: "quill")
        recorder.record_sighting(community_id: community_id, adapter: nil, native_id: "88", username: "quill")
      end.not_to raise_error
      expect(models.observed_identity.count).to eq(0)
    end

    # A game server handing back a session slot rather than an account would
    # otherwise merge two strangers across a restart and split one person
    # across two, with nothing to say it had.
    it "records nothing for a connection whose ids are per session" do
      slotted = Class.new do
        def identity_durability = :session
      end.new
      recorder = described_class.new(
        directory: directory, logger: Rubotty::Log.null,
        adapters: { [:api_wrapper, "acme"] => slotted }
      )
      origin = endpoint("acme:support", adapter: "api_wrapper", account: "acme")

      recorder.record(message(origin, author: author(native_id: "slot-3")), community)

      expect(models.observed_identity.count).to eq(0)
    end

    it "records for a connection whose ids name an account" do
      steady = Class.new do
        def identity_durability = :account
      end.new
      recorder = described_class.new(
        directory: directory, logger: Rubotty::Log.null,
        adapters: { [:api_wrapper, "acme"] => steady }
      )
      origin = endpoint("acme:support", adapter: "api_wrapper", account: "acme")

      recorder.record(message(origin, author: author(native_id: "u1")), community)

      expect(models.observed_identity.count).to eq(1)
    end

    it "reads an unknown connection as durable, which is what every platform here is" do
      recorder = described_class.new(directory: directory, logger: Rubotty::Log.null, adapters: {})

      recorder.record(message(tg, author: author(native_id: "u9")), community)

      expect(models.observed_identity.count).to eq(1)
    end

    it "never lets a directory failure propagate to the caller" do
      exploding = instance_double(Rubotty::ControlPlane::IdentityDirectory)
      allow(exploding).to receive(:record).and_raise(Sequel::DatabaseError, "boom")
      safe = described_class.new(directory: exploding, logger: Rubotty::Log.null)
      expect do
        safe.record_sighting(community_id: community_id, adapter: "discord", native_id: "88", username: "quill")
      end.not_to raise_error
    end
  end
end
