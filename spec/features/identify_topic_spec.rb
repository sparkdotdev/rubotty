# frozen_string_literal: true

require "spec_helper"

# The manual fallback for a room or topic auto-discovery never picked up. always_enabled?
# makes it run regardless of feature_settings, and that bypass belongs to Pipeline.
RSpec.describe Rubotty::Features::IdentifyTopic do
  let(:tg) { endpoint("tg") }
  let(:adapter) { Fakes::ReactingAdapter.new }
  let(:adapters) { Hash.new(adapter) }
  let(:scheduler) { Rubotty::Core::Scheduler.new(logger: Rubotty::Log.null) }
  let(:ephemeral) do
    Rubotty::Core::EphemeralMessage.new(
      adapters: adapters, session_id: "s", topology: topology(room("r", tg)), logger: Rubotty::Log.null
    )
  end

  Recorded = Struct.new(:community_id, :endpoint_key, :name, :operator, keyword_init: true)
  FakeChannel = Struct.new(:label, :suggested, keyword_init: true)

  let(:calls) { [] }
  let(:identify_result) { FakeChannel.new(label: "Lisbon Meetup", suggested: false) }

  def fake_channel_discovery(result: identify_result)
    recorded = calls
    Class.new do
      define_method(:identify_known) do |community_id:, endpoint_key:, name:, operator:|
        recorded << Recorded.new(community_id: community_id, endpoint_key: endpoint_key,
                                 name: name, operator: operator)
        result
      end
    end.new
  end

  def feature(channel_discovery: fake_channel_discovery)
    described_class.new(
      topology: topology(room("r", tg)), adapters: adapters, logger: Rubotty::Log.null,
      ephemeral: ephemeral, cleanup: scheduler, channel_discovery: channel_discovery
    )
  end

  let(:operator) { Rubotty::Core::Moderation::Operator.new(name: "Op", identities: { fake: ["u1"] }) }
  let(:operators) { Rubotty::Core::Moderation::Directory.new([operator]) }
  # A community that resolves nothing of its own beyond its id, which is what
  # scopes the relabel. Its operator and people directories answer nil so the
  # injected ones still apply, which is the precedence Context sets.
  let(:community) do
    Struct.new(:id) do
      def feature_config(*) = {}
      def operators = nil
      def people = nil
      def rooms = nil
    end.new("c1")
  end

  # The community defaults to a real one, since under the control plane a
  # message that reached the pipeline resolved to a community to get there.
  def context(text, operators: nil, in_community: community)
    Rubotty::Features::Context.new(
      message: message(tg, text: text, author: author(native_id: "u1")),
      config: {}, community: in_community, operators: operators
    )
  end

  def last_reply = adapter.delivered_to("tg").last&.body&.text

  after { scheduler.stop }

  it "declares itself always_enabled, unlike every other command feature" do
    expect(described_class.always_enabled?).to be(true)
    expect(described_class.feature_name).to eq("identify_topic")
    expect(described_class.observes).to eq([:chat])
  end

  it "ignores a message that is not the command at all, so the pipeline continues" do
    outcome = feature.call(context("just chatting"))
    expect(outcome.halt?).to be(false)
    expect(calls).to be_empty
  end

  it "recognises the command with either default prefix" do
    feature.call(context("/identify-topic Lisbon Meetup"))
    feature.call(context("!identify-topic Lisbon Meetup"))
    expect(calls.size).to eq(2)
  end

  # The spelling Telegram's "/" menu offers, since a Telegram command name may hold no
  # hyphen. Picking it from that menu has to reach this feature.
  it "recognises the underscored spelling the Telegram command menu publishes" do
    feature.call(context("/identify_topic Lisbon Meetup"))
    expect(calls.size).to eq(1)
    expect(calls.first.name).to eq("Lisbon Meetup")
  end

  it "recognises it with the @botname suffix Telegram appends in groups" do
    feature.call(context("/identify_topic@thebridgebot Lisbon Meetup"))
    expect(calls.size).to eq(1)
    expect(calls.first.name).to eq("Lisbon Meetup")
  end

  it "still ignores a word that merely looks like the command" do
    feature.call(context("/identify_topics Lisbon Meetup"))
    feature.call(context("/identify Lisbon Meetup"))
    expect(calls).to be_empty
  end

  # Issue #1802: the origin endpoint key went through on its own, and endpoint
  # keys are globally unique, so the row it found could be another tenant's.
  it "passes the community, the origin endpoint's id, the full name and operator status through" do
    feature.call(context("/identify-topic Lisbon Meetup", operators: operators))
    expect(calls.first.community_id).to eq("c1")
    expect(calls.first.endpoint_key).to eq("tg")
    expect(calls.first.name).to eq("Lisbon Meetup")
    expect(calls.first.operator).to be(true)
  end

  it "treats an unresolvable author as a regular member, never an operator, fail closed" do
    feature.call(context("/identify-topic x", operators: nil))
    expect(calls.first.operator).to be(false)
  end

  it "swallows the command either way (never relays it as chat content)" do
    outcome = feature.call(context("/identify-topic Lisbon Meetup"))
    expect(outcome.halt?).to be(true)
  end

  it "replies with a usage reminder, still swallowed, when the name is left blank" do
    outcome = feature.call(context("/identify-topic"))
    expect(outcome.halt?).to be(true)
    expect(calls).to be_empty
    expect(last_reply).to eq("Usage: /identify-topic <name>")
  end

  it "confirms identification immediately for an operator" do
    feature.call(context("/identify-topic Lisbon Meetup",
                          operators: operators))
    expect(last_reply).to include('Identified this room/topic as "Lisbon Meetup"')
  end

  it "reports a pending suggestion for anyone else" do
    result = FakeChannel.new(label: "Lisbon Meetup", suggested: true)
    feature(channel_discovery: fake_channel_discovery(result: result)).call(
      context("/identify-topic Lisbon Meetup")
    )
    expect(last_reply).to include('Suggested "Lisbon Meetup"')
    expect(last_reply).to include("An operator needs to approve it")
  end

  it "reports a clean failure when channel_discovery finds nothing to rename" do
    feature(channel_discovery: fake_channel_discovery(result: nil)).call(
      context("/identify-topic Lisbon Meetup")
    )
    expect(last_reply).to eq("Sorry, I couldn't identify this channel.")
  end

  it "refuses rather than relabelling by key alone when the room resolves to no community" do
    outcome = feature.call(context("/identify-topic Lisbon Meetup", in_community: nil))

    expect(outcome.halt?).to be(true)
    expect(calls).to be_empty
    expect(last_reply).to include("no community")
  end

  it "is a graceful no-op without a control plane (nil channel_discovery)" do
    outcome = feature(channel_discovery: nil).call(context("/identify-topic Lisbon Meetup"))
    expect(outcome.halt?).to be(true)
    expect(last_reply).to include("no control plane connected")
  end

  # reply_for reaches into channel_discovery, which is real DB access in production, so a
  # raise there must not propagate out of #call and leave the asker with nothing.
  describe "when reply_for itself raises (a real internal failure, not an authorization refusal)" do
    def raising_channel_discovery
      Class.new do
        def identify_known(**) = raise StandardError, "db went away"
      end.new
    end

    it "still replies, with an honest, actionable message, instead of propagating the raise" do
      outcome = nil
      expect { outcome = feature(channel_discovery: raising_channel_discovery).call(context("/identify-topic x")) }
        .not_to raise_error
      expect(outcome.halt?).to be(true)
      expect(last_reply).to eq("Sorry, something went wrong identifying this channel. Try again, or check the logs.")
    end
  end
end
