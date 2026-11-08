# frozen_string_literal: true

require "spec_helper"

# An operator surprised by what a colleague did is the problem this exists to
# prevent. It wraps the audit sink rather than calling out from each feature,
# so a verb added later is announced without anybody wiring it.
RSpec.describe Rubotty::ControlPlane::OperatorAnnouncer do
  AnnouncerCommunity = Struct.new(:id, :slug, :name, :config, keyword_init: true) do
    def feature_config(_scope, _feature) = config
  end
  AnnouncerSnapshot = Struct.new(:communities)
  AnnouncerRegistry = Struct.new(:current)

  let(:sink) do
    Class.new do
      attr_reader :events

      def initialize = @events = []

      def durable? = true

      def record(**event) = (@events << event) && event

      def query(**) = [:queried]

      def count(**) = 7
    end.new
  end

  let(:notifier) do
    Class.new do
      attr_reader :dms

      def initialize = @dms = []

      def notify_operators!(community_id:, text:)
        @dms << { community_id: community_id, text: text }
        Rubotty::ControlPlane::AdminNotifier::Delivery.new(audience: 1, reached: 1, refused: 0, unreachable: 0)
      end
    end.new
  end

  let(:config) { {} }
  let(:community) { AnnouncerCommunity.new(id: 7, slug: "acme", name: "Acme", config: config) }
  let(:registry) { AnnouncerRegistry.new(AnnouncerSnapshot.new([community])) }

  subject(:announcer) do
    described_class.new(audit: sink, notifier: notifier, registry: registry, logger: Rubotty::Log.null)
  end

  def record(**overrides)
    announcer.record(**{ community: "acme", source: "moderation", action: "ban", actor: "Mel",
                         subject: "Ada", reason: "spam", outcome: "1/1" }.merge(overrides))
  end

  it "reads as an audit log, so it drops in where one is expected" do
    expect(announcer.durable?).to be(true)
    expect(announcer.query(community: "acme")).to eq([:queried])
    expect(announcer.count(community: "acme")).to eq(7)
  end

  it "still records every event it announces" do
    record

    expect(sink.events.length).to eq(1)
  end

  it "tells the operators who did what to whom, and why" do
    record

    expect(notifier.dms.first[:community_id]).to eq(7)
    text = notifier.dms.first[:text]
    expect(text).to include("Acme")
    expect(text).to include("Mel ran /ban on Ada")
    expect(text).to include("Reason: spam")
  end

  it "covers warnings and a vindication as well as the moderation verbs" do
    record(source: "warnings", action: "warn")
    record(source: "content_policy", action: "vindicate")

    expect(notifier.dms.length).to eq(2)
  end

  # Those announce themselves already, on their own terms, so announcing here
  # would be a second DM about the same removal.
  it "stays quiet for the automated halves of content policy" do
    record(source: "content_policy", action: "delete")
    record(source: "content_policy", action: "flag_notify")
    record(source: "word_filter", action: "delete")
    record(source: "link_filter", action: "delete")

    expect(notifier.dms).to be_empty
  end

  # A colleague reading that somebody ran /delete on a member learns nothing
  # about the call unless the message travels with it, and the message is by
  # then the one thing they cannot go and look at.
  it "quotes the message a verb acted on" do
    record(action: "delete", excerpt: "the words that got removed")

    expect(notifier.dms.first[:text]).to include('Message: "the words that got removed"')
  end

  it "quotes enough of a long message to judge it and no more" do
    record(action: "delete", excerpt: "z" * 400)

    text = notifier.dms.first[:text]
    expect(text).to include("z" * Rubotty::ControlPlane::OperatorAnnouncer::QUOTE_CHARS)
    expect(text).not_to include("z" * (Rubotty::ControlPlane::OperatorAnnouncer::QUOTE_CHARS + 1))
    expect(text).to include("\u2026")
  end

  it "says nothing about a message for a verb that acted on none" do
    record(action: "ban")

    expect(notifier.dms.first[:text]).not_to include("Message:")
  end

  it "names the room for a verb that acts on nobody" do
    record(action: "lock", subject: nil, channel: "tg-general")

    expect(notifier.dms.first[:text]).to include("/lock in tg-general")
  end

  describe "the switch" do
    it "is on for a community that never mentioned it" do
      record

      expect(notifier.dms.length).to eq(1)
    end

    it "is off when the community turned it off" do
      config[Rubotty::ControlPlane::OperatorAnnouncer::FIELD] = false
      record

      expect(notifier.dms).to be_empty
      expect(sink.events.length).to eq(1)
    end

    it "reads the same key written as a string" do
      config["announce_operator_actions"] = false
      record

      expect(notifier.dms).to be_empty
    end
  end

  it "says nothing about a community the registry does not know" do
    record(community: "elsewhere")

    expect(notifier.dms).to be_empty
    expect(sink.events.length).to eq(1)
  end

  # The audit row is the durable trail; a DM is a courtesy and must never cost
  # the record.
  it "still records when the announcement raises" do
    broken = Class.new do
      def notify_operators!(**) = raise("no notifier")
    end.new
    wrapped = described_class.new(audit: sink, notifier: broken, registry: registry,
                                  logger: Rubotty::Log.null)

    expect { wrapped.record(community: "acme", source: "moderation", action: "ban", actor: "Mel") }
      .not_to raise_error
    expect(sink.events.length).to eq(1)
  end

  it "is a plain pass through with no notifier at all" do
    bare = described_class.new(audit: sink, logger: Rubotty::Log.null)
    bare.record(community: "acme", source: "moderation", action: "ban", actor: "Mel")

    expect(sink.events.length).to eq(1)
  end
end
