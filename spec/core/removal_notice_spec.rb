# frozen_string_literal: true

require "spec_helper"

# The shared helper the word filter, link filter and mention-spam guard all call,
# so the audit record and the self-deleting @mention notice have one shape and TTL.
RSpec.describe Rubotty::Core::RemovalNotice do
  let(:tg) { endpoint("tg") }
  let(:dc) { endpoint("dc") }
  let(:adapter) { Fakes::RecordingAdapter.new(own_id: "bot-1") }
  let(:adapters) { Hash.new(adapter) }
  let(:cleanup) { instance_spy(Rubotty::Core::Scheduler) }

  # A recording audit sink, standing in for the durable audit log.
  let(:recorder) do
    Class.new do
      attr_reader :events

      def initialize = @events = []

      def record(**kwargs)
        @events << kwargs
        kwargs
      end
    end.new
  end

  let(:ephemeral) do
    Rubotty::Core::EphemeralMessage.new(
      adapters: adapters, session_id: "s", topology: topology(room("r", tg, dc)), logger: Rubotty::Log.null
    )
  end

  def helper(ephemeral: nil, cleanup: nil, audit: nil, source: "word_filter", name: "word filter")
    described_class.new(
      ephemeral: ephemeral, cleanup: cleanup, audit: audit,
      logger: Rubotty::Log.null, source: source, name: name
    )
  end

  def community = instance_double(Rubotty::ControlPlane::Snapshot::Community, slug: "acme")

  def context(config: {}, author: author(native_id: "u9", first_name: "Ada", username: "troll"), with_community: true)
    Rubotty::Features::Context.new(
      message: message(tg, text: "x", native_id: "5", author: author),
      community: with_community ? community : nil, config: config
    )
  end

  # A removal nobody hears about is the failure this alert exists to prevent:
  # the in-room notice self-deletes and the message itself is gone, so the
  # operators had no way to learn a deterministic filter had acted at all.
  describe "the operator alert" do
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

    def alerting_community
      instance_double(Rubotty::ControlPlane::Snapshot::Community, slug: "acme", id: 7, name: "Acme")
    end

    def alerting_context(config: {})
      Rubotty::Features::Context.new(
        message: message(tg, text: "this whole process is bullshit", native_id: "5",
                         author: author(native_id: "u9", first_name: "Ada", username: "troll")),
        community: alerting_community, config: config
      )
    end

    def alerting(alerts: true, config: {})
      described_class.new(
        ephemeral: ephemeral, cleanup: cleanup, logger: Rubotty::Log.null,
        source: "word_filter", name: "word filter", adapters: adapters,
        admin_notifier: notifier, alerts: alerts
      ).apply(context: alerting_context(config: config), action: "delete", reason: "Contained profanity.")
    end

    it "DMs the operators what was removed, from whom and why" do
      alerting

      expect(notifier.dms.length).to eq(1)
      expect(notifier.dms.first[:community_id]).to eq(7)
      text = notifier.dms.first[:text]
      expect(text).to include("Acme")
      expect(text).to include("word_filter removed a message")
      expect(text).to include("Ada")
      expect(text).to include("Contained profanity.")
      expect(text).to include("this whole process is bullshit")
    end

    # A rate guard drops messages by the handful, so one DM per dropped message
    # would bury the alerts an operator actually needs to read.
    it "stays quiet for a filter that did not ask to alert" do
      alerting(alerts: false)

      expect(notifier.dms).to be_empty
    end

    it "stays quiet when the scope turned it off" do
      alerting(config: { Rubotty::Core::RemovalNotice::NOTIFY_FIELD => false })

      expect(notifier.dms).to be_empty
    end

    it "is on for a scope that never mentioned it, since silence is the failure" do
      expect(described_class.notify_operators?({})).to be(true)
      expect(described_class.notify_operators?(nil)).to be(true)
      expect(described_class.notify_operators?("notify_operators" => false)).to be(false)
    end

    # A flag leaves the message in the room for an operator to look at, so it
    # is not the thing that goes unseen.
    it "says nothing on a flag, only on a removal" do
      described_class.new(
        logger: Rubotty::Log.null, source: "word_filter", adapters: adapters,
        admin_notifier: notifier, alerts: true
      ).apply(context: alerting_context, action: "flag", reason: "Contained profanity.")

      expect(notifier.dms).to be_empty
    end

    it "still removes and audits when the DM cannot go out" do
      broken = Class.new do
        def notify_operators!(community_id:, text:) = raise("no notifier")
      end.new
      helper = described_class.new(
        ephemeral: ephemeral, cleanup: cleanup, audit: recorder, logger: Rubotty::Log.null,
        source: "word_filter", name: "word filter", adapters: adapters,
        admin_notifier: broken, alerts: true
      )

      expect { helper.apply(context: alerting_context, action: "delete", reason: "Contained profanity.") }
        .not_to raise_error
      expect(recorder.events.last).to include(action: "delete")
      expect(adapter.delivered_to("tg")).not_to be_empty
    end
  end

  describe "the removal notice" do
    it "posts the exact standard notice, pinging the author on the origin platform" do
      helper(ephemeral: ephemeral, cleanup: cleanup)
        .apply(context: context, action: "delete", reason: "Because reasons.")

      notice = adapter.delivered_to("tg").last
      expect(notice.body.text).to eq("Ada Your last message was automatically removed: Because reasons.")
      mention = notice.body.spans.find { |s| s.kind == :mention }
      expect(mention.begin_index).to eq(0)
      expect(mention.end_index).to eq("Ada".length)
      expect(mention.attributes).to eq(fake_id_for_target: "u9")
    end

    it "degrades to the plain display name (no ping) when the author has no native id" do
      helper(ephemeral: ephemeral, cleanup: cleanup)
        .apply(context: context(author: author(native_id: nil, first_name: "Ghost")),
               action: "delete", reason: "No id known.")

      notice = adapter.delivered_to("tg").last
      expect(notice.body.text).to eq("Ghost Your last message was automatically removed: No id known.")
      expect(notice.body.spans).to be_empty
    end

    it "terminates a reason that lacks sentence punctuation, and does not double an existing full stop" do
      subject = helper(ephemeral: ephemeral, cleanup: cleanup)
      subject.apply(context: context, action: "delete", reason: "no trailing stop")
      expect(adapter.delivered_to("tg").last.body.text).to end_with("removed: no trailing stop.")

      subject.apply(context: context, action: "delete", reason: "Already ends.")
      expect(adapter.delivered_to("tg").last.body.text).to end_with("removed: Already ends.")
    end

    it "posts only to the origin endpoint, not across the room" do
      helper(ephemeral: ephemeral, cleanup: cleanup).apply(context: context, action: "delete", reason: "x.")
      expect(adapter.delivered_to("tg")).not_to be_empty
      expect(adapter.delivered_to("dc")).to be_empty
    end
  end

  describe "the self-delete TTL" do
    it "schedules the notice's self-delete for the configured TTL" do
      helper(ephemeral: ephemeral, cleanup: cleanup)
        .apply(context: context(config: { removal_notice_ttl_seconds: 30 }), action: "delete", reason: "x.")
      expect(cleanup).to have_received(:after).with(30)
    end

    it "defaults to 60 seconds when the scope leaves the TTL unset" do
      helper(ephemeral: ephemeral, cleanup: cleanup).apply(context: context, action: "delete", reason: "x.")
      expect(cleanup).to have_received(:after).with(60)
    end

    it "keeps the notice persistent (schedules nothing) when the TTL is 0" do
      helper(ephemeral: ephemeral, cleanup: cleanup)
        .apply(context: context(config: { removal_notice_ttl_seconds: 0 }), action: "delete", reason: "x.")
      expect(cleanup).not_to have_received(:after)
    end
  end

  describe ".ttl_seconds" do
    it "reads the field under either a symbol or a string key" do
      expect(described_class.ttl_seconds(removal_notice_ttl_seconds: 45)).to eq(45)
      expect(described_class.ttl_seconds("removal_notice_ttl_seconds" => 45)).to eq(45)
    end

    it "falls back to the 60-second default for a missing, non-numeric or negative value" do
      expect(described_class.ttl_seconds({})).to eq(60)
      expect(described_class.ttl_seconds(removal_notice_ttl_seconds: "soon")).to eq(60)
      expect(described_class.ttl_seconds(removal_notice_ttl_seconds: -5)).to eq(60)
    end

    it "honours a configured 0 as persist" do
      expect(described_class.ttl_seconds(removal_notice_ttl_seconds: 0)).to eq(0)
    end
  end

  describe "the durable audit record" do
    it "records the removal as a structured event, the filter as the automated actor" do
      helper(audit: recorder, source: "word_filter")
        .apply(context: context, action: "delete", reason: "Watch it.", metadata: { pattern: "badword" })

      event = recorder.events.last
      expect(event).to include(
        source: "word_filter", action: "delete", community: "acme",
        actor: "word_filter", subject: "Ada", subject_native_id: "u9",
        adapter: :fake, channel: "tg", target_ref: "tg:5", outcome: "delete", reason: "Watch it."
      )
      expect(event[:actor_native_id]).to be_nil
      expect(event[:metadata]).to eq(pattern: "badword")
    end

    it "records a nil community when there is no control plane" do
      helper(audit: recorder).apply(context: context(with_community: false), action: "delete", reason: "x.")
      expect(recorder.events.last[:community]).to be_nil
    end

    it "records the requested action in the metadata only when it degraded to a stub" do
      helper(audit: recorder).apply(context: context, action: "delete", reason: "x.", requested: "warn")
      expect(recorder.events.last[:metadata]).to include(requested: "warn")

      helper(audit: recorder).apply(context: context, action: "delete", reason: "x.", requested: "delete")
      expect(recorder.events.last[:metadata]).to be_nil
    end
  end

  describe "the flag action" do
    it "records an audit event but posts no notice (nothing was removed)" do
      helper(ephemeral: ephemeral, cleanup: cleanup, audit: recorder)
        .apply(context: context, action: "flag", reason: "flagged.")
      expect(recorder.events.last[:action]).to eq("flag")
      expect(adapter.delivered_to("tg")).to be_empty
      expect(cleanup).not_to have_received(:after)
    end
  end

  describe "robustness" do
    it "is a silent no-op for the notice when no ephemeral primitive is wired, but still audits" do
      expect { helper(audit: recorder).apply(context: context, action: "delete", reason: "x.") }.not_to raise_error
      expect(recorder.events.last[:action]).to eq("delete")
      expect(adapter.delivered).to be_empty
    end

    it "never raises out when the audit sink fails" do
      failing = Class.new { def record(**) = raise("boom") }.new
      expect do
        helper(ephemeral: ephemeral, cleanup: cleanup, audit: failing)
          .apply(context: context, action: "delete", reason: "x.")
      end.not_to raise_error
      # The notice still posts even though the audit write failed.
      expect(adapter.delivered_to("tg")).not_to be_empty
    end
  end
end
