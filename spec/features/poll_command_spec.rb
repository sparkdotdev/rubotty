# frozen_string_literal: true

require "spec_helper"

# The /poll command and both ways an answer comes back.
RSpec.describe Rubotty::Features::PollCommand, :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:accounts) { sample_model.accounts }
  let(:registry) { Rubotty::ControlPlane::Registry.build(models: models, accounts: accounts) }
  let(:controls) { Rubotty::ControlPlane::FeatureControls.new(models: models) }

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
    Rubotty::Polls::Lifecycle.new(
      polls: writer, board: board, timekeeper: timekeeper, logger: Rubotty::Log.null
    )
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

  def bruno = Rubotty::Core::Author.new(native_id: "111222", username: "bruno")

  # The seeded bootstrap operator on Telegram (sample_owner).
  def boss = Rubotty::Core::Author.new(native_id: "80000012", username: "sample_owner", first_name: "Alex")

  def turn_on!
    controls.enable(community: registry.current.community("sample"), selector: "gaming", feature: "poll")
  end

  def run(message, config: {})
    feature.call(
      Rubotty::Features::Context.new(
        message: message, community: registry.current.community("sample"),
        channel: registry.current.channel_by_endpoint_key("tg-gaming"), config: config
      )
    )
  end

  def open_poll(text = "/poll Which map? | Dust II | Inferno", config: {}, author: ada)
    turn_on!
    run(message(origin, text: text, native_id: "cmd-#{rand(100_000)}", author: author), config: config)
    writer.open_polls.last
  end

  def card_native_id(poll, endpoint_id: "tg-gaming")
    models.poll_card.where(poll_id: poll.id, endpoint_id: endpoint_id).first&.native_id
  end

  def react(poll, position, kind: :reaction_add, author: ada)
    run(
      message(origin, kind: kind, native_id: card_native_id(poll), author: author,
                      reaction: Rubotty::Polls::OptionEmoji.for_position(position))
    )
  end

  def press(poll, position, author: ada, token: nil)
    run(
      message(origin, kind: :button_press, native_id: card_native_id(poll), author: author,
                      button: token || Rubotty::Polls::VoteButtons.token_for(position))
    )
  end

  def reply(poll, text, author: ada)
    run(
      message(origin, text: text, native_id: "r-#{rand(100_000)}", author: author,
                      reply_to: ref("tg-gaming", card_native_id(poll)))
    )
  end

  def voters_on(poll, position)
    ballot.by_option(writer.by_id(poll.id))[writer.option_at(poll, position).id].map(&:handle)
  end

  describe "the feature contract" do
    it "shares Features::Poll's own feature_name and is off by code default" do
      expect(described_class.feature_name).to eq(Rubotty::Features::Poll.feature_name)
      expect(described_class.default_enabled?).to be(false)
    end

    it "observes chat, both reaction kinds, the anonymous reaction sync and a button press" do
      expect(described_class.observes).to eq(%i[chat reaction_add reaction_remove reaction_sync button_press])
    end

    it "refuses rather than relays a recognised /poll without a control plane" do
      bare = described_class.new(topology: topology(room("r", endpoint("a"))), adapters: adapters,
                                 logger: Rubotty::Log.null)
      msg = message(endpoint("a"), text: "/poll a | b | c")

      outcome = bare.call(Rubotty::Features::Context.new(message: msg))
      expect(outcome).to be_halt
      expect(adapter.delivered_to("a").last.body.text).to include("/poll")
    end

    it "still lets an unrecognised message continue with no control plane at all" do
      bare = described_class.new(topology: topology(room("r", endpoint("a"))), adapters: adapters,
                                 logger: Rubotty::Log.null)
      msg = message(endpoint("a"), text: "just chatting")

      outcome = bare.call(Rubotty::Features::Context.new(message: msg))
      expect(outcome).to be_continue
      expect(adapter.delivered).to be_empty
    end

    it "acknowledges rather than staying silent when the channel has no room mapping yet" do
      turn_on!
      allow(writer).to receive(:room_for_endpoint_key).and_return(nil)

      outcome = run(message(origin, text: "/poll Which map? | Dust II | Inferno", native_id: "cmd-1", author: ada))
      expect(outcome).to be_halt
      expect(adapter.delivered_to("tg-gaming").last.body.text).to match(/isn't linked/i)
      expect(writer.open_polls).to be_empty
    end
  end

  # Every example elsewhere in this file calls #call directly, so it keeps passing
  # whatever PollSurface::OBSERVES says. These drive one real message per observed
  # kind through a real Pipeline, with the bridge behind it so a swallow is visible.
  describe "every kind it observes, driven through the real pipeline" do
    let(:map) { Rubotty::Storage::Memory.new }
    let(:bridge) do
      Rubotty::Features::Bridge.new(
        topology: registry.current.topology, adapters: adapters, storage: map,
        loop_guard: Rubotty::Core::LoopGuard.new(storage: map), logger: Rubotty::Log.null, ttl: 3600
      )
    end

    # The snapshot is built once, so the row that switched polls on has to be read
    # back in before the pipeline can see this feature as enabled at all.
    let(:pipeline) do
      registry.reload
      Rubotty::Features::Pipeline.new(features: [feature, bridge], registry: registry, logger: Rubotty::Log.null)
    end

    # The card as the BRIDGE knows it, a copy on the far platform being what its
    # aggregate mirror reaches for.
    def relayed_card!(poll)
      map.record(source: ref("tg-gaming", card_native_id(poll)),
                 destination: ref("dc-gaming", "copy"), room_id: "gaming")
    end

    def on_card(poll, kind:, **rest)
      message(origin, kind: kind, native_id: card_native_id(poll), **rest)
    end

    observes_kind :chat, "/poll typed in the room is what opens one" do
      turn_on!
      pipeline.handle(message(origin, text: "/poll Which map? | Dust II | Inferno", native_id: "cmd", author: ada))
      writer.open_polls
    end

    observes_kind :reaction_add, "a keycap on the card is a vote wherever the platform allows one" do
      poll = open_poll
      pipeline.handle(
        on_card(poll, kind: :reaction_add, author: ada, reaction: Rubotty::Polls::OptionEmoji.for_position(1))
      )
      voters_on(poll, 1)
    end

    observes_kind :reaction_remove, "taking that keycap back withdraws the vote again" do
      poll = open_poll
      react(poll, 1)
      held = voters_on(poll, 1)
      pipeline.handle(
        on_card(poll, kind: :reaction_remove, author: ada, reaction: Rubotty::Polls::OptionEmoji.for_position(1))
      )
      held - voters_on(poll, 1)
    end

    swallows_kind :reaction_sync, "an anonymous count on the card is kept off the bridge's aggregate mirror" do
      poll = open_poll
      relayed_card!(poll)
      # Posting the card places its own keycaps, so only what follows counts.
      already_placed = adapter.syncs.size
      pipeline.handle(
        on_card(poll, kind: :reaction_sync, author: nil,
                      reaction_set: [Rubotty::Polls::OptionEmoji.for_position(1)])
      )
      adapter.syncs.drop(already_placed)
    end

    observes_kind :button_press, "a press is the only way to vote where keycap reactions are refused" do
      poll = open_poll
      pipeline.handle(
        on_card(poll, kind: :button_press, author: ada, button: Rubotty::Polls::VoteButtons.token_for(1))
      )
      voters_on(poll, 1)
    end

    covers_every_observed_kind
  end

  describe "/poll" do
    it "opens a poll with the question and its options, and swallows the command" do
      turn_on!
      outcome = run(message(origin, text: "/poll Which map? | Dust II | Inferno", author: ada))

      expect(outcome).to be_halt
      poll = writer.open_polls.last
      expect(poll.question).to eq("Which map?")
      expect(writer.options(poll).map(&:label)).to eq(["Dust II", "Inferno"])
    end

    it "reads the quoted form too, for somebody who types it the way /event is typed" do
      poll = open_poll('/poll "Which map?" "Dust II" Inferno')

      expect(poll.question).to eq("Which map?")
      expect(writer.options(poll).map(&:label)).to eq(["Dust II", "Inferno"])
    end

    it "posts the card and records it, so an answer on it resolves back" do
      poll = open_poll

      expect(card_native_id(poll)).not_to be_nil
      expect(adapter.delivered_to("tg-gaming").map { |m| m.body.text }.join("\n")).to include("Poll: Which map?")
    end

    it "opens it single-select, since a poll asks for one answer" do
      expect(open_poll).not_to be_multi_select
    end

    it "refuses a question with fewer than two options and says why" do
      turn_on!
      run(message(origin, text: "/poll Which map?", author: ada))

      expect(writer.open_polls).to be_empty
      expect(adapter.delivered_to("tg-gaming").last.body.text).to include("at least two options")
    end

    it "reads the deadline off this room's own config" do
      poll = open_poll(config: { duration: "4h" })

      expect(poll.closes_at).to be_within(120).of(Time.now.utc + (4 * 3600))
    end

    it "falls back to the default deadline for a duration the config cannot hold" do
      poll = open_poll(config: { duration: "nonsense" })

      expect(poll.closes_at).to be_within(120).of(Time.now.utc + (24 * 3600))
    end
  end

  describe "the reply_options override" do
    it "falls back to the room's own default when the poll gives none" do
      on = open_poll(config: { reply_options: true })
      off = open_poll(config: { reply_options: false })

      expect(on).to be_reply_options
      expect(off).not_to be_reply_options
    end

    it "turns reply-add-option ON for this poll even when the room default is off" do
      poll = open_poll("/poll Which map? | Dust II | Inferno | reply_options=yes", config: { reply_options: false })

      expect(poll).to be_reply_options
    end

    it "turns reply-add-option OFF for this poll even when the room default is on" do
      poll = open_poll("/poll Which map? | Dust II | Inferno | reply_options=no", config: { reply_options: true })

      expect(poll).not_to be_reply_options
    end

    it "reads the modifier when it trails a bare (non-piped) question too" do
      poll = open_poll('/poll "Which map?" "Dust II" Inferno reply_options=true', config: { reply_options: false })

      expect(poll).to be_reply_options
      expect(writer.options(poll).map(&:label)).to eq(["Dust II", "Inferno"])
    end

    it "does not leak the modifier into the options it strips it from" do
      poll = open_poll("/poll Which map? | Dust II | Inferno | reply_options=yes", config: { reply_options: false })

      expect(writer.options(poll).map(&:label)).to eq(["Dust II", "Inferno"])
    end

    it "refuses a directive this command does not take" do
      turn_on!
      run(message(origin, text: "/poll Which map? | Dust II | Inferno | nonsense=1", author: ada))

      expect(writer.open_polls).to be_empty
      expect(adapter.delivered_to("tg-gaming").last.body.text).to include("nonsense=")
    end

    # Discord's own /poll slash command has no pipe to put in front of a
    # keyed option, so it lands glued onto the last option with a space
    # instead (see Interactions#body_text): the directive still has to read
    # cleanly rather than becoming part of that option's literal text.
    it "reads a directive glued onto the last option with a space, as a native slash command reconstructs it" do
      poll = open_poll("/poll Which map? | Dust II | Inferno reply_options=yes")

      expect(poll).to be_reply_options
      expect(writer.options(poll).map(&:label)).to eq(["Dust II", "Inferno"])
    end

    it "reads two directives stacked on the same glued tail, as the native picker reconstructs them together" do
      poll = open_poll("/poll Which map? | Dust II | Inferno reply_options=yes duration=12h")

      expect(poll).to be_reply_options
      expect(poll.closes_at).to be_within(120).of(Time.now.utc + (12 * 3600))
      expect(writer.options(poll).map(&:label)).to eq(["Dust II", "Inferno"])
    end
  end

  describe "the duration override" do
    it "runs for the requested hours when given as its own directive" do
      poll = open_poll("/poll Which map? | Dust II | Inferno | duration=4h")

      expect(poll.closes_at).to be_within(120).of(Time.now.utc + (4 * 3600))
    end

    it "refuses a duration written in another unit and names the whole set" do
      turn_on!
      run(message(origin, text: "/poll Which map? | Dust II | Inferno | duration=2d", author: ada))

      expect(writer.open_polls).to be_empty
      expect(adapter.delivered_to("tg-gaming").last.body.text).to include("1h, 2h, 4h, 8h, 12h, 24h, 48h, 72h")
    end
  end

  describe "the multi_select override" do
    it "stays single choice by default: a second reaction moves the vote rather than adding to it" do
      poll = open_poll
      expect(poll).not_to be_multi_select

      react(poll, 1)
      react(poll, 2)

      expect(voters_on(poll, 1)).to be_empty
      expect(voters_on(poll, 2)).to eq(["ada"])
    end

    it "lets a voter hold two options at once, by reaction, when given as its own directive" do
      poll = open_poll("/poll Which map? | Dust II | Inferno | multi_select=yes")
      expect(poll).to be_multi_select

      react(poll, 1)
      react(poll, 2)

      expect(voters_on(poll, 1)).to eq(["ada"])
      expect(voters_on(poll, 2)).to eq(["ada"])
    end

    it "lets a voter hold two options at once, by reply, when given as its own directive" do
      poll = open_poll("/poll Which map? | Dust II | Inferno | multi_select=yes")

      reply(poll, "1")
      reply(poll, "2")

      expect(voters_on(poll, 1)).to eq(["ada"])
      expect(voters_on(poll, 2)).to eq(["ada"])
    end
  end

  # A real /poll typed on Telegram, copying the [reply_options=yes|no]
  # bracket notation straight out of the old USAGE string: the bracket-free
  # directive syntax means a stray "[" is no longer stripped to a bare "[",
  # it just stays a literal (if odd) piece of text.
  describe "the real report that exposed the old bracket parsing bug" do
    it "keeps the question clean of its own quotes and the bracket text intact rather than truncated" do
      poll = open_poll('/poll "Fuck who?" | Chris | [reply_options=no]')

      expect(poll.question).to eq("Fuck who?")
      expect(writer.options(poll).map(&:label)).to eq(["Chris", "[reply_options=no]"])
    end
  end

  describe "answering by reaction" do
    it "records a vote for the option the keycap names" do
      poll = open_poll
      react(poll, 2)

      expect(voters_on(poll, 2)).to eq(["ada"])
    end

    it "swallows the reaction so it never reaches the bridge's aggregate mirror" do
      poll = open_poll

      expect(react(poll, 1)).to be_halt
    end

    it "withdraws the vote when the reaction is taken back" do
      poll = open_poll
      react(poll, 1)
      react(poll, 1, kind: :reaction_remove)

      expect(voters_on(poll, 1)).to be_empty
    end

    it "moves the vote rather than stacking one, since a poll is single-select" do
      poll = open_poll
      react(poll, 1)
      react(poll, 2)

      expect(voters_on(poll, 1)).to be_empty
      expect(voters_on(poll, 2)).to eq(["ada"])
    end

    it "ignores a reaction outside the keycap vocabulary, and one on nothing it posted" do
      poll = open_poll
      run(message(origin, kind: :reaction_add, native_id: card_native_id(poll), author: ada,
                          reaction: Rubotty::Core::Reaction.new(emoji: "👍")))
      expect(ballot.by_option(writer.by_id(poll.id))).to be_empty

      stray = message(origin, kind: :reaction_add, native_id: "not-a-card", author: ada,
                              reaction: Rubotty::Polls::OptionEmoji.for_position(1))
      expect(run(stray)).to be_continue
    end

    it "leaves a closed poll's tally alone" do
      poll = open_poll
      writer.close(poll: writer.by_id(poll.id))
      react(poll, 1)

      expect(voters_on(poll, 1)).to be_empty
    end
  end

  # The Telegram path: no keycap can be tapped there, so the card carries an
  # inline keyboard and a press arrives as its own kind of message.
  describe "answering by pressing a button" do
    it "records a vote for the option the button names" do
      poll = open_poll
      press(poll, 2)

      expect(voters_on(poll, 2)).to eq(["ada"])
    end

    it "counts a second voter's press alongside the first, under their own handle" do
      poll = open_poll(config: {})
      press(poll, 1)
      press(poll, 1, author: bruno)

      expect(voters_on(poll, 1)).to eq(%w[ada bruno])
    end

    it "swallows the press so it never reaches the bridge" do
      poll = open_poll

      expect(press(poll, 1)).to be_halt
    end

    # One keyboard serves the whole room, so the press itself cannot say
    # whether it means to add or to remove; the ballot decides.
    it "takes the vote back when the same voter presses the same option again" do
      poll = open_poll
      press(poll, 1)
      press(poll, 1)

      expect(voters_on(poll, 1)).to be_empty
    end

    it "leaves the other voter's answer alone while one of them toggles" do
      poll = open_poll
      press(poll, 1)
      press(poll, 1, author: bruno)
      press(poll, 1)

      expect(voters_on(poll, 1)).to eq(["bruno"])
    end

    it "moves the vote rather than stacking one, since a poll is single-select" do
      poll = open_poll
      press(poll, 1)
      press(poll, 2)

      expect(voters_on(poll, 1)).to be_empty
      expect(voters_on(poll, 2)).to eq(["ada"])
    end

    it "toggles one option at a time where the poll takes several answers" do
      poll = open_poll("/poll Which map? | Dust II | Inferno | multi_select=yes")
      press(poll, 1)
      press(poll, 2)
      press(poll, 1)

      expect(voters_on(poll, 1)).to be_empty
      expect(voters_on(poll, 2)).to eq(["ada"])
    end

    it "redraws the card so the room sees the tally the press produced" do
      poll = open_poll
      adapter.edited.clear
      press(poll, 1)

      expect(adapter.edited.last.last.body.text).to include("Dust II @ada")
    end

    it "ignores a token that names no option of ours, and a press on nothing it posted" do
      poll = open_poll
      press(poll, 1, token: "something-else:1")
      press(poll, 99)
      expect(ballot.by_option(writer.by_id(poll.id))).to be_empty

      stray = message(origin, kind: :button_press, native_id: "not-a-card", author: ada,
                              button: Rubotty::Polls::VoteButtons.token_for(1))
      expect(run(stray)).to be_continue
    end

    it "leaves a closed poll's tally alone" do
      poll = open_poll
      writer.close(poll: writer.by_id(poll.id))
      press(poll, 1)

      expect(voters_on(poll, 1)).to be_empty
    end
  end

  describe "an anonymous reaction sync (issue: Telegram reports no author here)" do
    # Telegram reports message_reaction_count instead of a per-user update
    # in a channel or large supergroup with anonymous reactions on; before
    # :reaction_sync was observed, a tap there never reached PollSurface,
    # so it fell through to Bridge's aggregate mirror instead of a vote.
    it "swallows a sync on the poll's own card rather than recording a vote" do
      poll = open_poll
      msg = message(origin, kind: :reaction_sync, native_id: card_native_id(poll),
                            reaction_set: [Rubotty::Polls::OptionEmoji.for_position(1)], author: nil)
      expect(run(msg)).to be_halt
      expect(ballot.by_option(writer.by_id(poll.id))).to be_empty
    end

    it "still continues a sync on a message that names no tracked card" do
      msg = message(origin, kind: :reaction_sync, native_id: "not-a-card",
                            reaction_set: [Rubotty::Polls::OptionEmoji.for_position(1)], author: nil)
      expect(run(msg)).to be_continue
    end
  end

  describe "answering by reply" do
    it "reads a bare option number as a vote" do
      poll = open_poll
      expect(reply(poll, "2")).to be_halt

      expect(voters_on(poll, 2)).to eq(["ada"])
    end

    it "reads the option's own text as a vote, however it was capitalised" do
      poll = open_poll
      reply(poll, "  dust ii ")

      expect(voters_on(poll, 1)).to eq(["ada"])
    end

    it "acknowledges a successful reply-vote" do
      poll = open_poll
      reply(poll, "2")

      expect(adapter.delivered_to("tg-gaming").last.body.text).to include("Recorded your vote for Inferno.")
    end

    it "leaves an ordinary comment on the card alone, so it still crosses to the other rooms" do
      poll = open_poll

      expect(reply(poll, "looks good to me")).to be_continue
    end

    it "says nothing at all when the reply fallback is switched off for this room" do
      poll = open_poll(config: { reply_votes: false })

      expect(reply(poll, "1")).to be_continue
      expect(voters_on(poll, 1)).to be_empty
    end

    it "appends an option when this room allows it" do
      poll = open_poll(config: { reply_options: true })
      expect(reply(poll, "Nuke", author: bruno)).to be_halt

      expect(writer.options(writer.by_id(poll.id)).map(&:label)).to eq(["Dust II", "Inferno", "Nuke"])
    end

    it "records who suggested the option it added" do
      poll = open_poll(config: { reply_options: true })
      reply(poll, "Nuke", author: bruno)

      expect(writer.option_at(writer.by_id(poll.id), 3).suggested_by).to eq("telegram:bruno")
    end

    it "acknowledges a successful reply-add-option" do
      poll = open_poll(config: { reply_options: true })
      reply(poll, "Nuke", author: bruno)

      expect(adapter.delivered_to("tg-gaming").last.body.text).to include("Added option #3: Nuke.")
    end

    it "explains itself rather than staying silent when the option list is full" do
      poll = open_poll(config: { reply_options: true })
      (3..9).each { |i| writer.add_option(poll: writer.by_id(poll.id), label: "Option #{i}") }
      reply(poll, "One too many", author: bruno)

      expect(adapter.delivered_to("tg-gaming").last.body.text).to include("all 9 options")
    end
  end

  describe "canceling by replying to the card" do
    it "lets the poll's own creator cancel it early" do
      poll = open_poll # opened by ada
      outcome = reply(poll, "/cancel", author: ada)

      expect(outcome).to be_halt
      expect(writer.by_id(poll.id)).not_to be_open
      expect(adapter.delivered_to("tg-gaming").last.body.text).to include("canceled by ada")
    end

    it "lets a room operator cancel a poll they did not create" do
      poll = open_poll # opened by ada
      outcome = reply(poll, "/cancel", author: boss)

      expect(outcome).to be_halt
      expect(writer.by_id(poll.id)).not_to be_open
    end

    it "refuses a non-creator, non-operator, and leaves the poll open" do
      poll = open_poll # opened by ada
      outcome = reply(poll, "/cancel", author: bruno)

      expect(outcome).to be_halt
      expect(writer.by_id(poll.id)).to be_open
      expect(adapter.delivered_to("tg-gaming").last.body.text).to match(/only poll #\d+'s creator or a room operator/i)
    end

    it "answers gracefully rather than erroring on a duplicate cancel" do
      poll = open_poll
      reply(poll, "/cancel", author: ada)
      outcome = reply(poll, "/cancel", author: ada)

      expect(outcome).to be_halt
      expect(adapter.delivered_to("tg-gaming").last.body.text).to include("is already closed")
    end

    it "reads a bare 'cancel' with no prefix the same way" do
      poll = open_poll
      reply(poll, "cancel", author: ada)

      expect(writer.by_id(poll.id)).not_to be_open
    end

    it "posts the poll's closing results, the same as a natural close" do
      poll = open_poll
      react(poll, 1, author: bruno)
      reply(poll, "/cancel", author: ada)

      expect(adapter.delivered_to("tg-gaming").map(&:body).map(&:text)).to include(a_string_starting_with("Poll closed:"))
    end
  end

  describe "the room's scrollback" do
    it "counts every message in the room, whether or not the feature acted on it" do
      poll = open_poll
      key = Rubotty::Polls::RoomActivity.key(registry.current.community("sample").id, "gaming")
      posted = writer.by_id(poll.id).last_posted_at

      Rubotty::Polls::RoomActivity::VISIBLE_WINDOW.times do |i|
        run(message(origin, text: "chatter #{i}", native_id: "m#{i}", author: bruno,
                            timestamp: posted + 60 + i))
      end

      expect(activity.buried?(key, posted)).to be(true)
    end
  end

  # The invocation and its acknowledgement are one exchange (Core::CommandAck), the same
  # contract UtilityCommands already carries; see spec/features/command_cleanup_durability_spec.rb.
  # PollSurface's #acknowledge is shared by every /poll and /schedule call site (open, vote-by-reply,
  # add-option-by-reply), so exercising it through PollCommand covers ScheduleCommand's identical path too.
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
        polls: writer, board: board, ballot: ballot, lifecycle: lifecycle,
        activity: activity, ephemeral: ephemeral, cleanup: scheduler
      )
    end

    after { scheduler.stop }

    # Opening a poll (or an earlier vote) may already have claimed earlier native ids,
    # so the ack's own id is read back rather than assumed to be "d1".
    def next_native_id = "d#{adapter.delivered.size + 1}"

    def reply_fixed(poll, text, native_id:, author: ada, config: {})
      run(
        message(origin, text: text, native_id: native_id, author: author,
                        reply_to: ref("tg-gaming", card_native_id(poll))),
        config: config
      )
    end

    it "takes the invoking /poll message with it when the ack self-deletes" do
      turn_on!
      ack_id = next_native_id
      run(message(origin, text: "/poll Which map?", native_id: "77", author: ada))

      advance(30)
      scheduler.run_due

      expect(adapter.deleted).to include(["tg-gaming", ack_id], %w[tg-gaming 77])
    end

    it "leaves the /poll invocation alone when the scope opts out" do
      turn_on!
      ack_id = next_native_id
      run(message(origin, text: "/poll Which map?", native_id: "77", author: ada),
          config: { delete_command_message: false })

      advance(30)
      scheduler.run_due

      expect(adapter.deleted).to include(["tg-gaming", ack_id])
      expect(adapter.deleted).not_to include(%w[tg-gaming 77])
    end

    it "takes a vote-by-reply message with it when the ack self-deletes" do
      poll = open_poll
      ack_id = next_native_id
      reply_fixed(poll, "2", native_id: "77")

      advance(30)
      scheduler.run_due

      expect(adapter.deleted).to include(["tg-gaming", ack_id], %w[tg-gaming 77])
    end

    it "takes an add-option-by-reply message with it when the ack self-deletes" do
      poll = open_poll(config: { reply_options: true })
      ack_id = next_native_id
      reply_fixed(poll, "Nuke", native_id: "77", author: bruno)

      advance(30)
      scheduler.run_due

      expect(adapter.deleted).to include(["tg-gaming", ack_id], %w[tg-gaming 77])
    end

    it "leaves a vote-by-reply invocation alone when the scope opts out" do
      poll = open_poll
      ack_id = next_native_id
      reply_fixed(poll, "2", native_id: "77", config: { delete_command_message: false })

      advance(30)
      scheduler.run_due

      expect(adapter.deleted).to include(["tg-gaming", ack_id])
      expect(adapter.deleted).not_to include(%w[tg-gaming 77])
    end

    # A native Discord slash-command interaction is reconstructed for the pipeline; its
    # ref names no real posted message, so Core::CommandAck.pair_with must never pair it.
    it "never pairs a synthetic (Discord slash-command) /poll invocation" do
      turn_on!
      ack_id = next_native_id
      run(message(origin, text: "/poll Which map?", native_id: "77", author: ada, synthetic: true))

      advance(30)
      scheduler.run_due

      expect(adapter.deleted).to include(["tg-gaming", ack_id])
      expect(adapter.deleted).not_to include(%w[tg-gaming 77])
    end
  end
end
