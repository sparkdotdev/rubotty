# frozen_string_literal: true

require "spec_helper"

# Issue #1801, the other half of the #1767 incident. The outbound mirror
# recorded the native id only after the platform answered, and Discord pushes
# its gateway create before that reply lands, so the loop guard read
# native_refs too early and mirrored our own event back in as a second one.
RSpec.describe "an echo of our own native create", :control_plane do
  # Blocks inside create_scheduled_event, which is precisely the instant the
  # platform owns the object and nothing here has written its id down yet.
  class EchoRaceAdapter < Rubotty::Adapters::Base
    class << self
      def adapter_name = :discord
    end

    CAPS = Rubotty::Adapters::Capabilities.new(
      edits: true, deletes: false, replies: false, reactions: true
    ).freeze

    def initialize(native_id:, during_create: nil)
      super(account: "discord", settings: {}, dispatcher: nil, logger: Rubotty::Log.null)
      @native_id = native_id
      @during_create = during_create
      @delivered = []
    end

    attr_reader :delivered

    def capabilities = CAPS

    def own_account_id = "dc-bot"

    def start = self

    def stop = self

    def running? = true

    def deliver(message, endpoint)
      @delivered << endpoint.id
      Rubotty::Core::DeliveryReceipt.new(endpoint_id: endpoint.id, native_id: "dc#{@delivered.size}")
    end

    def supports_native_events? = true

    def create_scheduled_event(_event, _endpoint)
      @during_create&.call
      @native_id
    end
  end

  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:registry) { Rubotty::ControlPlane::Registry.new(models: models) }
  let(:community) { models.community.where(slug: "sample").first }
  let(:room) { models.room.where(community_id: community.id, room_key: "gaming").first }

  let(:guild_id) { "9000000000001" }
  let(:native_id) { "1541461319872417862" }

  let(:claims) { Rubotty::Events::NativeCreateClaims.new(timeout: 10.0) }
  let(:scheduling) { Rubotty::ControlPlane::EventScheduling.new(models: models, logger: Rubotty::Log.null) }

  # The two handshakes that drive the ordering, so the race is reproduced
  # rather than hoped for.
  let(:platform_called) { Queue.new }
  let(:release_platform) { Queue.new }

  let(:discord) do
    EchoRaceAdapter.new(native_id: native_id, during_create: lambda {
      platform_called << :called
      release_platform.pop
    })
  end

  let(:announcer) do
    Rubotty::Events::Announcer.new(
      registry: registry, models: models, adapters: { [:discord, "discord"] => discord },
      logger: Rubotty::Log.null, native_claims: claims
    )
  end

  let(:mirror) do
    Rubotty::Events::NativeMirror.new(
      models: models, event_scheduling: scheduling, logger: Rubotty::Log.null, native_claims: claims
    )
  end

  let(:event) do
    scheduling.create(community: community, room: room, as: :operator, title: "AOE3",
                      starts_at: Time.utc(2026, 8, 24, 15, 30, 0), kind: "gaming",
                      created_by: "discord:owner_handle")
  end

  before do
    Rubotty::ControlPlane::FeatureControls.new(models: models)
                                          .enable(community: community, selector: "gaming", feature: "events")
    # Resolve the Discord connection's guild as a live boot would, so the echo
    # maps back to the community it really came from.
    models.platform_connection.where(adapter: "discord").update(external_id: guild_id)
    # Force every memoized helper before a thread can be the first to touch one.
    event
    announcer
    mirror
    platform_called
    release_platform
  end

  def native_change(id)
    Rubotty::Events::NativeEventChange.new(
      adapter: :discord, account: "discord", action: :created, native_id: id, guild_id: guild_id,
      title: "AOE3", starts_at: Time.utc(2026, 8, 24, 15, 30, 0),
      raw: { "entity_metadata" => { "location" => nil } }
    )
  end

  def events = models.event.order(:id).all.map { |row| Rubotty::Events::Event.new(row) }

  # The echo thread can only return before the platform call is released by
  # having decided the native id names nothing, which is the duplicate.
  def run_echo(change)
    inbound = Thread.new do
      platform_called.pop
      mirror.handle(change)
    end
    outbound = Thread.new { announcer.announce_created(event) }

    held = inbound.join(0.5).nil?
    release_platform << :go
    expect(outbound.join(10)).not_to be_nil
    expect(inbound.join(10)).not_to be_nil
    held
  end

  it "is held at the loop guard until the create has recorded its id" do
    expect(run_echo(native_change(native_id))).to be(true)
  end

  it "does not manufacture a second event for the native id we just created" do
    run_echo(native_change(native_id))

    expect(events.size).to eq(1)
    expect(events.first.native_ref("discord")).to eq(native_id)
    expect(events.first.created_by).to eq("discord:owner_handle")
  end

  # The guard delays an inbound create, it does not drop one: somebody really
  # using Discord's own ui while we are mid-mirror still gets their event.
  it "still mirrors in a native event that is genuinely somebody else's" do
    run_echo(native_change("7788990011"))

    expect(events.size).to eq(2)
    expect(events.last.native_ref("discord")).to eq("7788990011")
    expect(events.last.created_by).to eq(Rubotty::Events::NativeMirror::CREATED_BY)
  end
end
