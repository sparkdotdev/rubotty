# frozen_string_literal: true

require "spec_helper"
require "rubotty"

# A script could only ever ask whether the author was an operator at all,
# while what rubotty actually enforces is per action and per room: somebody
# may hold mute in one room and nothing in another. may() answers from the
# same directory Core::Moderation answers from.
RSpec.describe Rubotty::Core::Router, "what an author may do" do
  include Fakes

  let(:tg) { endpoint("tg-lounge", adapter: :telegram, account: "tg") }
  let(:other) { endpoint("tg-attic", adapter: :telegram, account: "tg") }

  # Holds mute, in one room only.
  let(:ada) do
    Rubotty::Core::Moderation::Operator.new(
      name: "ada", identities: { telegram: ["55"] }, actions: [:mute], rooms: ["lounge"]
    )
  end
  let(:directory) { Rubotty::Core::Moderation::Directory.new([ada]) }

  let(:lounge) { Rubotty::Core::Room.new(id: "lounge", label: "Lounge", endpoints: [tg]) }
  let(:attic) { Rubotty::Core::Room.new(id: "attic", label: "Attic", endpoints: [other]) }

  let(:community) { Struct.new(:id, :rooms, :operators).new(1, [lounge, attic], directory) }

  def context_for(origin, author_id: "55")
    incoming = message(origin, text: "anything", author: author(native_id: author_id))
    Struct.new(:message, :community, :channel, :operators).new(incoming, community, "lounge", directory)
  end

  def may(context, action)
    router = described_class.allocate
    router.send(:script_may_handler, context).call(action)
  end

  it "says yes to a verb they hold, in a room they hold it in" do
    expect(may(context_for(tg), "mute")).to be(true)
  end

  # The half the boolean could never express.
  it "says no to a verb they do not hold, in a room they are an operator in" do
    expect(may(context_for(tg), "ban")).to be(false)
  end

  # The other half: the same person, the same verb, a room the grant does not
  # reach.
  it "says no in a room their grant does not cover" do
    expect(may(context_for(other), "mute")).to be(false)
  end

  it "says no for somebody the directory has never heard of" do
    expect(may(context_for(tg, author_id: "999"), "mute")).to be(false)
  end

  # A script cannot invent a verb and have it answered, or the grants page fills
  # up with per script vocabulary. An unknown verb is false rather than a raise,
  # so a typo reads like a refusal instead of killing the invocation.
  it "refuses a verb that is not one rubotty enforces" do
    expect(may(context_for(tg), "start_trivia")).to be(false)
    expect(may(context_for(tg), "")).to be(false)
  end

  # Same honesty warn keeps: there is nobody to ask about when no message caused
  # the run.
  it "says no on a woken run, where there is no author" do
    woken = Struct.new(:message, :community, :channel, :operators).new(nil, community, "lounge", directory)

    expect(may(woken, "mute")).to be(false)
  end
end
