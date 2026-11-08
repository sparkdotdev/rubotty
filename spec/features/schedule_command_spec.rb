# frozen_string_literal: true

require "spec_helper"

# What /schedule does differently; the shared capture underneath is covered by
# spec/features/poll_command_spec.rb.
RSpec.describe Rubotty::Features::ScheduleCommand, :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:accounts) { sample_model.accounts }
  let(:registry) { Rubotty::ControlPlane::Registry.build(models: models, accounts: accounts) }
  let(:controls) { Rubotty::ControlPlane::FeatureControls.new(models: models, registry: registry) }

  let(:writer) { Rubotty::ControlPlane::Polls.new(models: models, logger: Rubotty::Log.null) }
  let(:ballot) { Rubotty::Polls::Ballot.new(models: models, logger: Rubotty::Log.null) }
  let(:activity) { Rubotty::Polls::RoomActivity.new }
  let(:board) do
    Rubotty::Polls::Board.new(
      registry: registry, models: models, adapters: adapters, polls: writer,
      ballot: ballot, activity: activity, logger: Rubotty::Log.null
    )
  end
  let(:timekeeper) do
    Class.new do
      def arm(_poll) = 2

      def cancel_for(_poll) = 0
    end.new
  end
  let(:lifecycle) do
    Rubotty::Polls::Lifecycle.new(polls: writer, board: board, timekeeper: timekeeper, logger: Rubotty::Log.null)
  end

  let(:adapter) { Fakes::ReactingAdapter.new(own_id: "bot-1") }
  let(:adapters) { Hash.new(adapter) }

  let(:ephemeral) do
    Rubotty::Core::EphemeralMessage.new(
      adapters: adapters, session_id: "s", topology: registry.current.topology, logger: Rubotty::Log.null
    )
  end

  subject(:feature) do
    described_class.new(
      topology: registry.current.topology, adapters: adapters, logger: Rubotty::Log.null,
      polls: writer, board: board, ballot: ballot, lifecycle: lifecycle,
      activity: activity, ephemeral: ephemeral
    )
  end

  def origin = registry.current.channel_by_endpoint_key("tg-gaming").endpoint

  def ada = Rubotty::Core::Author.new(native_id: "999888", username: "ada", first_name: "Ada")

  def turn_on!(allow: true)
    community = registry.current.community("sample")
    controls.enable(community: community, selector: "gaming", feature: "events")
    controls.set(community: community, selector: "gaming", feature: "events",
                 key: "allow_schedule_polling", value: allow)
  end

  def config(**overrides) = { allow_schedule_polling: true }.merge(overrides)

  def run(message, config: config())
    feature.call(
      Rubotty::Features::Context.new(
        message: message, community: registry.current.community("sample"),
        channel: registry.current.channel_by_endpoint_key("tg-gaming"), config: config
      )
    )
  end

  # Two candidate times, matching what most specs below need; a few pass
  # their own text when they want to test the times themselves.
  DEFAULT_TEXT = '/schedule name="Raid night" game="Deep Rock Galactic" times="tuesday 7pm | wednesday 7pm"'

  def schedule(text = DEFAULT_TEXT, config: config(), author: ada)
    run(message(origin, text: text, native_id: "cmd-#{rand(100_000)}", author: author), config: config)
    writer.open_polls.last
  end

  def card_native_id(poll) = models.poll_card.where(poll_id: poll.id, endpoint_id: "tg-gaming").first&.native_id

  def reply(poll, text, author: ada)
    run(
      message(origin, text: text, native_id: "r-#{rand(100_000)}", author: author,
                      reply_to: ref("tg-gaming", card_native_id(poll)))
    )
  end

  def last_reply = adapter.delivered_to("tg-gaming").last.body.text

  describe "the feature contract" do
    it "shares Features::Events' own feature_name, so one row gates it with /event" do
      expect(described_class.feature_name).to eq(Rubotty::Features::Events.feature_name)
      expect(described_class.default_enabled?).to be(false)
    end

    # PollCommand's own spec drives every one of these kinds through a real
    # pipeline, and that stands for this feature only while both read the one list.
    it "reads PollSurface's own list of kinds instead of keeping a copy of it" do
      expect(described_class.observes).to equal(Rubotty::Features::PollSurface::OBSERVES)
    end

    it "is a checkbox inside events rather than a catalog feature of its own" do
      expect(Rubotty::Features::Catalog.names).not_to include("schedule")
      expect(Rubotty::Features::Events.config_schema.fields).to include(:allow_schedule_polling)
      expect(Rubotty::Features::Events.config_schema.fields[:allow_schedule_polling].default).to be(false)
    end

    it "acknowledges rather than staying silent when the channel has no room mapping yet" do
      turn_on!
      allow(writer).to receive(:room_for_endpoint_key).and_return(nil)

      outcome = run(message(origin, text: DEFAULT_TEXT, native_id: "cmd-1", author: ada))
      expect(outcome).to be_halt
      expect(adapter.delivered_to("tg-gaming").last.body.text).to match(/isn't linked/i)
      expect(writer.open_polls).to be_empty
    end
  end

  describe "/schedule" do
    it "opens a multi-select session naming the game, and swallows the command" do
      turn_on!
      outcome = run(message(origin, text: DEFAULT_TEXT, author: ada))

      poll = writer.open_polls.last
      expect(outcome).to be_halt
      expect(poll.question).to eq("Raid night")
      expect(poll.detail).to eq("Deep Rock Galactic")
      expect(poll).to be_multi_select
      expect(poll).to be_schedule
    end

    it "opens with exactly the candidate times the creator named, parsed the way a reply is" do
      poll = schedule

      slots = writer.options(poll)
      expect(slots.map(&:starts_at)).to eq(
        ["tuesday 7pm", "wednesday 7pm"].map do |text|
          Rubotty::Polls::ScheduleSlots.suggested(text, timezone: poll.timezone, now: Time.now)
        end
      )
    end

    it "names which segment would not parse as a time, rather than dropping it or opening anyway" do
      turn_on!
      run(message(origin, text: '/schedule name="Raid night" game="Deep Rock Galactic" ' \
                                 'times="tuesday 7pm | not a time"', author: ada))

      expect(writer.open_polls).to be_empty
      expect(last_reply).to include('"not a time"')
    end

    it "lets a reply add a time, on top of the ones given at creation" do
      poll = schedule
      expect(poll).to be_reply_options
      expect(writer.options(poll).size).to be < Rubotty::Polls::Poll::MAX_OPTIONS
    end

    it "reads the fields in any order, since each is a keyed name=value pair" do
      poll = schedule('/schedule times="tuesday 7pm | wednesday 7pm" game="Deep Rock Galactic" name="Raid night"')

      expect(poll.question).to eq("Raid night")
      expect(poll.detail).to eq("Deep Rock Galactic")
      expect(writer.options(poll).size).to eq(2)
    end

    it "parses the exact input reported in issue #1797, unquoted spaces and all" do
      text = "/schedule name=When do you want to play AOE3 today? game=AOE3 times=2PM | 3PM | 4PM"
      fields = feature.send(:parse_fields, text.sub("/schedule ", ""))

      expect(fields).to eq(
        "name" => "When do you want to play AOE3 today?", "game" => "AOE3", "times" => "2PM | 3PM | 4PM"
      )
    end

    it "opens a poll from the same unquoted shape as the reported input, times included" do
      poll = schedule("/schedule name=When do you want to play AOE3 today? game=AOE3 " \
                       "times=tuesday 7pm | wednesday 7pm")

      expect(poll.question).to eq("When do you want to play AOE3 today?")
      expect(poll.detail).to eq("AOE3")
      expect(writer.options(poll).size).to eq(2)
    end

    it "does not let an apostrophe in a value break the parse" do
      poll = schedule("/schedule name=Alex's game night game=Chess times=tuesday 7pm | wednesday 7pm")
      expect(poll.question).to eq("Alex's game night")
    end

    it "reads a quoted value verbatim, even one holding text that looks like another key" do
      poll = schedule('/schedule name="Raid night game=decoy" game="Deep Rock Galactic" ' \
                       'times="tuesday 7pm | wednesday 7pm"')
      expect(poll.question).to eq("Raid night game=decoy")
    end

    it "says what is missing when it is given only a name" do
      turn_on!
      run(message(origin, text: '/schedule name="Raid night"', author: ada))

      expect(writer.open_polls).to be_empty
      expect(last_reply).to include("needs a name, a game, and at least two candidate times")
    end

    it "says what is missing when it is given a name and a game but only one time" do
      turn_on!
      run(message(origin, text: '/schedule name="Raid night" game="Deep Rock Galactic" times="tuesday 7pm"',
                          author: ada))

      expect(writer.open_polls).to be_empty
      expect(last_reply).to include("needs a name, a game, and at least two candidate times")
    end

    it "stays switched off until the room's own checkbox says otherwise" do
      turn_on!(allow: false)
      run(message(origin, text: DEFAULT_TEXT, author: ada), config: { allow_schedule_polling: false })

      expect(writer.open_polls).to be_empty
      expect(last_reply).to include("switched off in this room")
    end
  end

  describe "the duration" do
    it "runs for twenty-four hours when none is given" do
      expect(schedule.closes_at).to be_within(120).of(Time.now.utc + (24 * 3600))
    end

    it "takes any of the eight it offers, given as a duration= field" do
      %w[1h 2h 4h 8h 12h 24h 48h 72h].each do |token|
        poll = schedule("/schedule name=\"Raid #{token}\" game=\"Deep Rock Galactic\" " \
                         "times=\"tuesday 7pm | wednesday 7pm\" duration=#{token}")

        expect(poll.closes_at).to be_within(120).of(Time.now.utc + (token.to_i * 3600))
      end
    end

    it "refuses anything else and names the whole set" do
      turn_on!
      run(message(origin, text: '/schedule name="Raid night" game="Deep Rock Galactic" ' \
                                 'times="tuesday 7pm | wednesday 7pm" duration=3h', author: ada))

      expect(writer.open_polls).to be_empty
      expect(last_reply).to include("1h, 2h, 4h, 8h, 12h, 24h, 48h, 72h")
    end

    it "refuses a duration written in another unit" do
      turn_on!
      run(message(origin, text: '/schedule name="Raid night" game="Deep Rock Galactic" ' \
                                 'times="tuesday 7pm | wednesday 7pm" duration=2d', author: ada))

      expect(writer.open_polls).to be_empty
      expect(last_reply).to include("not a duration I take")
    end

    it "refuses a field this command does not take" do
      turn_on!
      run(message(origin, text: '/schedule name="Raid night" game="Deep Rock Galactic" ' \
                                 'times="tuesday 7pm | wednesday 7pm" reply_options=no', author: ada))

      expect(writer.open_polls).to be_empty
      expect(last_reply).to include("reply_options=")
    end
  end

  describe "suggesting a time by reply" do
    it "appends the time somebody replied with" do
      poll = schedule
      expect(reply(poll, "next monday 7pm")).to be_halt

      added = writer.options(writer.by_id(poll.id)).last
      expect(added.starts_at).to eq(
        Rubotty::Polls::ScheduleSlots.suggested("next monday 7pm", timezone: poll.timezone, now: Time.now)
      )
    end

    it "leaves an ordinary comment alone, so it still crosses to the other rooms" do
      poll = schedule

      expect(reply(poll, "any of those work for me honestly")).to be_continue
      expect(writer.options(writer.by_id(poll.id)).size).to eq(2)
    end

    it "stops at nine options however many more are suggested" do
      poll = schedule
      %w[monday tuesday wednesday thursday friday saturday sunday].each do |day|
        reply(poll, "#{day} 9pm")
      end
      # 2 initial + 7 replies lands exactly at the cap; one more must be refused.
      reply(poll, "next monday 9pm")

      expect(writer.options(writer.by_id(poll.id)).size).to eq(Rubotty::Polls::Poll::MAX_OPTIONS)
      expect(last_reply).to include("all 9 options")
    end

    it "reads a bare option number as a vote rather than a time" do
      poll = schedule
      reply(poll, "2")

      option = writer.option_at(poll, 2)
      expect(ballot.by_option(writer.by_id(poll.id))[option.id].map(&:handle)).to eq(["ada"])
    end
  end

  describe "answering by reaction" do
    it "lets one person back every slot that works for them" do
      poll = schedule
      [1, 2].each do |position|
        run(
          message(origin, kind: :reaction_add, native_id: card_native_id(poll), author: ada,
                          reaction: Rubotty::Polls::OptionEmoji.for_position(position))
        )
      end

      votes = ballot.by_option(writer.by_id(poll.id))
      expect(votes[writer.option_at(poll, 1).id].map(&:handle)).to eq(["ada"])
      expect(votes[writer.option_at(poll, 2).id].map(&:handle)).to eq(["ada"])
    end
  end

  describe "the timezone the slots are worked out in" do
    # The same chain /event walks for a blank tz=.
    it "comes from the room's own configured zone when nobody's flag says otherwise" do
      controls.set(
        community: registry.current.community("sample"), selector: "gaming", feature: "bridge",
        key: "timestamp_timezones", value: [{ label: "Lisbon", iana_timezone: "Europe/Lisbon" }]
      )

      expect(schedule.timezone).to eq("Europe/Lisbon")
    end

    it "comes from a flag in the asker's own display name first" do
      flagged = Rubotty::Core::Author.new(native_id: "42", username: "ada", display_name: "Ada 🇵🇹")

      expect(schedule(author: flagged).timezone).to eq("Europe/Lisbon")
    end

    it "comes from the shipped default home zone in a room that configured none" do
      expect(schedule.timezone).to eq("America/Los_Angeles")
    end

    it "falls back to UTC in a room that stored an empty zone list" do
      controls.set(
        community: registry.current.community("sample"), selector: "gaming", feature: "bridge",
        key: "timestamp_timezones", value: []
      )

      expect(schedule.timezone).to eq("UTC")
    end
  end

  # The same PollSurface mechanism poll_command_spec.rb covers in full; this
  # just proves it applies to a scheduling session too, labelled correctly.
  describe "canceling by replying to the card" do
    it "lets the session's own creator cancel it early" do
      poll = schedule # opened by ada
      outcome = reply(poll, "/cancel", author: ada)

      expect(outcome).to be_halt
      expect(writer.by_id(poll.id)).not_to be_open
      expect(last_reply).to include("Scheduling poll ##{poll.id} canceled by ada")
    end
  end
end
