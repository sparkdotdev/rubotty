# frozen_string_literal: true

require "spec_helper"

# Records every delivered message, standing in for a real adapter.
class GuestAnnouncerFakeAdapter < Rubotty::Adapters::Base
  def initialize(name)
    @name_sym = name
    super(account: name.to_s, settings: {}, dispatcher: nil, logger: Rubotty::Log.null)
    @delivered = []
  end

  attr_reader :delivered

  define_method(:adapter_name) { @name_sym }

  def capabilities = Rubotty::Adapters::Capabilities.new

  def own_account_id = "#{@name_sym}-bot"

  def start = self
  def stop = self
  def running? = true

  def deliver(message, endpoint)
    @delivered << [endpoint.id, message]
    Rubotty::Core::DeliveryReceipt.new(endpoint_id: endpoint.id, native_id: "n#{@delivered.size}")
  end
end

# Arrival and departure notices, in both shapes: direct synchronous delivery,
# and the durable job the guest portal and dashboard need, holding no adapters.
RSpec.describe Rubotty::ControlPlane::GuestAnnouncer, :control_plane do
  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:registry) { Rubotty::ControlPlane::Registry.new(models: models) }
  let(:community) { models.community.where(slug: "sample").first }
  let(:room) { models.room.where(community_id: community.id, room_key: "general").first }

  let(:tg) { GuestAnnouncerFakeAdapter.new(:telegram) }
  let(:dc) { GuestAnnouncerFakeAdapter.new(:discord) }
  let(:adapter_map) { { [:telegram, "telegram"] => tg, [:discord, "discord"] => dc } }

  let(:now) { Time.now }

  def make_invite(room_row: room)
    models.guest_invite.create(
      community_id: community.id, room_id: room_row.id, nickname: "Sam",
      token_hash: "digest", expires_at: now + 3600, created_at: now, updated_at: now
    )
  end

  describe "direct delivery (no scheduler)" do
    subject(:announcer) do
      described_class.new(registry: registry, models: models, adapters: adapter_map, logger: Rubotty::Log.null)
    end

    it "announces a join to every endpoint in the room" do
      invite = make_invite
      announcer.announce_join(invite)

      expect(tg.delivered.map(&:first)).to eq(["tg-general"])
      expect(dc.delivered.map(&:first)).to eq(["dc-general"])
      expect(tg.delivered.first.last.body.text).to eq("Sam (guest) joined the room as a guest.")
    end

    it "phrases a revocation departure distinctly from an expiry" do
      invite = make_invite
      announcer.announce_departure(invite, reason: "invite revoked")
      expect(tg.delivered.first.last.body.text).to eq("Sam (guest) left, access was revoked.")
    end

    it "phrases an expiry departure" do
      invite = make_invite
      announcer.announce_departure(invite, reason: "access expired")
      expect(tg.delivered.first.last.body.text).to eq("Sam (guest) left, access expired.")
    end

    it "does nothing for a nil invite" do
      expect { announcer.announce_join(nil) }.not_to raise_error
      expect { announcer.announce_departure(nil, reason: "access expired") }.not_to raise_error
      expect(tg.delivered).to be_empty
    end

    it "drops the notice, logged, when the invite's room no longer exists" do
      invite = make_invite
      models.room_channel.where(room_id: room.id).delete
      models.room.where(id: room.id).delete

      expect { announcer.announce_join(invite) }.not_to raise_error
      expect(tg.delivered).to be_empty
    end

    it "never raises when an adapter's delivery fails" do
      invite = make_invite
      allow(tg).to receive(:deliver).and_raise(Rubotty::AdapterError.new("nope", adapter: :telegram))

      expect { announcer.announce_join(invite) }.not_to raise_error
      expect(dc.delivered).not_to be_empty
    end

    it "is a no-op with no registry, the enqueue-only shape a write-only process gets" do
      enqueue_only = described_class.new(models: models, adapters: adapter_map)
      invite = make_invite

      expect { enqueue_only.announce_join(invite) }.not_to raise_error
      expect(tg.delivered).to be_empty
    end
  end

  # rooms.room_key is unique only WITHIN a community, so two communities each
  # having a "general" is routine. Resolving one against the global topology
  # would deliver the notice into a stranger's room.
  describe "a second community with a same-named room" do
    def build_other_community!
      now = Time.now
      other = models.community.create(
        slug: "other-co", name: "Other Co", status: "active", created_at: now, updated_at: now
      )
      connection = models.platform_connection.create(
        community_id: other.id, adapter: "telegram", account: "telegram-other",
        external_id: "-999", label: "Other general", created_at: now, updated_at: now
      )
      channel = models.channel.create(
        community_id: other.id, platform_connection_id: connection.id, adapter: "telegram",
        account: "telegram-other", route_key: "-999", endpoint_key: "other-tg-general",
        label: "general", receives: true, sends: true, relay: "{}", display_name: "{}",
        settings: "{}", created_at: now, updated_at: now
      )
      other_room = models.room.create(
        community_id: other.id, room_key: "general", label: "general",
        display_name: "{}", created_at: now, updated_at: now
      )
      models.room_channel.create(room_id: other_room.id, channel_id: channel.id, created_at: now)
      [other, other_room]
    end

    it "never delivers a SAMPLE guest's notice into the other community's same-named room" do
      other_community, = build_other_community!
      other_adapter = GuestAnnouncerFakeAdapter.new(:telegram)
      adapters = adapter_map.merge([:telegram, "telegram-other"] => other_adapter)
      announcer = described_class.new(registry: registry, models: models, adapters: adapters,
                                       logger: Rubotty::Log.null)

      invite = make_invite
      announcer.announce_join(invite)

      expect(tg.delivered.map(&:first)).to eq(["tg-general"])
      expect(other_adapter.delivered).to be_empty
      expect(invite.community_id).not_to eq(other_community.id)
    end
  end

  describe "routed through a durable job" do
    let(:scheduler) do
      Rubotty::Core::DurableScheduler.new(store: Rubotty::Core::DurableSchedulerStore::Sequel.new(db: db),
                                          session_id: "spec")
    end

    it "enqueues rather than delivering immediately, then delivers once the job runs" do
      writer = described_class.new(models: models, scheduler: scheduler) # no adapters: an enqueue-only process
      deliverer = described_class.new(registry: registry, models: models, adapters: adapter_map, scheduler: scheduler)
      invite = make_invite

      writer.announce_join(invite)
      expect(tg.delivered).to be_empty

      scheduler.run_due
      expect(tg.delivered.map(&:first)).to eq(["tg-general"])
    end

    it "carries the departure reason through the job payload" do
      writer = described_class.new(models: models, scheduler: scheduler)
      described_class.new(registry: registry, models: models, adapters: adapter_map, scheduler: scheduler)
      invite = make_invite

      writer.announce_departure(invite, reason: "invite revoked")
      scheduler.run_due

      expect(tg.delivered.first.last.body.text).to eq("Sam (guest) left, access was revoked.")
    end
  end
end
