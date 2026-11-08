# frozen_string_literal: true

require "spec_helper"

# The event broadcast: the card on create, the reminder card when a rung fires, the
# cancellation notice on cancel, and the outbound-only native mirror alongside all
# three. Exercised over the seeded SAMPLE "gaming" room with two fake adapters.
RSpec.describe Rubotty::Events::Announcer, :control_plane do
  # A Telegram-ish adapter: no native-event support, and nothing overridden, so the
  # default Adapters::Base fallback renderer is what runs.
  class FakePlainAdapter < Rubotty::Adapters::Base
    class << self
      def adapter_name = :telegram
    end

    CAPS = Rubotty::Adapters::Capabilities.new(
      edits: true, deletes: false, replies: false, reactions: true
    ).freeze

    def initialize
      super(account: "telegram", settings: {}, dispatcher: nil, logger: Rubotty::Log.null)
      @delivered = []
      @edited = []
      @synced = []
      @dms = []
      @fail_next = false
      @refuse_dms = false
    end

    attr_reader :delivered, :edited, :synced, :dms

    def fail_next! = (@fail_next = true)

    def refuse_dms! = (@refuse_dms = true)

    def supports_admin_dm? = true

    def send_admin_dm(native_id, text)
      return nil if @refuse_dms

      (@dms ||= []) << [native_id, text]
      true
    end

    def capabilities = CAPS

    def own_account_id = "tg-bot"

    def start = self

    def stop = self

    def running? = true

    def deliver(message, endpoint)
      if @fail_next
        @fail_next = false
        raise Rubotty::AdapterError.new("nope", adapter: :telegram)
      end
      @delivered << [endpoint.id, message]
      Rubotty::Core::DeliveryReceipt.new(endpoint_id: endpoint.id, native_id: "tg#{@delivered.size}")
    end

    def edit(message, endpoint, native_id)
      @edited << [endpoint.id, native_id, message]
      Rubotty::Core::DeliveryReceipt.new(endpoint_id: endpoint.id, native_id: native_id)
    end

    def sync_reactions(endpoint, native_id, desired:, previous: [])
      @synced << { endpoint_id: endpoint.id, native_id: native_id, desired: desired }
      nil
    end
  end

  # A Discord-ish adapter: native-event capable, and its own <t:UNIX:...>
  # timestamp rendering, mirroring Adapters::Discord::Adapter's override.
  class FakeNativeAdapter < Rubotty::Adapters::Base
    class << self
      def adapter_name = :discord
    end

    CAPS = FakePlainAdapter::CAPS

    def initialize
      super(account: "discord", settings: {}, dispatcher: nil, logger: Rubotty::Log.null)
      @delivered = []
      @edited = []
      @synced = []
      @created = []
      @created_endpoints = []
      @updated = []
      @updated_endpoints = []
      @deleted = []
      @deleted_endpoints = []
      @dms = []
      @next_id = 0
    end

    attr_reader :delivered, :edited, :synced, :created, :created_endpoints, :updated, :updated_endpoints,
                :deleted, :deleted_endpoints, :dms

    def supports_admin_dm? = true

    def send_admin_dm(native_id, text)
      @dms << [native_id, text]
      true
    end

    def capabilities = CAPS

    def own_account_id = "dc-bot"

    def start = self

    def stop = self

    def running? = true

    def deliver(message, endpoint)
      @delivered << [endpoint.id, message]
      Rubotty::Core::DeliveryReceipt.new(endpoint_id: endpoint.id, native_id: "dc#{@delivered.size}")
    end

    def edit(message, endpoint, native_id)
      @edited << [endpoint.id, native_id, message]
      Rubotty::Core::DeliveryReceipt.new(endpoint_id: endpoint.id, native_id: native_id)
    end

    def sync_reactions(endpoint, native_id, desired:, previous: [])
      @synced << { endpoint_id: endpoint.id, native_id: native_id, desired: desired }
      nil
    end

    def supports_native_events? = true

    def create_scheduled_event(event, endpoint = nil)
      @next_id += 1
      @created << event
      @created_endpoints << endpoint
      @next_id.to_s
    end

    def update_scheduled_event(native_id, event, endpoint = nil)
      @updated << [native_id, event]
      @updated_endpoints << endpoint
    end

    def delete_scheduled_event(native_id, endpoint = nil)
      @deleted << native_id
      @deleted_endpoints << endpoint
    end

    def render_timestamp(time, style: :full, tz: nil, now: nil)
      unix = time.to_i
      case style.to_sym
      when :relative then "<t:#{unix}:R>"
      when :both then "<t:#{unix}:F> <t:#{unix}:R>"
      else "<t:#{unix}:F>"
      end
    end
  end

  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:registry) { Rubotty::ControlPlane::Registry.new(models: models) }
  let(:community) { models.community.where(slug: "sample").first }
  let(:room) { models.room.where(community_id: community.id, room_key: "gaming").first }

  let(:tg) { FakePlainAdapter.new }
  let(:dc) { FakeNativeAdapter.new }
  let(:adapter_map) { { [:telegram, "telegram"] => tg, [:discord, "discord"] => dc } }
  let(:controls) { Rubotty::ControlPlane::FeatureControls.new(models: models, registry: registry) }
  let(:storage) { Rubotty::Storage::Memory.new }

  let(:now) { Time.now }

  subject(:announcer) do
    described_class.new(registry: registry, models: models, adapters: adapter_map, logger: Rubotty::Log.null,
                        storage: storage, clock: -> { now })
  end

  # The room stores an empty zone list, which is how it says it wants the fixed
  # single-zone rendering rather than the shipped default expansion.
  def zones_off!
    controls.set(community: registry.current.community("sample"), selector: "gaming",
                 feature: "bridge", key: "timestamp_timezones", value: [])
  end

  def gaming_event(overrides = {})
    row = models.event.create(
      **{
        community_id: community.id, room_id: room.id, title: "Raid Night",
        starts_at: now + (2 * 86_400), kind: "gaming", timezone: "Europe/Lisbon",
        game_title: "Counter-Strike 2", server_address: "1.2.3.4:7777",
        rsvp_mode: "none", status: "scheduled", native_refs: "{}",
        created_at: now, updated_at: now
      }.merge(overrides)
    )
    Rubotty::Events::Event.new(row)
  end

  def general_event(overrides = {})
    gaming_event({ kind: "general", game_title: nil, server_address: nil,
                   url: "https://meet.example/room" }.merge(overrides))
  end

  def reload(event) = Rubotty::Events::Event.new(event.row.refresh)

  describe "#announce_created: the card" do
    it "delivers a card to every endpoint in the room" do
      announcer.announce_created(gaming_event)
      expect(tg.delivered.map(&:first)).to eq(["tg-gaming"])
      expect(dc.delivered.map(&:first)).to eq(["dc-gaming"])
    end

    it "renders the start time through EACH endpoint's own adapter" do
      zones_off!
      event = gaming_event
      announcer.announce_created(event)

      tg_text = tg.delivered.first.last.body.text
      dc_text = dc.delivered.first.last.body.text

      expect(dc_text).to include("<t:#{event.starts_at.to_i}:F>", "<t:#{event.starts_at.to_i}:R>")
      expect(tg_text).not_to include("<t:")
      expect(tg_text).to include(Rubotty::Util::EventTimestamps.full(event.starts_at, "Europe/Lisbon"))
    end

    # The room here has never touched Bridge#timestamp_timezones, which used to
    # mean a raw "+0000" offset nobody could read at a glance.
    it "renders the shipped default zones in a room that configured none" do
      event = gaming_event

      announcer.announce_created(event)

      tg_text = tg.delivered.first.last.body.text
      expanded = Rubotty::Features::TimestampExpansion.render(
        event.starts_at,
        Rubotty::Features::TimestampExpansion.zones_for_config({}),
        Time.now
      )

      expect(tg_text).to include(expanded)
      expect(tg_text).to include("Pacific", "Eastern", "Western Europe", "Central Europe")
      expect(tg_text).not_to include("+0000")
    end

    it "keeps Discord's own markup in a room that configured none either" do
      event = gaming_event

      announcer.announce_created(event)

      expect(dc.delivered.first.last.body.text)
        .to include("<t:#{event.starts_at.to_i}:F>", "<t:#{event.starts_at.to_i}:R>")
    end

    # Issue: a non-Discord card used to show the fixed-zone fallback's raw
    # "+0000" offset even in a room that configured Bridge#timestamp_timezones
    # for exactly this purpose (readable per-reader zones, day-labelled). A
    # Discord target still keeps its own native <t:...> markup regardless.
    it "renders the community's configured multi-timezone text instead, when the room set one" do
      controls.set(
        community: registry.current.community("sample"), selector: "gaming", feature: "bridge",
        key: "timestamp_timezones", value: [{ label: "Pacific", iana_timezone: "America/Los_Angeles" }]
      )
      event = gaming_event

      announcer.announce_created(event)

      tg_text = tg.delivered.first.last.body.text
      dc_text = dc.delivered.first.last.body.text
      expanded = Rubotty::Features::TimestampExpansion.render(
        event.starts_at,
        [Rubotty::Features::TimestampExpansion::Zone.new(label: "Pacific", iana_timezone: "America/Los_Angeles")],
        Time.now
      )

      expect(tg_text).to include(expanded)
      expect(tg_text).not_to include("+0000")
      expect(dc_text).to include("<t:#{event.starts_at.to_i}:F>", "<t:#{event.starts_at.to_i}:R>")
    end

    it "includes the title and the gaming fields, and shows nothing rsvp-related for a none-mode event" do
      announcer.announce_created(gaming_event)
      text = tg.delivered.first.last.body.text
      expect(text).to include("Raid Night")
      expect(text).to include("Game: Counter-Strike 2 @ 1.2.3.4:7777")
      expect(text).not_to match(/Going|Maybe|Attending/)
    end

    it "renders a general event's url as a Link line instead" do
      announcer.announce_created(general_event)
      text = tg.delivered.first.last.body.text
      expect(text).to include("Link: https://meet.example/room")
      expect(text).not_to include("Game:")
    end

    it "labels an http url as a Link too, not only https" do
      announcer.announce_created(general_event(url: "http://meet.example/room"))
      expect(tg.delivered.first.last.body.text).to include("Link: http://meet.example/room")
    end

    it "does not call free text a Link, showing it as a place instead" do
      announcer.announce_created(general_event(url: "Location TBD"))
      text = tg.delivered.first.last.body.text
      expect(text).not_to include("Link:")
      expect(text).to include("Where: Location TBD")
    end

    it "does not call a non-web scheme a Link either" do
      announcer.announce_created(general_event(url: "ftp://files.example/plans"))
      text = tg.delivered.first.last.body.text
      expect(text).not_to include("Link:")
      expect(text).to include("Where: ftp://files.example/plans")
    end

    it "omits the Game line entirely when a gaming event names neither field" do
      announcer.announce_created(gaming_event(game_title: nil, server_address: nil))
      expect(tg.delivered.first.last.body.text).not_to include("Game:")
    end

    it "posts as the bot, under a system author" do
      announcer.announce_created(gaming_event)
      message = tg.delivered.first.last
      expect(message.kind).to eq(:chat).or eq(:system)
      expect(message.author.kind).to eq(:system)
    end

    it "does not stop at one endpoint's delivery failure; the rest still get their copy" do
      tg.fail_next!
      expect { announcer.announce_created(gaming_event) }.not_to raise_error
      expect(dc.delivered.size).to eq(1)
    end

    it "is a no-op, and never raises, without a control plane" do
      no_registry = described_class.new(registry: nil, models: models, adapters: adapter_map)
      expect { no_registry.announce_created(gaming_event) }.not_to raise_error
      expect(tg.delivered).to be_empty
    end

    it "is a no-op, and never raises, for an event whose room no longer exists" do
      event = gaming_event
      room.destroy
      expect { announcer.announce_created(event) }.not_to raise_error
      expect(tg.delivered).to be_empty
    end

    it "still announces to the event's own room while its channel is briefly linked into " \
       "another room too (issue #1694)" do
      # Dashboard::App's channel-mapping route links a channel into its new
      # room before unlinking it from the old one, so room_channels briefly
      # holds a row for both. Reproduce that without unlinking, and confirm
      # resolve_room picks the room the event names, not whichever comes first.
      general = models.room.where(community_id: community.id, room_key: "general").first
      dc_gaming_channel = models.channel.where(community_id: community.id, endpoint_key: "dc-gaming").first
      mapper = Rubotty::ControlPlane::ChannelMapper.new(models: models, registry: registry)
      mapper.map(community: community, selectors: [dc_gaming_channel.endpoint_key], room_key: general.room_key)

      announcer.announce_created(gaming_event)

      expect(tg.delivered.map(&:first)).to eq(["tg-gaming"])
      expect(dc.delivered.map(&:first)).to eq(["dc-gaming"])
    end
  end

  describe "#announce_created: the native mirror" do
    it "creates a native event on the one native-capable adapter and stores its id" do
      event = gaming_event
      announcer.announce_created(event)

      expect(dc.created).to eq([event])
      expect(reload(event).native_ref("discord")).to eq("1")
    end

    it "never asks the non-native adapter to create one" do
      # supports_native_events? defaults to false on Adapters::Base, so FakePlainAdapter
      # must never be invoked; the mirror only ever writes a "discord" key.
      event = gaming_event
      announcer.announce_created(event)
      expect(reload(event).native_refs.keys).to eq(["discord"])
    end

    # Issue #1701: one adapter INSTANCE can bridge more than one room (guild,
    # for the real Discord adapter), so the call has to carry that room's own
    # endpoint rather than always the same one. SAMPLE's seeded "general" room
    # bridges through the same shared dc adapter as "gaming" does.
    it "passes the room's own endpoint to the adapter, not always the same one" do
      general_room = models.room.where(community_id: community.id, room_key: "general").first
      announcer.announce_created(gaming_event)
      announcer.announce_created(gaming_event(room_id: general_room.id))

      expect(dc.created_endpoints.map(&:id)).to eq(%w[dc-gaming dc-general])
    end
  end

  describe "#announce_created: the rsvp line and seeded reactions (issue #184, wave 3b)" do
    def affirm_event(overrides = {})
      gaming_event({ rsvp_mode: "affirm" }.merge(overrides))
    end

    def full_event(overrides = {})
      gaming_event({ rsvp_mode: "full" }.merge(overrides))
    end

    # The line above this one is the start time with its relative form, so a
    # reader arriving at a bare count is still reading times: "In: 5" was taken
    # for five minutes rather than five people.
    it "says nobody yet, not a zero, for a fresh affirm-mode event" do
      announcer.announce_created(affirm_event)
      text = tg.delivered.first.last.body.text
      expect(text).to include("Attending: nobody yet")
      expect(text).not_to match(/Attending: 0|In:/)
    end

    it "names the one person who is in, rather than counting them" do
      event = affirm_event
      models.event_rsvp.create(event_id: event.id, identity: "u1", platform: "telegram",
                               response: "in", responded_at: now)
      announcer.announce_created(event)

      expect(tg.delivered.first.last.body.text).to include("Attending: @u1")
    end

    it "labels the collapsed count too, once a fourth person is in" do
      event = affirm_event
      4.times do |i|
        models.event_rsvp.create(event_id: event.id, identity: "u#{i}", platform: "telegram",
                                 response: "in", responded_at: now)
      end
      announcer.announce_created(event)

      expect(tg.delivered.first.last.body.text).to include("Attending: 4")
    end

    it "shows the zeroed full tally for a fresh full-mode event" do
      announcer.announce_created(full_event)
      expect(tg.delivered.first.last.body.text).to include("Going 0, Maybe 0, No 0")
    end

    it "folds recorded event_rsvps rows into the line, naming who answered" do
      event = full_event
      models.event_rsvp.create(event_id: event.id, identity: "u1", platform: "telegram",
                               response: "yes", responded_at: now)
      models.event_rsvp.create(event_id: event.id, identity: "u2", platform: "telegram",
                               response: "maybe", responded_at: now)
      announcer.announce_created(event)
      expect(tg.delivered.first.last.body.text).to include("Going @u1, Maybe @u2, No 0")
    end

    it "prints the handle the identity directory knows, not the raw native id" do
      event = full_event
      models.observed_identity.create(
        community_id: community.id, adapter: "telegram", native_id: "44120",
        username: "ada", first_seen_at: now, last_seen_at: now
      )
      models.event_rsvp.create(event_id: event.id, identity: "44120", platform: "telegram",
                               response: "yes", responded_at: now)
      announcer.announce_created(event)

      expect(tg.delivered.first.last.body.text).to include("Going @ada,")
    end

    it "qualifies a handle from another platform, and leaves the reader's own bare" do
      event = full_event
      models.event_rsvp.create(event_id: event.id, identity: "u1", platform: "telegram",
                               response: "yes", responded_at: now)
      announcer.announce_created(event)

      expect(tg.delivered.first.last.body.text).to include("Going @u1,")
      expect(dc.delivered.first.last.body.text).to include("Going @u1@telegram,")
    end

    it "collapses to a bare count once a fourth person answers the same way" do
      event = full_event
      4.times do |i|
        models.event_rsvp.create(event_id: event.id, identity: "u#{i}", platform: "telegram",
                                 response: "yes", responded_at: now)
      end
      announcer.announce_created(event)

      expect(tg.delivered.first.last.body.text).to include("Going 4, Maybe 0, No 0")
    end

    it "seeds the single affirm reaction on every reaction-capable adapter" do
      announcer.announce_created(affirm_event)
      expect(tg.synced.first[:desired]).to eq([Rubotty::Events::RsvpReactions::GOING])
      expect(dc.synced.first[:desired]).to eq([Rubotty::Events::RsvpReactions::GOING])
    end

    it "seeds all three reactions, oldest first, for a full-mode event" do
      announcer.announce_created(full_event)
      expect(tg.synced.first[:desired]).to eq(
        [Rubotty::Events::RsvpReactions::GOING, Rubotty::Events::RsvpReactions::MAYBE,
         Rubotty::Events::RsvpReactions::NO]
      )
    end

    it "seeds nothing for a none-mode event" do
      announcer.announce_created(gaming_event)
      expect(tg.synced).to be_empty
    end
  end

  describe "#event_for_card" do
    it "resolves a tracked card copy's ref back to its event" do
      event = gaming_event
      announcer.announce_created(event)
      # The adapter's own delivery-receipt native id, as tracked into event_cards,
      # rather than the placeholder the outbound Core::Message carried.
      native_id = models.event_card.where(event_id: event.id, endpoint_id: "tg-gaming").first.native_id

      resolved = announcer.event_for_card(Rubotty::Core::MessageRef.new("tg-gaming", native_id))
      expect(resolved.id).to eq(event.id)
    end

    it "is nil for a ref that names no tracked card" do
      expect(announcer.event_for_card(Rubotty::Core::MessageRef.new("tg-gaming", "nope"))).to be_nil
    end

    it "is nil without a control plane" do
      no_registry = described_class.new(registry: nil, models: models, adapters: adapter_map)
      expect(no_registry.event_for_card(Rubotty::Core::MessageRef.new("tg-gaming", "1"))).to be_nil
    end
  end

  describe "#holds_card?" do
    it "is true for a tracked card copy's (endpoint_id, native_id)" do
      event = gaming_event
      announcer.announce_created(event)
      native_id = models.event_card.where(event_id: event.id, endpoint_id: "tg-gaming").first.native_id

      expect(announcer.holds_card?("tg-gaming", native_id)).to be(true)
    end

    it "is false for the right native id on the wrong endpoint, or the wrong native id" do
      event = gaming_event
      announcer.announce_created(event)
      native_id = models.event_card.where(event_id: event.id, endpoint_id: "tg-gaming").first.native_id

      expect(announcer.holds_card?("tg-general", native_id)).to be(false)
      expect(announcer.holds_card?("tg-gaming", "nope")).to be(false)
    end

    it "is false, not a raise, without a models service" do
      no_models = described_class.new(registry: registry, models: nil, adapters: adapter_map)
      expect(no_models.holds_card?("tg-gaming", "1")).to be(false)
    end
  end

  describe "#refresh_rsvp" do
    it "edits every tracked copy of the card with the refreshed tally" do
      event = gaming_event(rsvp_mode: "full")
      announcer.announce_created(event)
      tg.edited.clear
      dc.edited.clear

      models.event_rsvp.create(event_id: event.id, identity: "u1", platform: "telegram",
                               response: "yes", responded_at: now)
      announcer.refresh_rsvp(reload(event))

      expect(tg.edited.size).to eq(1)
      expect(tg.edited.first.last.body.text).to include("Going @u1, Maybe 0, No 0")
      expect(dc.edited.size).to eq(1)
      expect(dc.edited.first.last.body.text).to include("Going @u1@telegram, Maybe 0, No 0")
    end

    it "edits the SAME native id the card was originally posted under" do
      event = gaming_event(rsvp_mode: "affirm")
      announcer.announce_created(event)
      native_id = models.event_card.where(event_id: event.id, endpoint_id: "tg-gaming").first.native_id
      tg.edited.clear

      announcer.refresh_rsvp(reload(event))
      expect(tg.edited.first[1]).to eq(native_id)
    end

    it "is a no-op, and never raises, without a control plane" do
      no_registry = described_class.new(registry: nil, models: models, adapters: adapter_map)
      expect { no_registry.refresh_rsvp(gaming_event) }.not_to raise_error
    end

    it "is a no-op for an event with no tracked card at all" do
      event = gaming_event
      expect { announcer.refresh_rsvp(event) }.not_to raise_error
      expect(tg.edited).to be_empty
    end
  end

  describe "#announce_reminder" do
    def going!(event, identity, platform: "telegram")
      models.event_rsvp.create(event_id: event.id, identity: identity, platform: platform,
                               response: "yes", responded_at: now)
    end

    def rsvp_event(overrides = {}) = gaming_event({ rsvp_mode: "full" }.merge(overrides))

    it "DMs each person who said they are coming, and posts nothing in the room" do
      event = rsvp_event
      going!(event, "u1")
      announcer.announce_reminder(event, 3600)

      expect(tg.dms.map(&:first)).to eq(["u1"])
      expect(tg.delivered).to be_empty
      expect(dc.delivered).to be_empty
    end

    it "carries the duration phrase and the localized timestamp into the DM" do
      zones_off!
      event = rsvp_event(starts_at: now + 3600)
      going!(event, "u1")
      announcer.announce_reminder(event, 3600)

      expect(tg.dms.first.last).to start_with("Raid Night starts in 1 hour")
      expect(tg.dms.first.last).to include(
        Rubotty::Util::EventTimestamps.full(event.starts_at, "Europe/Lisbon")
      )
    end

    it "phrases the shorter and longer rungs the way the ladder names them" do
      soon = rsvp_event(starts_at: now + 900)
      going!(soon, "u1")
      announcer.announce_reminder(soon, 900)

      distant = rsvp_event(starts_at: now + 604_800)
      going!(distant, "u1")
      announcer.announce_reminder(distant, 604_800)

      expect(tg.dms.map(&:last).first).to start_with("Raid Night starts in 15 minutes")
      expect(tg.dms.map(&:last).last).to start_with("Raid Night starts in 1 week")
    end

    # A rung the scheduler ran late (a recovered downtime, a busy tick) must
    # never tell someone an hour remains once the event has actually begun.
    it "phrases a rung that fired late off how much time is really left, not the rung it fired as" do
      event = rsvp_event(starts_at: now - 60)
      going!(event, "u1")
      announcer.announce_reminder(event, 3600)

      expect(tg.dms.first.last).not_to start_with("Raid Night starts in 1 hour")
      expect(tg.dms.first.last).to start_with("Raid Night starts in 0 seconds")
    end

    it "reaches each person on their own platform" do
      event = rsvp_event
      going!(event, "u1")
      going!(event, "d1", platform: "discord")
      announcer.announce_reminder(event, 3600)

      expect(tg.dms.map(&:first)).to eq(["u1"])
      expect(dc.dms.map(&:first)).to eq(["d1"])
    end

    it "leaves out anybody who did not say yes" do
      event = rsvp_event
      going!(event, "u1")
      models.event_rsvp.create(event_id: event.id, identity: "u2", platform: "telegram",
                               response: "no", responded_at: now)
      announcer.announce_reminder(event, 3600)

      expect(tg.dms.map(&:first)).to eq(["u1"])
    end

    it "reminds nobody at all for an event with no RSVPs" do
      announcer.announce_reminder(gaming_event, 3600)

      expect(tg.dms).to be_empty
      expect(tg.delivered).to be_empty
    end

    # Falling back to the channel would put back exactly the noise this removes.
    it "skips a refused DM rather than announcing it in the room" do
      event = rsvp_event
      going!(event, "u1")
      going!(event, "d1", platform: "discord")
      tg.refuse_dms!

      expect { announcer.announce_reminder(event, 3600) }.not_to raise_error
      expect(tg.delivered).to be_empty
      expect(dc.dms.map(&:first)).to eq(["d1"])
    end

    it "skips somebody whose platform is no longer in the room" do
      event = rsvp_event
      going!(event, "x1", platform: "irc")

      expect { announcer.announce_reminder(event, 3600) }.not_to raise_error
      expect(tg.dms).to be_empty
      expect(tg.delivered).to be_empty
    end
  end

  describe "#announce_reminder_now" do
    it "posts into every endpoint of the room, not a DM, unlike the automated ladder" do
      event = gaming_event
      announcer.announce_reminder_now(event)

      expect(tg.delivered.map(&:first)).to eq(["tg-gaming"])
      expect(dc.delivered.map(&:first)).to eq(["dc-gaming"])
      expect(tg.dms).to be_empty
    end

    # An announcer pinned to an instant nowhere near the wall clock, so a
    # rendering that quietly read Time.now instead shows up as a wild countdown.
    def announcer_pinned_to(instant)
      described_class.new(registry: registry, models: models, adapters: adapter_map,
                          logger: Rubotty::Log.null, storage: storage, clock: -> { instant })
    end

    # The parenthesised countdown belongs to the fixed single-zone rendering, so
    # the three cases below turn the multi-zone expansion off to read it.
    def hour_out_text(event)
      "Raid Night starts in 1 hour\n" \
        "#{Rubotty::Util::EventTimestamps.full(event.starts_at, "Europe/Lisbon")} (in 1 hour)"
    end

    it "reuses reminder_text: the same duration phrase and timestamp the automated DM carries" do
      zones_off!
      event = gaming_event(starts_at: now + 3600)
      announcer.announce_reminder_now(event)

      expect(tg.delivered.first.last.body.text).to eq(hour_out_text(event))
    end

    it "phrases both halves off the injected clock rather than the wall clock" do
      zones_off!
      pinned = Time.utc(2035, 6, 1, 12, 0, 0)
      event = gaming_event(starts_at: pinned + 3600)
      announcer_pinned_to(pinned).announce_reminder_now(event)

      expect(tg.delivered.first.last.body.text).to eq(hour_out_text(event))
    end

    # A shade under the hour is where the two halves used to disagree, one
    # truncating and the other rounding. Both floor now, so both say the same
    # thing, and the thing they say is the honest one.
    it "reads a gap a shade under the hour the same way in both halves" do
      zones_off!
      pinned = Time.utc(2035, 6, 1, 12, 0, 0)
      event = gaming_event(starts_at: pinned + 3599.7)
      announcer_pinned_to(pinned).announce_reminder_now(event)

      text = tg.delivered.first.last.body.text
      expect(text).to start_with("Raid Night starts in 59 minutes")
      expect(text).to include("(in 59 minutes)")
    end

    # A backend that keeps whole seconds hands back a start a fraction under the
    # hour, which truncating the gap called 59 minutes.
    it "still calls it an hour when the stored start lost its fraction of a second" do
      event = gaming_event(starts_at: Time.at((now + 3600).to_i))
      announcer.announce_reminder_now(event)

      expect(tg.delivered.first.last.body.text).to start_with("Raid Night starts in 1 hour")
    end

    it "carries the card's own Attending wording rather than a second one of its own" do
      event = gaming_event(rsvp_mode: "affirm", starts_at: now + 3600)
      models.event_rsvp.create(event_id: event.id, identity: "u1", platform: "telegram",
                               response: "in", responded_at: now)
      announcer.announce_reminder_now(reload(event))

      expect(tg.delivered.first.last.body.text).to include("Attending: @u1")
    end

    it "returns true once it reaches at least one live endpoint" do
      expect(announcer.announce_reminder_now(gaming_event)).to be(true)
    end

    it "returns false when the room cannot be resolved" do
      no_registry = described_class.new(registry: nil, models: models, adapters: adapter_map)
      expect(no_registry.announce_reminder_now(gaming_event)).to be(false)
    end
  end

  describe "#roster" do
    it "lists every response, untruncated, unlike the card's own summary line" do
      event = gaming_event(rsvp_mode: "full")
      4.times do |i|
        models.event_rsvp.create(event_id: event.id, identity: "u#{i}", platform: "telegram",
                                 response: "yes", responded_at: now)
      end
      roster = announcer.roster(event)
      expect(roster["yes"].map(&:identity)).to eq(%w[u0 u1 u2 u3])
    end

    it "is empty for an event nobody has answered yet" do
      expect(announcer.roster(gaming_event(rsvp_mode: "full"))).to eq({})
    end

    it "is empty outright for a none-mode event" do
      event = gaming_event
      models.event_rsvp.create(event_id: event.id, identity: "u1", platform: "telegram",
                               response: "yes", responded_at: now)
      expect(announcer.roster(event)).to eq({})
    end
  end

  describe "#announce_cancelled" do
    it "posts a short cancellation notice naming the event" do
      event = gaming_event
      announcer.announce_cancelled(event)
      expect(tg.delivered.first.last.body.text).to include("cancelled")
      expect(tg.delivered.first.last.body.text).to include("Raid Night")
    end

    it "deletes the native mirror and clears native_refs" do
      event = gaming_event
      announcer.announce_created(event) # creates the native id first
      dc.delivered.clear # isolate the cancel-time delivery below

      announcer.announce_cancelled(reload(event))

      expect(dc.deleted).to eq(["1"])
      expect(reload(event).native_refs).to eq({})
    end

    it "does nothing to delete when the event never had a native mirror" do
      event = gaming_event # never announced created, so native_refs is still "{}"
      announcer.announce_cancelled(event)
      expect(dc.deleted).to be_empty
    end

    # Issue #1701: a cancel resolves the mirror's platform from the shared
    # adapter map, then had nothing naming which of that adapter's rooms the
    # call was actually for. event.room_id is what recovers it, even for a
    # room other than whichever one happens to be seeded first.
    it "deletes through the room's own endpoint, not always the same one" do
      general_room = models.room.where(community_id: community.id, room_key: "general").first
      event = gaming_event(room_id: general_room.id)
      announcer.announce_created(event)

      announcer.announce_cancelled(reload(event))

      expect(dc.deleted_endpoints.last&.id).to eq("dc-general")
    end
  end

  # Events::Lifecycle calls this on every fingerprint change, and the card it
  # posts is seeded with the RSVP reactions, so an untracked copy collects
  # responses that resolve to no event at all.
  describe "#announce_updated: the re-posted card" do
    def tracked_native_id(endpoint_id = "tg-gaming")
      models.event_card.where(endpoint_id: endpoint_id).first&.native_id
    end

    it "tracks the copy it posts, so a reaction on it resolves back to the event" do
      event = gaming_event(rsvp_mode: "full")
      announcer.announce_created(event)
      first_card = tracked_native_id

      announcer.announce_updated(reload(event))
      reposted = tracked_native_id

      expect(reposted).not_to eq(first_card)
      expect(announcer.event_for_card(Rubotty::Core::MessageRef.new("tg-gaming", reposted))&.id).to eq(event.id)
    end

    it "supersedes the copy it replaced rather than tracking two per endpoint" do
      event = gaming_event(rsvp_mode: "full")
      announcer.announce_created(event)

      announcer.announce_updated(reload(event))

      expect(models.event_card.where(event_id: event.id, endpoint_id: "tg-gaming").count).to eq(1)
      expect(tracked_native_id).to eq("tg#{tg.delivered.size}")
    end

    it "refreshes the tally on the card that is actually live" do
      event = gaming_event(rsvp_mode: "affirm")
      announcer.announce_created(event)
      announcer.announce_updated(reload(event))
      newest = "tg#{tg.delivered.size}"
      tg.edited.clear

      models.event_rsvp.create(event_id: event.id, identity: "u1", platform: "telegram",
                               response: "yes", responded_at: now)
      announcer.refresh_rsvp(reload(event))

      expect(tg.edited.map { |edit| edit[1] }).to eq([newest])
    end

    # Before the fix, #refresh_one always re-rendered under the literal "New
    # event" heading, so an RSVP on a card already re-posted as an update
    # relabeled it back to brand new.
    it "keeps the Event updated heading when an RSVP refreshes the re-posted card" do
      event = gaming_event(rsvp_mode: "affirm")
      announcer.announce_created(event)
      announcer.announce_updated(reload(event))
      tg.edited.clear

      models.event_rsvp.create(event_id: event.id, identity: "u1", platform: "telegram",
                               response: "yes", responded_at: now)
      announcer.refresh_rsvp(reload(event))

      text = tg.edited.first.last.body.text
      expect(text).to start_with("Event updated:")
      expect(text).not_to start_with("New event:")
    end

    # Issue #1701: the same "which room" gap #announce_cancelled had, on the
    # update path.
    it "updates through the room's own endpoint, not always the same one" do
      general_room = models.room.where(community_id: community.id, room_key: "general").first
      event = gaming_event(room_id: general_room.id)
      announcer.announce_created(event)

      announcer.announce_updated(reload(event))

      expect(dc.updated_endpoints.last&.id).to eq("dc-general")
    end
  end

  # Issue: a /delete or /pin on an event card only reached the ONE platform's
  # copy the command was issued against; every other platform reported
  # "not_found" though the message existed there too. Announcer posts through
  # each adapter directly, not Bridge's relay, which used to write the message map.
  describe "cross-platform resolution (the message map link)" do
    it "links a created card's copies, resolvable from either platform" do
      event = gaming_event
      announcer.announce_created(event)

      tg_ref = Rubotty::Core::MessageRef.new("tg-gaming", "tg1")
      dc_ref = Rubotty::Core::MessageRef.new("dc-gaming", "dc1")

      expect(storage.counterparts(tg_ref, endpoint_id: "dc-gaming").first).to eq(dc_ref)
      expect(storage.origins(dc_ref).find { |ref| ref.endpoint_id == "tg-gaming" }).to eq(tg_ref)
    end

    it "links a cancellation notice's copies, separately from the card's own" do
      event = gaming_event
      announcer.announce_created(event) # posts tg1/dc1, already linked
      announcer.announce_cancelled(reload(event)) # posts tg2/dc2

      tg_ref = Rubotty::Core::MessageRef.new("tg-gaming", "tg2")
      expect(storage.counterparts(tg_ref, endpoint_id: "dc-gaming").first)
        .to eq(Rubotty::Core::MessageRef.new("dc-gaming", "dc2"))
    end

    it "never raises without a storage service, the same posture every other injected dependency takes" do
      bare = described_class.new(registry: registry, models: models, adapters: adapter_map,
                                 logger: Rubotty::Log.null, storage: nil)
      expect { bare.announce_created(gaming_event) }.not_to raise_error
    end

    it "does not link a single-endpoint broadcast, since there is nothing to link" do
      solo = described_class.new(
        registry: registry, models: models, adapters: { [:telegram, "telegram"] => tg }, logger: Rubotty::Log.null,
        storage: storage
      )
      solo.announce_created(gaming_event)
      expect(storage.counterparts(Rubotty::Core::MessageRef.new("tg-gaming", "tg1"))).to be_empty
    end
  end
end
