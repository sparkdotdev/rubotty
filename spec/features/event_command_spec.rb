# frozen_string_literal: true

require "spec_helper"

# The /event chat command against the real seeded SAMPLE control plane, so parse, permission
# and create all run through the actual EventPolicy and EventScheduling.
RSpec.describe Rubotty::Features::EventCommand, :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:accounts) { sample_model.accounts }
  let(:registry) { Rubotty::ControlPlane::Registry.build(models: models, accounts: accounts) }
  # A fixed clock: exact only to keep the relative-start-time tests below
  # deterministic. Every other test here still passes an explicit absolute
  # string, so it is unaffected by which instant "now" happens to be.
  let(:now) { Time.utc(2026, 8, 11, 10, 0, 0) } # a Tuesday
  let(:scheduling) do
    Rubotty::ControlPlane::EventScheduling.new(models: models, logger: Rubotty::Log.null, clock: -> { now })
  end
  # registry: registry so a controls.set/#enable write reloads the snapshot
  # #run reads context.community from, the same way the dashboard does; a
  # config-only test (the Bridge#timestamp_timezones fallback below) needs
  # that to see its own write.
  let(:controls) { Rubotty::ControlPlane::FeatureControls.new(models: models, registry: registry) }

  let(:adapter) { Fakes::RecordingAdapter.new(own_id: "bot-1") }
  let(:adapters) { Hash.new(adapter) }

  let(:ephemeral) do
    Rubotty::Core::EphemeralMessage.new(
      adapters: adapters, session_id: "s", topology: registry.current.topology, logger: Rubotty::Log.null
    )
  end

  subject(:feature) do
    described_class.new(
      topology: registry.current.topology, adapters: adapters, logger: Rubotty::Log.null,
      event_scheduling: scheduling, ephemeral: ephemeral
    )
  end

  def origin = registry.current.channel_by_endpoint_key("tg-gaming").endpoint

  def newcomer
    Rubotty::Core::Author.new(native_id: "999888", username: "newbie", first_name: "New", last_name: "Bie")
  end

  # The seeded bootstrap operator on Telegram (sample_owner).
  def boss
    Rubotty::Core::Author.new(native_id: "80000012", username: "sample_owner", first_name: "Alex")
  end

  def author_with(nickname: nil, display_name: nil)
    Rubotty::Core::Author.new(native_id: "999888", username: "newbie", nickname: nickname, display_name: display_name)
  end

  def run(text, author:, config: {})
    community = registry.current.community("sample")
    channel = registry.current.channel_by_endpoint_key("tg-gaming")
    msg = message(origin, text: text, native_id: "m#{rand(100_000)}", author: author)
    feature.call(Rubotty::Features::Context.new(message: msg, community: community, channel: channel, config: config))
  end

  def ack_on(endpoint_id) = adapter.delivered_to(endpoint_id).last&.body&.text

  def created_event = Rubotty::Events::Event.new(models.event.first)

  # The room says it wants no timestamp expansion, which also leaves it with no
  # home zone of its own for a bare wall-clock time.
  def zones_off!(selector: "gaming")
    controls.set(community: registry.current.community("sample"), selector: selector, feature: "bridge",
                 key: "timestamp_timezones", value: [])
  end

  def turn_on!(who: "operators", selector: "gaming")
    controls.enable(community: registry.current.community("sample"), selector: selector, feature: "events")
    controls.set(community: registry.current.community("sample"), selector: selector, feature: "events",
                 key: "who_can_create", value: who)
  end

  def fields
    'title="Friday Raid Night" start="2026-07-25 20:00" tz=Europe/Lisbon kind=gaming ' \
      'game="Counter-Strike 2" server=1.2.3.4:7777'
  end

  describe "the feature contract" do
    it "shares Features::Events' own feature_name, is off by code default, and observes only chat" do
      expect(described_class.feature_name).to eq(Rubotty::Features::Events.feature_name)
      expect(described_class.feature_name).to eq("events")
      expect(described_class.default_enabled?).to be(false)
      expect(described_class.observes).to eq(%i[chat])
    end

    it "refuses rather than relays a recognised /event without a control plane" do
      bare = described_class.new(
        topology: topology(room("r", endpoint("a"))), adapters: adapters, logger: Rubotty::Log.null
      )
      outcome = bare.call(Rubotty::Features::Context.new(message: message(endpoint("a"), text: "/event #{fields}")))
      expect(outcome).to be_halt
      expect(adapter.delivered_to("a").last.body.text).to include("/event")
    end

    it "acknowledges rather than staying silent when the channel has no room mapping yet" do
      turn_on!
      allow(scheduling).to receive(:room_for_endpoint_key).and_return(nil)

      run("/event #{fields}", author: newcomer)
      expect(ack_on("tg-gaming")).to match(/isn't linked/i)
      expect(models.event.count).to eq(0)
    end

    it "still lets an unrecognised message continue with no control plane at all" do
      bare = described_class.new(
        topology: topology(room("r", endpoint("a"))), adapters: adapters, logger: Rubotty::Log.null
      )
      outcome = bare.call(Rubotty::Features::Context.new(message: message(endpoint("a"), text: "just chatting")))
      expect(outcome).to be_continue
      expect(adapter.delivered).to be_empty
    end

    it "ignores an ordinary message, letting it continue down the pipeline" do
      expect(run("just chatting about the game", author: newcomer)).to be_continue
      expect(adapter.delivered).to be_empty
    end
  end

  describe "when the room's events feature is off" do
    it "declines politely and creates nothing" do
      outcome = run("/event #{fields}", author: boss)
      expect(outcome).to be_halt # swallowed, never relayed as content
      expect(ack_on("tg-gaming")).to match(/not enabled/i)
      expect(models.event.count).to eq(0)
    end
  end

  describe "permission" do
    it "lets an operator create where who_can_create is operators (the default)" do
      turn_on!(who: "operators")
      run("/event #{fields}", author: boss)
      expect(models.event.count).to eq(1)
    end

    it "declines a normal member when who_can_create is operators" do
      turn_on!(who: "operators")
      run("/event #{fields}", author: newcomer)
      expect(ack_on("tg-gaming")).to match(/only operators/i)
      expect(models.event.count).to eq(0)
    end

    it "lets a normal member create when who_can_create is everyone" do
      turn_on!(who: "everyone")
      run("/event #{fields}", author: newcomer)
      expect(models.event.count).to eq(1)
    end
  end

  describe "a well-formed create" do
    before { turn_on!(who: "everyone") }

    it "creates the event with the parsed fields" do
      run("/event #{fields} rsvp=affirm", author: newcomer)
      event = models.event.first
      expect(event.title).to eq("Friday Raid Night")
      expect(event.kind).to eq("gaming")
      expect(event.game_title).to eq("Counter-Strike 2")
      expect(event.server_address).to eq("1.2.3.4:7777")
      expect(event.rsvp_mode).to eq("affirm")
      expect(event.room_id).to eq(models.room.where(community_id: event.community_id, room_key: "gaming").first.id)
    end

    it "acknowledges with a confirmation naming the event and its time" do
      run("/event #{fields}", author: newcomer)
      expect(ack_on("tg-gaming")).to match(/Scheduled #\d+: Friday Raid Night at Sat, 25 Jul 2026 20:00 \+0100/)
    end

    it "recognises the command under the alternate ! prefix as well as /" do
      outcome = run("!event #{fields}", author: newcomer)
      expect(outcome).to be_halt
      expect(models.event.count).to eq(1)
    end

    it "accepts long field-name aliases as well as the short ones" do
      run('/event title=Standup start="2026-07-25 09:00" timezone=UTC kind=general url=https://meet.example/x',
          author: newcomer)
      event = models.event.first
      expect(event.kind).to eq("general")
      expect(event.url).to eq("https://meet.example/x")
    end

    it "reads a quoted value with spaces as one field" do
      run('/event title="Multi Word Title" start="2026-07-25 09:00" tz=UTC kind=general url=https://x',
          author: newcomer)
      expect(models.event.first.title).to eq("Multi Word Title")
    end

    it "reads an unquoted multi-word value up to the next key, instead of demanding quotes" do
      run('/event title=Movie Night start="2026-09-01 20:00" tz=UTC kind=general', author: newcomer)
      expect(models.event.first.title).to eq("Movie Night")
    end

    it "does not let an apostrophe in a value break the parse" do
      run('/event title=Alex\'s Game Night start="2026-09-01 20:00" tz=UTC kind=general', author: newcomer)
      expect(models.event.first.title).to eq("Alex's Game Night")
    end

    # iOS and macOS substitute curly quotes for straight ones automatically as
    # someone types; this is the exact input reported live against #1797.
    it "reads curly quotes the same way as straight ones, the pair a phone substitutes automatically" do
      run("/event title=“Game zone” start=“2026-09-01 14:45” game=“AOE3” " \
          "tz=UTC kind=gaming", author: newcomer)
      event = models.event.first
      expect(event.title).to eq("Game zone")
      expect(event.game_title).to eq("AOE3")
    end

    it "does not let a curly apostrophe in a value break the parse" do
      run("/event title=Alex’s Game Night start=\"2026-09-01 20:00\" tz=UTC kind=general", author: newcomer)
      expect(models.event.first.title).to eq("Alex’s Game Night")
    end

    it "reads a quoted value verbatim, even one holding text that looks like another key" do
      run('/event title="Standup start=now" start="2026-09-01 20:00" tz=UTC kind=general', author: newcomer)
      expect(models.event.first.title).to eq("Standup start=now")
    end
  end

  describe "tz left blank: ControlPlane::TimezoneInference fills it in" do
    before { turn_on!(who: "everyone") }

    it "is no longer a required field at all" do
      run('/event title=Standup start="2026-07-25 09:00" kind=general', author: newcomer)
      expect(models.event.count).to eq(1)
    end

    it "falls back to the shipped default home zone with no flag and no room zones configured" do
      run('/event title=Standup start="2026-07-25 09:00" kind=general', author: newcomer)

      expect(models.event.first.timezone).to eq("America/Los_Angeles")
    end

    it "falls all the way to UTC in a room that stored an empty zone list" do
      zones_off!

      run('/event title=Standup start="2026-07-25 09:00" kind=general', author: newcomer)
      event = models.event.first
      expect(event.timezone).to eq("UTC")
      expect(ack_on("tg-gaming")).to match(/\+0000/)
    end

    it "infers a timezone from a flag emoji in the author's display name" do
      run('/event title=Standup start="2026-07-25 09:00" kind=general',
          author: author_with(display_name: "Newbie \u{1F1F5}\u{1F1F9}"))
      expect(models.event.first.timezone).to eq("Europe/Lisbon")
    end

    it "prefers a flag emoji in the nickname over one in the display name" do
      run('/event title=Standup start="2026-07-25 09:00" kind=general',
          author: author_with(nickname: "Newbie \u{1F1E9}\u{1F1EA}", display_name: "Newbie \u{1F1F5}\u{1F1F9}"))
      expect(models.event.first.timezone).to eq("Europe/Berlin")
    end

    # Zones off in this room, so the flag is the only candidate left and a
    # guessed zone would show up plainly against UTC.
    it "falls through a multi-zone flag (no single honest answer) rather than guessing" do
      zones_off!

      run('/event title=Standup start="2026-07-25 09:00" kind=general',
          author: author_with(display_name: "Newbie \u{1F1FA}\u{1F1F8}"))
      expect(models.event.first.timezone).to eq("UTC")
    end

    it "an explicit tz= still wins outright over a flag" do
      run('/event title=Standup start="2026-07-25 09:00" tz=Asia/Tokyo kind=general',
          author: author_with(display_name: "Newbie \u{1F1F5}\u{1F1F9}"))
      expect(models.event.first.timezone).to eq("Asia/Tokyo")
    end

    it "falls back to this room's own configured Bridge#timestamp_timezones default" do
      controls.set(
        community: registry.current.community("sample"), selector: "gaming", feature: "bridge",
        key: "timestamp_timezones", value: [{ label: "Pacific", iana_timezone: "America/Los_Angeles" }]
      )

      run('/event title=Standup start="2026-07-25 09:00" kind=general', author: newcomer)
      expect(models.event.first.timezone).to eq("America/Los_Angeles")
    end
  end

  describe "a relative start time" do
    before { turn_on!(who: "everyone") }

    it "reads a bare offset" do
      run('/event title=Standup start="6 hours" kind=general tz=UTC', author: newcomer)
      expect(models.event.first.starts_at).to eq(now + 6 * 3600)
    end

    it "reads now" do
      run('/event title=Standup start=now kind=general tz=UTC', author: newcomer)
      expect(models.event.first.starts_at).to eq(now)
    end

    it "reads tomorrow plus a clock time, anchored to the resolved timezone" do
      run('/event title=Standup start="tomorrow 4pm" kind=general tz=Europe/Lisbon', author: newcomer)
      # now is 2026-08-11 10:00 UTC; Europe/Lisbon is UTC+1 in August, so
      # tomorrow there is 2026-08-12, and 4pm local is 15:00 UTC.
      expect(models.event.first.starts_at).to eq(Time.utc(2026, 8, 12, 15, 0, 0))
    end

    it "reads a weekday plus a clock time using the flag-inferred timezone, when tz is left blank" do
      run('/event title=Standup start="tuesday 11pm" kind=general',
          author: author_with(display_name: "Newbie \u{1F1F5}\u{1F1F9}"))
      # now is Tuesday 2026-08-11: the next Tuesday is one week out, at 11pm
      # Europe/Lisbon (UTC+1 in August) == 22:00 UTC.
      expect(models.event.first.starts_at).to eq(Time.utc(2026, 8, 18, 22, 0, 0))
    end

    it "reads a bare absolute start time in the resolved timezone" do
      run('/event title=Standup start="2026-07-25 20:00" kind=general tz=Asia/Tokyo', author: newcomer)
      expect(models.event.first.starts_at).to eq(Time.utc(2026, 7, 25, 11, 0, 0))
    end
  end

  describe "repeat= (issue #948)" do
    before { turn_on!(who: "everyone") }

    it "leaves the event a one-off when repeat is not given" do
      run("/event #{fields}", author: newcomer)
      expect(created_event).not_to be_recurring
    end

    it "leaves the event a one-off for repeat=none" do
      run("/event #{fields} repeat=none", author: newcomer)
      expect(created_event).not_to be_recurring
    end

    it "accepts a known keyword" do
      run("/event #{fields} repeat=weekly", author: newcomer)
      expect(created_event.recurrence_interval).to eq(604_800)
    end

    it "accepts a bare number of seconds for a cadence the keyword vocabulary does not name" do
      run("/event #{fields} repeat=43200", author: newcomer)
      expect(created_event.recurrence_interval).to eq(43_200)
    end

    it "mentions the cadence in the confirmation" do
      run("/event #{fields} repeat=daily", author: newcomer)
      expect(ack_on("tg-gaming")).to match(/repeats every 1 day/)
    end

    it "rejects text that is neither a keyword nor a number, without creating the event" do
      run("/event #{fields} repeat=fortnightly", author: newcomer)
      expect(ack_on("tg-gaming")).to match(/Could not understand repeat=fortnightly/)
      expect(models.event.count).to eq(0)
    end
  end

  describe "reminders= (issue #944)" do
    before { turn_on!(who: "everyone") }

    it "leaves the override nil (use the community/room default) when not given" do
      run("/event #{fields}", author: newcomer)
      expect(created_event.reminder_intervals).to be_nil
    end

    it "leaves the override nil for reminders=default" do
      run("/event #{fields} reminders=default", author: newcomer)
      expect(created_event.reminder_intervals).to be_nil
    end

    it "sets an explicit empty ladder for reminders=none" do
      run("/event #{fields} reminders=none", author: newcomer)
      event = created_event
      expect(event.reminder_intervals).to eq([])
      expect(event.reminder_intervals).not_to be_nil
    end

    it "parses a comma separated list of seconds" do
      run("/event #{fields} reminders=3600,900", author: newcomer)
      expect(created_event.reminder_intervals).to eq([3600, 900])
    end

    it "rejects an unparsable entry, without creating the event" do
      run("/event #{fields} reminders=3600,soon", author: newcomer)
      expect(ack_on("tg-gaming")).to match(/Could not understand reminders=3600,soon/)
      expect(models.event.count).to eq(0)
    end
  end

  describe "bad input" do
    before { turn_on!(who: "everyone") }

    it "replies with usage for a bare /event" do
      run("/event", author: newcomer)
      expect(ack_on("tg-gaming")).to match(/Usage: \/event/)
      expect(models.event.count).to eq(0)
    end

    it "names the missing fields rather than a generic failure" do
      run("/event title=Standup", author: newcomer)
      expect(ack_on("tg-gaming")).to match(/Missing/)
      expect(ack_on("tg-gaming")).to match(/start/)
      expect(models.event.count).to eq(0)
    end

    it "names a key it does not take rather than silently dropping it" do
      run('/event title=Standup start="2026-07-25 09:00" kind=general typo=oops', author: newcomer)
      expect(ack_on("tg-gaming")).to match(/typo=/)
      expect(models.event.count).to eq(0)
    end

    it "declines a start time it cannot parse" do
      run('/event title=X start="not a time" tz=UTC kind=general url=https://x', author: newcomer)
      expect(ack_on("tg-gaming")).to match(/start time/i)
      expect(models.event.count).to eq(0)
    end

    it "declines an unknown kind" do
      run('/event title=X start="2026-07-25 09:00" tz=UTC kind=raid', author: newcomer)
      expect(ack_on("tg-gaming")).to match(/kind/i)
      expect(models.event.count).to eq(0)
    end

    it "reports unmatched quoting rather than raising" do
      expect { run('/event title="Unterminated start="2026-07-25 09:00"', author: newcomer) }.not_to raise_error
      expect(ack_on("tg-gaming")).to match(/quoting/i)
      expect(models.event.count).to eq(0)
    end

    it "leaves an unknown prefixed token alone, so the bridge relays it" do
      outcome = run("!eventful musings", author: newcomer)
      expect(outcome).to be_continue
      expect(models.event.count).to eq(0)
    end
  end

  # The invocation and its acknowledgement are one exchange (Core::CommandAck), the same
  # contract UtilityCommands already carries; see spec/features/command_cleanup_durability_spec.rb.
  describe "the acknowledgement pairs with its own invocation (also_delete)" do
    let(:base) { Time.now }
    let(:clock) { -> { @now ||= base } }
    def advance(seconds) = (@now = (@now || base) + seconds)

    let(:scheduler) { Rubotty::Core::Scheduler.new(logger: Rubotty::Log.null, clock: clock) }
    let(:ephemeral) do
      Rubotty::Core::EphemeralMessage.new(
        adapters: adapters, session_id: "s", topology: registry.current.topology, logger: Rubotty::Log.null,
        clock: clock
      )
    end
    let(:feature) do
      described_class.new(
        topology: registry.current.topology, adapters: adapters, logger: Rubotty::Log.null,
        event_scheduling: scheduling, ephemeral: ephemeral, cleanup: scheduler
      )
    end

    after { scheduler.stop }
    before { turn_on!(who: "everyone") }

    def run_fixed(text, native_id:, author: newcomer, config: {})
      community = registry.current.community("sample")
      channel = registry.current.channel_by_endpoint_key("tg-gaming")
      msg = message(origin, text: text, native_id: native_id, author: author)
      feature.call(Rubotty::Features::Context.new(message: msg, community: community, channel: channel,
                                                   config: config))
    end

    it "takes the invoking /event message with it when the ack self-deletes" do
      run_fixed("/event #{fields}", native_id: "77")

      advance(30)
      scheduler.run_due

      expect(adapter.deleted).to include(%w[tg-gaming d1], %w[tg-gaming 77])
    end

    it "leaves the invocation alone when the scope opts out" do
      run_fixed("/event #{fields}", native_id: "77", config: { delete_command_message: false })

      advance(30)
      scheduler.run_due

      expect(adapter.deleted).to include(%w[tg-gaming d1])
      expect(adapter.deleted).not_to include(%w[tg-gaming 77])
    end

    # A native Discord slash-command interaction is reconstructed for the pipeline; its
    # ref names no real posted message, so Core::CommandAck.pair_with must never pair it.
    it "never pairs a synthetic (Discord slash-command) invocation" do
      community = registry.current.community("sample")
      channel = registry.current.channel_by_endpoint_key("tg-gaming")
      msg = message(origin, text: "/event #{fields}", native_id: "77", author: newcomer, synthetic: true)
      feature.call(Rubotty::Features::Context.new(message: msg, community: community, channel: channel, config: {}))

      advance(30)
      scheduler.run_due

      expect(adapter.deleted).to include(%w[tg-gaming d1])
      expect(adapter.deleted).not_to include(%w[tg-gaming 77])
    end
  end
end
