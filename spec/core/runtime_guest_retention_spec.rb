# frozen_string_literal: true

require "spec_helper"

# Exercised directly rather than through a full #start, which would bring up
# real adapters.
RSpec.describe Rubotty::Core::Runtime, "guest retention wiring", :control_plane do
  let(:config) { sample_model }

  def sequel_store
    db = Sequel.sqlite
    store = Rubotty::Storage::SequelStore.new(db: db, description: "test sqlite")
    store.migrate!
    store
  end

  def build_runtime(store:)
    described_class.new(
      config: config, logger: Rubotty::Log.null, storage: store, env: ControlPlaneHelpers::CONFIG_ENV
    ).build
  end

  describe "construction" do
    it "builds the retention service on a Sequel-backed backend" do
      runtime = build_runtime(store: sequel_store)
      expect(runtime.guest_retention).to be_a(Rubotty::ControlPlane::GuestRetention)
    ensure
      runtime&.durable_scheduler&.stop
    end

    # Registered before boot recovery runs, so a session that expired during
    # downtime is reclaimed on the very next start.
    it "registers the reclamation handler on the durable scheduler" do
      runtime = build_runtime(store: sequel_store)
      expect(runtime.durable_scheduler.handler?(Rubotty::ControlPlane::GuestRetention::KIND)).to be(true)
    ensure
      runtime&.durable_scheduler&.stop
    end

    it "takes its retention grace from the behaviour configuration" do
      runtime = build_runtime(store: sequel_store)
      expect(runtime.guest_retention.grace).to eq(config.guest_retention)
    ensure
      runtime&.durable_scheduler&.stop
    end

    # No control plane means no guest tables, so there is nothing to reclaim.
    it "builds no retention service on a backend with no control plane" do
      runtime = build_runtime(store: Rubotty::Storage::Memory.new)
      expect(runtime.guest_retention).to be_nil
    end
  end

  describe "the boot reconcile" do
    it "reclaims a guest session that ended while the process was down" do
      store = sequel_store
      runtime = build_runtime(store: store)
      models = Rubotty::ControlPlane.models(store.db)
      community = models.community.first
      room = models.room.where(community_id: community.id, room_key: "general").first

      long_ago = Time.now - 86_400
      models.guest_invite.create(
        community_id: community.id, room_id: room.id, nickname: "Gone",
        token_hash: "b" * 64, expires_at: long_ago,
        created_at: long_ago - 3600, updated_at: long_ago - 3600
      )
      models.guest_message.create(
        community_id: community.id, room_id: room.id, direction: "in",
        author_label: "Ada@discord", body: "a member message captured for a guest",
        attachments: "[]", kind: "chat", created_at: long_ago - 3600
      )

      runtime.send(:reconcile_guest_retention)

      expect(models.guest_message.count).to eq(0)
    ensure
      runtime&.durable_scheduler&.stop
    end

    it "is a harmless no-op without a control plane" do
      runtime = build_runtime(store: Rubotty::Storage::Memory.new)
      expect { runtime.send(:reconcile_guest_retention) }.not_to raise_error
    end
  end

  describe "the periodic sweep" do
    # The sweep rides the existing purge tick, so it starts no thread of its own.
    it "is a harmless no-op without a control plane" do
      runtime = build_runtime(store: Rubotty::Storage::Memory.new)
      expect { runtime.send(:sweep_guest_retention) }.not_to raise_error
    end

    it "never raises out of the purge thread when the sweep fails" do
      runtime = build_runtime(store: sequel_store)
      allow(runtime.guest_retention).to receive(:sweep).and_raise(StandardError, "boom")
      expect { runtime.send(:sweep_guest_retention) }.not_to raise_error
    ensure
      runtime&.durable_scheduler&.stop
    end
  end
end
