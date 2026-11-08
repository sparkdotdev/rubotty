# frozen_string_literal: true

require "spec_helper"

# A command typed bare asks for its fields one at a time and takes the whole
# exchange away again, driven entirely by what Core::CommandRegistry already
# says about /event.
RSpec.describe Rubotty::Features::CommandBuilder do
  include Builders

  let(:tg) { endpoint("tg") }
  let(:adapter) { Fakes::ReactingAdapter.new }
  let(:adapters) { Hash.new(adapter) }
  let(:clock) { -> { @now ||= Time.at(1_700_000_000) } }
  let(:scheduler) { Rubotty::Core::Scheduler.new(logger: Rubotty::Log.null, clock: clock) }
  let(:pending) do
    Rubotty::Core::PendingOperations.new(ttl: described_class::TTL_SECONDS, clock: clock,
                                         logger: Rubotty::Log.null)
  end
  let(:ephemeral) do
    Rubotty::Core::EphemeralMessage.new(
      adapters: adapters, session_id: "s", topology: topology(room("r", tg)), logger: Rubotty::Log.null
    )
  end
  let(:ran) { [] }

  # A platform that can post but cannot take anything away again, which is
  # what IRC is.
  let(:mute_adapter) do
    Class.new(Fakes::RecordingAdapter) do
      def capabilities
        @capabilities ||= Rubotty::Adapters::Capabilities.new(edits: false, deletes: false, replies: false)
      end
    end.new
  end

  def advance(seconds)
    @now = clock.call + seconds
    scheduler.run_due
  end

  def feature(adapters: self.adapters)
    @feature ||= described_class.new(
      topology: topology(room("r", tg)), adapters: adapters, logger: Rubotty::Log.null,
      ephemeral: ephemeral, cleanup: scheduler, pending: pending, run: ->(message) { ran << message }
    )
  end

  # Only #feature_enabled? and #feature_config (for the shared command marker)
  # are ever read off a community here.
  def fake_community(enabled: { "events" => true })
    Class.new do
      define_method(:initialize) { |flags| @flags = flags }
      define_method(:id) { "c1" }
      define_method(:feature_enabled?) { |_channel, feature| @flags.fetch(feature, false) }
      define_method(:feature_config) { |_channel, _feature| {} }
    end.new(enabled)
  end

  let(:community) { fake_community }

  def say(text, native_id: "m#{@said = (@said || 0) + 1}", author_id: "u1", reply_to: nil, community: self.community)
    Rubotty::Features::Context.new(
      message: message(tg, text: text, native_id: native_id, reply_to: reply_to,
                       author: author(native_id: author_id, username: "ada")),
      config: {}, community: community, channel: nil
    )
  end

  def prompts = adapter.delivered_to("tg").map { |posted| posted.body.text }

  def deleted = adapter.deleted.map(&:last)

  after { scheduler.stop }

  it "is catalogued, on by default, and reads only chat" do
    expect(Rubotty::Features::Catalog.classes).to include(described_class)
    expect(described_class.feature_name).to eq("command_builder")
    expect(described_class.default_enabled?).to be(true)
    expect(described_class.observes).to eq([:chat])
  end

  it "waits three minutes for an answer, not the shared fifteen" do
    expect(described_class::TTL_SECONDS).to eq(180)
    expect(described_class::TTL_SECONDS).to be < Rubotty::Core::PendingOperations::DEFAULT_TTL
  end

  describe "starting" do
    it "asks for the first field of a bare command and swallows the invocation" do
      outcome = feature.call(say("/event"))

      expect(outcome.halt?).to be(true)
      expect(prompts.first).to include("/event (1 of 10)", "title.", "the event's title.")
    end

    it "offers /schedule, /reschedule and /rsvp too, the same way it offers /event" do
      expect(feature.call(say("/schedule")).halt?).to be(true)
      expect(prompts.last).to include("/schedule (1 of 5)", "name.")

      expect(feature.call(say("/reschedule")).halt?).to be(true)
      expect(prompts.last).to include("/reschedule (1 of 9)", "id.")

      expect(feature.call(say("/rsvp")).halt?).to be(true)
      expect(prompts.last).to include("/rsvp (1 of 2)", "id.")
    end

    # The whole point: the description arrives when it is useful instead of as
    # a wall printed on failure.
    it "leaves an invocation that already carries arguments to the command itself" do
      outcome = feature.call(say("/event title=x"))

      expect(outcome.halt?).to be(false)
      expect(prompts).to be_empty
    end

    it "offers nothing for a command that is not on the list yet" do
      expect(feature.call(say("/poll")).halt?).to be(false)
    end

    it "offers nothing where the command's own feature is switched off here" do
      outcome = feature.call(say("/event", community: fake_community(enabled: { "events" => false })))

      expect(outcome.halt?).to be(false)
      expect(prompts).to be_empty
    end

    it "offers nothing without a resolved community" do
      expect(feature.call(say("/event", community: nil)).halt?).to be(false)
    end

    # The gate is the adapter's own answer, so a platform that gains deletion
    # later gets builders with no change here.
    it "offers nothing on a platform that cannot delete a message" do
      outcome = feature(adapters: Hash.new(mute_adapter)).call(say("/event"))

      expect(outcome.halt?).to be(false)
      expect(mute_adapter.delivered).to be_empty
    end

    # Swallowing the invocation and then failing to ask anything would leave a
    # member with silence where the usage line used to be.
    it "falls back to the command's own answer when the prompt cannot be posted" do
      adapter.fail_next(StandardError.new("boom"))
      outcome = feature.call(say("/event"))

      expect(outcome.halt?).to be(false)
      expect(pending.size).to eq(0)
    end

    it "leaves ordinary chat alone" do
      expect(feature.call(say("just chatting")).halt?).to be(false)
      expect(prompts).to be_empty
    end
  end

  describe "answering" do
    before { feature.call(say("/event")) }

    it "takes the next answer as the field it just asked for" do
      outcome = feature.call(say("Game night"))

      expect(outcome.halt?).to be(true)
      expect(prompts.last).to include("(2 of 10)", "start.")
    end

    it "keeps asking until every required field is answered, then runs the command" do
      feature.call(say("Game night"))
      feature.call(say("tomorrow 4pm"))
      feature.call(say("gaming"))
      feature.call(say("/done"))

      expect(ran.map { |message| message.body.text })
        .to eq([%(/event title="Game night" start="tomorrow 4pm" kind=gaming)])
    end

    # A finished line is a message nobody posted, exactly as a native slash
    # command already is, which is what keeps it off the bridge.
    it "runs it as a synthetic message from the person who built it" do
      feature.call(say("Game night"))
      feature.call(say("tomorrow 4pm"))
      feature.call(say("gaming"))
      feature.call(say("/done"))

      expect(ran.first.synthetic?).to be(true)
      expect(ran.first.author.native_id).to eq("u1")
      expect(ran.first.origin.id).to eq("tg")
    end

    it "re-asks the same field rather than abandoning a form over a refused answer" do
      feature.call(say("Game night"))
      feature.call(say("/skip"))

      expect(prompts.last).to include("That field is required.", "(2 of 10)", "start.")
      expect(ran).to be_empty
    end

    it "keeps the answers already given when it re-asks" do
      feature.call(say("Game night"))
      feature.call(say("/skip"))
      feature.call(say("tomorrow 4pm"))
      feature.call(say("gaming"))
      7.times { feature.call(say("/skip")) }

      expect(ran.first.body.text).to include(%(title="Game night"))
    end

    it "offers to run the command as soon as nothing required is left" do
      feature.call(say("Game night"))
      feature.call(say("tomorrow 4pm"))
      feature.call(say("gaming"))

      expect(prompts.last).to include("(4 of 10, optional)", "/done to run it now")
    end

    it "refuses to run early while a required field is still open" do
      feature.call(say("/done"))

      expect(ran).to be_empty
      expect(prompts.last).to include("That field is required.", "(1 of 10)", "title.")
    end

    it "leaves an optional field out when it is skipped" do
      feature.call(say("Game night"))
      feature.call(say("tomorrow 4pm"))
      feature.call(say("gaming"))
      feature.call(say("Europe/Lisbon"))
      6.times { feature.call(say("/skip")) }

      expect(ran.first.body.text).to include("tz=Europe/Lisbon")
      expect(ran.first.body.text).not_to include("game=")
    end
  end

  # A skipped plain field ahead of another would shift the rest along, since
  # command_line writes plain values back in registry order. /schedule's
  # fields are all keyed; /reschedule and /rsvp each have only one plain
  # field, id, and it is required, so neither can hit that.
  describe "the other newly buildable commands" do
    it "assembles /schedule with its keyed fields, skipping the optional ones" do
      feature.call(say("/schedule"))
      feature.call(say("Game night"))
      feature.call(say("Stellaris"))
      feature.call(say("today 7pm | tomorrow 8pm"))
      2.times { feature.call(say("/skip")) }

      expect(ran.first.body.text)
        .to eq(%(/schedule name="Game night" game=Stellaris times="today 7pm | tomorrow 8pm"))
    end

    it "keeps /reschedule's id plain and unkeyed, ahead of the keyed fields it changes" do
      feature.call(say("/reschedule"))
      feature.call(say("42"))
      feature.call(say("/done"))

      expect(ran.first.body.text).to eq("/reschedule 42")
    end

    it "assembles /rsvp as two plain values in the order they were asked for" do
      feature.call(say("/rsvp"))
      feature.call(say("42"))
      feature.call(say("yes"))

      expect(ran.first.body.text).to eq("/rsvp 42 yes")
    end
  end

  describe "clearing up" do
    it "removes the prompts, the answers and the invocation once the command runs" do
      feature.call(say("/event", native_id: "inv"))
      feature.call(say("Game night", native_id: "a1"))
      feature.call(say("tomorrow 4pm", native_id: "a2"))
      feature.call(say("gaming", native_id: "a3"))
      7.times { |i| feature.call(say("/skip", native_id: "s#{i}")) }

      expect(deleted).to include("inv", "a1", "a2", "a3", "s6")
    end

    it "removes every prompt it posted, not only the last one" do
      feature.call(say("/event"))
      feature.call(say("Game night"))
      feature.call(say("tomorrow 4pm"))
      feature.call(say("gaming"))
      7.times { feature.call(say("/skip")) }

      posted = adapter.delivered.length
      expect(deleted.count { |id| id.start_with?("d") }).to eq(posted)
    end

    it "stops on a deliberate cancel, running nothing and leaving nothing behind" do
      feature.call(say("/event", native_id: "inv"))
      feature.call(say("Game night", native_id: "a1"))
      feature.call(say("/cancel", native_id: "stop"))

      expect(ran).to be_empty
      expect(deleted).to include("inv", "a1", "stop")
      expect(pending.size).to eq(0)
    end

    # Nothing fires when a pending operation expires, so the removal rides the
    # timed self-delete every prompt is posted with.
    it "takes an abandoned exchange away three minutes after it went quiet" do
      feature.call(say("/event", native_id: "inv"))
      advance(described_class::TTL_SECONDS + 1)

      expect(deleted).to include("inv")
      expect(pending.size).to eq(0)
    end

    it "runs the three minutes from the last answer, not from the invocation" do
      feature.call(say("/event"))
      advance(described_class::TTL_SECONDS - 10)
      feature.call(say("Game night"))
      advance(20)

      expect(prompts.last).to include("(2 of 10)")
      expect(pending.size).to eq(1)
    end

    # The timers are still armed when a form finishes early, and must not go
    # back for messages that are already gone.
    it "leaves its own timers inert once the exchange has been removed" do
      feature.call(say("/event"))
      feature.call(say("/cancel"))
      before = adapter.deleted.length
      advance(described_class::TTL_SECONDS + 1)

      expect(adapter.deleted.length).to eq(before)
    end
  end

  describe "telling an answer from ordinary chat" do
    before { feature.call(say("/event")) }

    it "reads a reply to its own prompt as the answer" do
      outcome = feature.call(say("Game night", reply_to: ref("tg", "d1")))

      expect(outcome.halt?).to be(true)
      expect(prompts.last).to include("(2 of 10)")
    end

    it "leaves a reply pointing at somebody else's message as ordinary chat" do
      outcome = feature.call(say("no, that was last week", reply_to: ref("tg", "other")))

      expect(outcome.halt?).to be(false)
      expect(prompts.length).to eq(1)
    end

    it "leaves another command alone rather than swallowing it as a value" do
      outcome = feature.call(say("/help"))

      expect(outcome.halt?).to be(false)
      expect(prompts.length).to eq(1)
    end

    # Every field a command declares is typed, so a photo cannot be answering
    # one and is bridged as usual rather than swallowed into the form.
    it "leaves a wordless message alone" do
      outcome = feature.call(say(""))

      expect(outcome.halt?).to be(false)
      expect(prompts.length).to eq(1)
    end

    it "never touches a message from somebody who has no form open" do
      outcome = feature.call(say("hello all", author_id: "u2"))

      expect(outcome.halt?).to be(false)
    end

    # The per-actor key is what makes this work, so two people can build at
    # once in one room.
    it "keeps two members' forms apart" do
      feature.call(say("/event", author_id: "u2"))
      feature.call(say("Game night", author_id: "u1"))
      feature.call(say("Book club", author_id: "u2"))
      feature.call(say("tomorrow 4pm", author_id: "u1"))
      feature.call(say("gaming", author_id: "u1"))
      7.times { feature.call(say("/skip", author_id: "u1")) }

      expect(ran.length).to eq(1)
      expect(ran.first.body.text).to include(%(title="Game night"))
      expect(pending.size).to eq(1)
    end
  end
end
