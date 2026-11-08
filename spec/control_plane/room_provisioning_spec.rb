# frozen_string_literal: true

require "spec_helper"

# Creating and deleting meta-channels from the dashboard, provisioned on each platform.
RSpec.describe Rubotty::ControlPlane::RoomProvisioning, :control_plane do
  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }
  let(:audit) { Rubotty::Core::AuditLog::Sequel.new(db: db) }
  let(:now) { Time.new(2026, 7, 24, 12, 0, 0) }

  # A fake adapter with real channel-management support, kept as a local Class.new so
  # it leaks no constant for other specs to trip over.
  fake_managed_adapter_class = Class.new do
    attr_reader :created, :deleted, :copied, :scoped_to

    def initialize(next_id: "native-1")
      @next_id = next_id
      @created = []
      @deleted = []
      @copied = []
      @scoped_to = []
      @fail_create = nil
    end

    def fail_next_create(error) = (@fail_create = error)

    def supports_channel_management? = true

    def create_channel(name:, community_id:, template: nil)
      raise ArgumentError, "no community" if community_id.nil?

      @scoped_to << community_id
      if @fail_create
        error = @fail_create
        @fail_create = nil
        raise error
      end
      @created << { name: name, template: template }
      @next_id
    end

    def delete_channel(native_id, community_id:)
      raise ArgumentError, "no community" if community_id.nil?

      @scoped_to << community_id
      @deleted << native_id
      true
    end

    def copy_channel_permissions(from:, to:)
      @copied << { from: from, to: to }
      true
    end
  end

  let(:discord_adapter) { fake_managed_adapter_class.new(next_id: "discord-native-1") }
  let(:telegram_adapter) { fake_managed_adapter_class.new(next_id: "telegram-native-1") }
  let(:adapters) { { [:discord, "discord"] => discord_adapter, [:telegram, "telegram"] => telegram_adapter } }

  let(:scheduler) do
    Struct.new(:jobs) do
      def schedule(kind:, run_at:, payload:, community: nil)
        job = { kind: kind, run_at: run_at, payload: payload, community: community }
        jobs << job
        job
      end
    end.new([])
  end

  subject(:service) do
    described_class.new(models: models, scheduler: scheduler, adapters: adapters, audit: audit, clock: -> { now })
  end

  def job_for(payload)
    Struct.new(:payload).new(payload)
  end

  describe "#request_create" do
    it "enqueues a durable job and writes an audit line" do
      service.request_create(
        community: community, name: "Gaming & Scheduling",
        platforms: [{ adapter: "discord", account: "discord" }], requested_by: "sample_owner"
      )

      expect(scheduler.jobs.size).to eq(1)
      expect(scheduler.jobs.first[:kind]).to eq(described_class::CREATE_KIND)
      expect(scheduler.jobs.first[:payload]["name"]).to eq("Gaming & Scheduling")

      event = audit.query(community: "sample", action: "room_create_requested").first
      expect(event.actor).to eq("sample_owner")
    end

    it "rejects an empty name" do
      expect do
        service.request_create(community: community, name: "  ", platforms: [{ adapter: "discord", account: "discord" }],
                                requested_by: "sample_owner")
      end.to raise_error(described_class::Invalid, /name/)
    end

    it "rejects a platform the community has no connection for" do
      expect do
        service.request_create(
          community: community, name: "Gaming", platforms: [{ adapter: "discord", account: "ghost" }],
          requested_by: "sample_owner"
        )
      end.to raise_error(described_class::Invalid, /ghost/)
    end

    # endpoint_key carries a global unique index, so an unscoped lookup resolves
    # another tenant's channel and its permissions get cloned into the new one.
    it "rejects a template channel belonging to another community" do
      other_id = Rubotty::ControlPlane::Seed.from_model(sample_model, models: models, slug: "other-co")
      theirs = models.channel.where(community_id: other_id, adapter: "discord").first

      expect do
        service.request_create(
          community: community, name: "Gaming",
          platforms: [{ adapter: "discord", account: "discord" }],
          template_channel: theirs.endpoint_key, requested_by: "sample_owner"
        )
      end.to raise_error(described_class::Invalid, /not a channel of community/)
      expect(scheduler.jobs).to be_empty
    end

    it "accepts a template channel of its own community" do
      mine = models.channel.where(community_id: community.id, adapter: "discord").first

      service.request_create(
        community: community, name: "Gaming",
        platforms: [{ adapter: "discord", account: "discord" }],
        template_channel: mine.endpoint_key, requested_by: "sample_owner"
      )

      expect(scheduler.jobs.first[:payload]["template_channel"]).to eq(mine.endpoint_key)
    end

    it "rejects a request naming no platform at all" do
      expect do
        service.request_create(community: community, name: "Gaming", platforms: [], requested_by: "sample_owner")
      end.to raise_error(described_class::Invalid, /platform/)
    end
  end

  describe "#create (the execution side)" do
    def create_payload(platforms:, template: nil)
      { "community_id" => community.id, "name" => "Gaming & Scheduling", "platforms" => platforms,
        "template_channel" => template, "requested_by" => "sample_owner" }
    end

    it "creates a channel on every requested platform and links them into one room" do
      result = service.create(job_for(create_payload(
        platforms: [{ "adapter" => "discord", "account" => "discord" },
                    { "adapter" => "telegram", "account" => "telegram" }]
      )))

      expect(result.status).to eq(:created)
      expect(result.room.label).to eq("Gaming & Scheduling")
      expect(result.channels.map(&:route_key)).to contain_exactly("discord-native-1", "telegram-native-1")
      expect(discord_adapter.created).to eq([{ name: "Gaming & Scheduling", template: nil }])
    end

    # Issue #1783: the adapter used to be handed a bare name and left to work
    # out which space it belonged in, which is what both platforms got wrong.
    it "tells the adapter which community it is provisioning for" do
      service.create(job_for(create_payload(
        platforms: [{ "adapter" => "discord", "account" => "discord" },
                    { "adapter" => "telegram", "account" => "telegram" }]
      )))

      expect(discord_adapter.scoped_to).to eq([community.id])
      expect(telegram_adapter.scoped_to).to eq([community.id])
    end

    it "marks every created channel row provisioned_by_bot" do
      result = service.create(job_for(create_payload(platforms: [{ "adapter" => "discord", "account" => "discord" }])))
      expect(result.channels).to all(have_attributes(provisioned_by_bot: true))
    end

    it "links the created channels into a real room, indistinguishable from a hand-mapped one" do
      result = service.create(job_for(create_payload(platforms: [{ "adapter" => "discord", "account" => "discord" }])))
      linked = models.room_channel.where(room_id: result.room.id).select_map(:channel_id)
      expect(linked).to eq(result.channels.map(&:id))
    end

    it "writes a room_created audit line naming every platform" do
      service.create(job_for(create_payload(platforms: [{ "adapter" => "discord", "account" => "discord" }])))
      event = audit.query(community: "sample", action: "room_created").first
      expect(event.metadata["platforms"]).to eq(["discord/discord"])
    end

    it "copies permissions from a template channel when one is given" do
      template = models.channel.where(community_id: community.id, adapter: "discord").first

      service.create(job_for(create_payload(
        platforms: [{ "adapter" => "discord", "account" => "discord" }], template: template.endpoint_key
      )))

      expect(discord_adapter.copied).to eq([{ from: template.route_key, to: "discord-native-1" }])
    end

    # A route_key from one platform is meaningless, and often rejected outright,
    # when handed to another platform's create_channel. Resolving the template
    # fresh per platform, filtered to that platform's own adapter/account,
    # is what keeps a cross-platform template from reaching the wrong one.
    it "only offers a template to the platform it actually belongs to, in a multi-platform request" do
      template = models.channel.where(community_id: community.id, adapter: "telegram").first

      result = service.create(job_for(create_payload(
        platforms: [{ "adapter" => "discord", "account" => "discord" },
                    { "adapter" => "telegram", "account" => "telegram" }],
        template: template.endpoint_key
      )))

      expect(result.status).to eq(:created)
      expect(discord_adapter.created).to eq([{ name: "Gaming & Scheduling", template: nil }])
      expect(telegram_adapter.created).to eq([{ name: "Gaming & Scheduling", template: template.route_key }])
      expect(discord_adapter.copied).to be_empty
      expect(telegram_adapter.copied).to eq([{ from: template.route_key, to: "telegram-native-1" }])
    end

    # The request side refuses this now, but the job payload outlives the request,
    # so the execution side resolves the key inside the community too.
    it "ignores a template key naming another community's channel" do
      other_id = Rubotty::ControlPlane::Seed.from_model(sample_model, models: models, slug: "other-co")
      theirs = models.channel.where(community_id: other_id, adapter: "discord").first

      service.create(job_for(create_payload(
        platforms: [{ "adapter" => "discord", "account" => "discord" }], template: theirs.endpoint_key
      )))

      expect(discord_adapter.copied).to be_empty
      expect(discord_adapter.created).to eq([{ name: "Gaming & Scheduling", template: nil }])
    end

    it "rolls back every channel it created when one platform fails, leaving no room" do
      discord_adapter.fail_next_create(StandardError.new("guild not found"))
      telegram_adapter # created first in iteration order below

      result = service.create(job_for(create_payload(
        platforms: [{ "adapter" => "telegram", "account" => "telegram" },
                    { "adapter" => "discord", "account" => "discord" }]
      )))

      expect(result.status).to eq(:failed)
      expect(telegram_adapter.deleted).to eq(["telegram-native-1"])
      expect(models.channel.where(route_key: "telegram-native-1").first).to be_nil
      expect(models.room.where(community_id: community.id, label: "Gaming & Scheduling").first).to be_nil
    end

    it "fails cleanly, creating nothing, when a platform reports no support" do
      adapters[[:discord, "discord"]] = nil

      result = service.create(job_for(create_payload(platforms: [{ "adapter" => "discord", "account" => "discord" }])))

      expect(result.status).to eq(:failed)
      expect(result.failures.first).to match(/not supported/)
    end
  end

  describe "#request_delete" do
    let(:room) do
      models.room.where(community_id: community.id).first
    end

    it "requires the room's name typed back before enqueuing anything" do
      expect do
        service.request_delete(community: community, room: room, confirmed_name: "wrong",
                               requested_by: "sample_owner")
      end.to raise_error(described_class::Invalid, /type/)
      expect(scheduler.jobs).to be_empty
    end

    it "accepts the room's label or its room_key, case-insensitively" do
      service.request_delete(community: community, room: room, confirmed_name: room.room_key.upcase,
                             requested_by: "sample_owner")
      expect(scheduler.jobs.size).to eq(1)
      expect(scheduler.jobs.first[:kind]).to eq(described_class::DELETE_KIND)
    end
  end

  describe "#delete (the execution side)" do
    let(:room) { models.room.where(community_id: community.id).first }
    let(:room_channels) { models.channel.where(id: models.room_channel.where(room_id: room.id).select_map(:channel_id)).all }

    def delete_payload(delete_platform_channels: false, force_channel_ids: [])
      { "community_id" => community.id, "room_id" => room.id,
        "delete_platform_channels" => delete_platform_channels, "force_channel_ids" => force_channel_ids,
        "requested_by" => "sample_owner" }
    end

    it "unmaps the room by default without touching any platform channel" do
      result = service.delete(job_for(delete_payload))

      expect(result.status).to eq(:deleted)
      expect(models.room[room.id]).to be_nil
      expect(discord_adapter.deleted).to be_empty
      # The channel rows themselves survive: still discovered, just unmapped.
      expect(room_channels.map { |c| models.channel[c.id] }).to all(be_present)
    end

    it "deletes the platform channel too when opted in, for a channel the bot did not create" do
      # The seeded channels were never provisioned by the bot.
      expect(room_channels).to all(have_attributes(provisioned_by_bot: false))

      service.delete(job_for(delete_payload(delete_platform_channels: true)))

      expect(discord_adapter.deleted).to be_empty
      expect(telegram_adapter.deleted).to be_empty
    end

    it "deletes the platform channel when the admin force-confirms an unprovisioned one" do
      target = room_channels.find { |c| c.adapter == "discord" }

      service.delete(job_for(delete_payload(delete_platform_channels: true, force_channel_ids: [target.id])))

      expect(discord_adapter.deleted).to eq([target.route_key])
      expect(models.channel[target.id]).to be_nil
    end

    it "keeps the channel row when the platform refuses the delete, rather than destroying it anyway" do
      target = room_channels.find { |c| c.adapter == "discord" }
      allow(discord_adapter).to receive(:delete_channel).and_return(false)

      result = service.delete(job_for(delete_payload(delete_platform_channels: true, force_channel_ids: [target.id])))

      expect(models.channel[target.id]).not_to be_nil
      expect(result.failures).to include(a_string_matching(/discord\/discord: the platform refused the delete/))
    end

    it "writes a room_deleted audit line" do
      service.delete(job_for(delete_payload))
      event = audit.query(community: "sample", action: "room_deleted").first
      expect(event.actor).to eq("sample_owner")
    end
  end
end
