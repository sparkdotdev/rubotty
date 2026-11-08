# frozen_string_literal: true

require "spec_helper"

# The inbound Discord-native mirror: a Guild Scheduled Event created in Discord's
# own ui, reflected into a Rubotty event through the plain EventScheduling writer,
# so Events::Lifecycle then broadcasts it to the other platforms.
RSpec.describe Rubotty::Events::NativeMirror, :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }
  let(:gaming) { models.room.where(community_id: community.id, room_key: "gaming").first }

  let(:scheduling) { Rubotty::ControlPlane::EventScheduling.new(models: models, logger: Rubotty::Log.null) }

  subject(:mirror) do
    described_class.new(models: models, event_scheduling: scheduling, logger: Rubotty::Log.null)
  end

  let(:guild_id) { "9000000000001" }

  before do
    Rubotty::ControlPlane::FeatureControls.new(models: models)
                                          .enable(community: community, selector: "gaming", feature: "events")
    # Resolve the Discord connection's guild id, as GuildResolver would on a
    # live boot, so a change carrying that guild maps back to this community.
    models.platform_connection.where(adapter: "discord").update(external_id: guild_id)
  end

  def native_change(action:, native_id: "N1", title: "Movie Night",
                    starts_at: Time.utc(2026, 8, 1, 20, 0, 0), ends_at: nil,
                    location: "https://zoom.us/j/1", description: "Bring popcorn",
                    guild: guild_id, adapter: :discord, account: "discord")
    Rubotty::Events::NativeEventChange.new(
      adapter: adapter, account: account, action: action, native_id: native_id, guild_id: guild,
      title: title, starts_at: starts_at, ends_at: ends_at,
      raw: { "description" => description, "entity_metadata" => { "location" => location } }
    )
  end

  def events = models.event.where(community_id: community.id).all.map { |row| Rubotty::Events::Event.new(row) }

  describe "a created native event" do
    it "creates a mirrored Rubotty event in the guild's events-enabled room" do
      mirror.handle(native_change(action: :created))

      expect(events.size).to eq(1)
      event = events.first
      expect(event.title).to eq("Movie Night")
      expect(event.room_id).to eq(gaming.id)
      expect(event.kind).to eq("general") # a Discord GSE never carries a game title
      expect(event.url).to eq("https://zoom.us/j/1") # the location maps to the general event's url
      expect(event.description).to eq("Bring popcorn")
      expect(event.starts_at).to eq(Time.utc(2026, 8, 1, 20, 0, 0))
      expect(event.created_by).to eq("discord-native")
    end

    it "stamps the native id so it is never pushed back out (the loop guard)" do
      mirror.handle(native_change(action: :created, native_id: "556677"))
      expect(events.first.native_ref("discord")).to eq("556677")
    end

    it "does not create a second event when the same native create is seen again" do
      mirror.handle(native_change(action: :created, native_id: "dupe"))
      mirror.handle(native_change(action: :created, native_id: "dupe"))
      expect(events.size).to eq(1)
    end

    it "leaves the url empty when the location is only the stand-in the outbound mirror invents" do
      placeholder = Rubotty::Adapters::Discord::ScheduledEvents::NO_LOCATION
      mirror.handle(native_change(action: :created, location: placeholder))

      expect(events.first.url).to be_nil
    end

    it "does not mirror in an event Rubotty itself already owns (its own outbound native id)" do
      # As if Rubotty had mirrored one of its OWN events out to Discord.
      scheduling.create(community: community, room: gaming, as: :operator, title: "Ours",
                        starts_at: Time.utc(2026, 8, 2, 20), kind: "general",
                        native_refs: { "discord" => "ours-1" })
      expect(events.size).to eq(1)

      mirror.handle(native_change(action: :created, native_id: "ours-1"))
      expect(events.size).to eq(1) # the echo created nothing new
    end
  end

  describe "room resolution" do
    it "creates nothing for a guild that maps to no known connection" do
      mirror.handle(native_change(action: :created, guild: "no-such-guild"))
      expect(events).to be_empty
    end

    it "creates nothing when the guild's rooms all have events turned off" do
      Rubotty::ControlPlane::FeatureControls.new(models: models)
                                            .disable(community: community, selector: "gaming", feature: "events")
      mirror.handle(native_change(action: :created))
      expect(events).to be_empty
    end
  end

  describe "an updated native event" do
    it "reflects the change onto the Rubotty event it maps to" do
      mirror.handle(native_change(action: :created, native_id: "U1", title: "Old"))
      event = events.first

      mirror.handle(native_change(action: :updated, native_id: "U1", title: "New",
                                  starts_at: Time.utc(2026, 8, 3, 18, 0, 0)))
      reloaded = Rubotty::Events::Event.new(event.row.refresh)
      expect(reloaded.title).to eq("New")
      expect(reloaded.starts_at).to eq(Time.utc(2026, 8, 3, 18, 0, 0))
    end

    it "writes nothing for an update that changes nothing (damping the outbound echo)" do
      mirror.handle(native_change(action: :created, native_id: "U2", title: "Same"))
      stamp = events.first.row.updated_at.to_i

      mirror.handle(native_change(action: :updated, native_id: "U2", title: "Same"))
      expect(Rubotty::Events::Event.new(events.first.row.refresh).row.updated_at.to_i).to eq(stamp)
    end

    it "does not write the outbound stand-in back onto an event that never had a url" do
      scheduling.create(community: community, room: gaming, as: :operator, title: "Ours",
                        starts_at: Time.utc(2026, 8, 2, 20), kind: "general",
                        native_refs: { "discord" => "round-trip" })

      # The update still lands, since its description differs; only the invented location is dropped.
      mirror.handle(native_change(action: :updated, native_id: "round-trip", title: "Ours",
                                  starts_at: Time.utc(2026, 8, 2, 20),
                                  location: Rubotty::Adapters::Discord::ScheduledEvents::NO_LOCATION))

      expect(events.first.url).to be_nil
      expect(events.first.description).to eq("Bring popcorn")
    end

    it "creates a mirror for an update to a native event it has not seen before" do
      mirror.handle(native_change(action: :updated, native_id: "unseen", title: "Late arrival"))
      expect(events.map(&:title)).to eq(["Late arrival"])
    end

    # Issue #1702 (AOE3 in SECOND): Discord's SCHEDULED to ACTIVE transition
    # fires GUILD_SCHEDULED_EVENT_UPDATE at start time with a bare payload
    # (no entity_metadata or description), which used to blank an already-set
    # url/description. AOE3's being null had masked the blanking bug before.
    it "neither blanks an already-set url/description nor re-announces on a bare status transition" do
      mirror.handle(native_change(action: :created, native_id: "N7", title: "AOE3",
                                  starts_at: Time.utc(2026, 8, 1, 15, 30, 0),
                                  location: "https://discord.gg/aoe3", description: "bring your best build"))
      stamp = events.first.row.updated_at.to_i

      status_transition = Rubotty::Events::NativeEventChange.new(
        adapter: :discord, account: "discord", action: :updated, native_id: "N7", guild_id: guild_id,
        title: "AOE3", starts_at: Time.utc(2026, 8, 1, 15, 30, 0), status: :active,
        raw: {
          "id" => "N7", "guild_id" => guild_id, "name" => "AOE3",
          "scheduled_start_time" => "2026-08-01T15:30:00.000000+00:00", "status" => 2
        }
      )
      mirror.handle(status_transition)

      reloaded = events.first
      expect(reloaded.url).to eq("https://discord.gg/aoe3") # not blanked
      expect(reloaded.description).to eq("bring your best build") # not blanked
      expect(reloaded.row.updated_at.to_i).to eq(stamp) # a genuine no-op: nothing written at all
    end
  end

  describe "a deleted native event" do
    it "cancels the Rubotty event it maps to" do
      mirror.handle(native_change(action: :created, native_id: "D1"))
      mirror.handle(native_change(action: :deleted, native_id: "D1"))
      expect(events.first.cancelled?).to be(true)
    end

    it "is a harmless no-op for a delete of an event it never mirrored" do
      expect { mirror.handle(native_change(action: :deleted, native_id: "ghost")) }.not_to raise_error
      expect(events).to be_empty
    end
  end

  # The Ruby-side verify already keeps the ANSWER right whatever the LIKE
  # matches, so what escaping changes here is the scan: an id carrying a
  # wildcard must narrow the events table rather than select all of it. That is
  # visible in the SQL and nowhere else, so the SQL is what this asserts.
  describe "the native-ref lookup" do
    def sql_for(native_id)
      statements = []
      seeded[0].loggers << Class.new do
        def initialize(sink) = @sink = sink
        def info(message) = @sink << message.to_s
        def method_missing(_name, *_args) = nil
        def respond_to_missing?(*) = true
      end.new(statements)
      mirror.handle(native_change(action: :deleted, native_id: native_id))
      statements.find { |line| line.include?("LIKE") }.to_s
    end

    it "escapes a wildcard in the narrowing pattern" do
      expect(sql_for("1%3")).to include("'%1!%3%'").and include("ESCAPE '!'")
    end

    it "leaves an ordinary snowflake alone" do
      expect(sql_for("998877")).to include("'%998877%'")
    end

    it "still matches a native id that really does hold a wildcard" do
      mirror.handle(native_change(action: :created, native_id: "1%3"))
      mirror.handle(native_change(action: :deleted, native_id: "1%3"))

      expect(events.first.cancelled?).to be(true)
    end
  end

  it "never raises out to the gateway thread on a malformed change" do
    bad = Rubotty::Events::NativeEventChange.new(adapter: :discord, account: "discord",
                                                 action: :created, native_id: nil, guild_id: nil)
    expect { mirror.handle(bad) }.not_to raise_error
    expect(events).to be_empty
  end
end
