# frozen_string_literal: true

require "spec_helper"

# The room route has to leave no trace, because the trace is the reprisal: the
# command is removed at once and the reporter hears by DM and nowhere else.
RSpec.describe Rubotty::Features::Reports, :control_plane do
  let(:tg) { endpoint("tg", adapter: :telegram) }
  let(:adapter) { Fakes::ReactingAdapter.new(own_id: "bot", admin_dm: true) }
  let(:adapters) { Hash.new(adapter) }
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:store) { Rubotty::ControlPlane::MemberReports.new(models: models, logger: Rubotty::Log.null) }

  let(:notifier) do
    Class.new do
      attr_reader :alerts

      def initialize = @alerts = []

      def notify_operators!(community_id:, text:)
        @alerts << { community_id: community_id, text: text }
        Rubotty::ControlPlane::AdminNotifier::Delivery.new(audience: 1, reached: 1, refused: 0, unreachable: 0)
      end
    end.new
  end

  subject(:feature) do
    described_class.new(topology: topology(room("r", tg)), adapters: adapters,
                        logger: Rubotty::Log.null, reports: store, notifier: notifier)
  end

  # feature_config is stubbed because Context#command_prefixes reads it to work
  # out what a command even looks like in this scope.
  let(:community) do
    instance_double(Rubotty::ControlPlane::Snapshot::Community,
                    id: models.community.first.id, name: "SAMPLE", feature_config: {})
  end

  def report(text: "/report", config: {}, preview: default_preview)
    message = message(tg, text: text, native_id: "1000", author: author(native_id: "u1", username: "ada"),
                          reply_to: ref("tg", "900"), reply_preview: preview)
    feature.call(Rubotty::Features::Context.new(message: message, community: community, config: config))
  end

  def default_preview
    Rubotty::Core::ReplyPreview.new(
      author: author(native_id: "777", username: "bo"), body: "the words that got reported",
      ref: Rubotty::Core::MessageRef.new("tg", "900")
    )
  end

  it "takes the report and tells the operators, with a code to answer by" do
    report

    expect(models.member_report.count).to eq(1)
    expect(notifier.alerts.length).to eq(1)
    expect(notifier.alerts.first[:text]).to include(models.member_report.first.code)
    expect(notifier.alerts.first[:text]).to include("the words that got reported")
  end

  # The trace is the reprisal, so the command goes and nothing is posted in the
  # room, not even a self-deleting notice: one still shows the room who
  # reported for as long as it lives.
  it "removes the command and posts nothing in the room" do
    report

    expect(adapter.deleted).to include(["tg", "1000"])
    expect(adapter.delivered).to be_empty
  end

  it "acknowledges the reporter by DM and nowhere else" do
    report

    expect(adapter.dms_sent.map { |dm| dm[:native_id] }).to eq(["u1"])
    expect(adapter.dms_sent.first[:text]).to include(models.member_report.first.code)
  end

  it "never relays the command onward" do
    expect(report).to be_halt
  end

  it "asks for a reply when the report names no message" do
    report(preview: nil)

    expect(models.member_report.count).to eq(0)
    expect(adapter.dms_sent.first[:text]).to include("Reply to the message")
    expect(adapter.deleted).to include(["tg", "1000"])
  end

  # A /report the bot cannot hide leaves the reporter named in front of the
  # person they reported, which is worse than having no feature at all.
  it "refuses the room route where the bot cannot delete" do
    silent = Fakes::ReactingAdapter.new(own_id: "bot", admin_dm: true)
    allow(silent).to receive(:capabilities_for).and_return(
      Rubotty::Adapters::Capabilities.new(deletes: false)
    )
    refusing = described_class.new(topology: topology(room("r", tg)), adapters: Hash.new(silent),
                                   logger: Rubotty::Log.null, reports: store, notifier: notifier)
    message = message(tg, text: "/report", native_id: "1000", author: author(native_id: "u1"),
                          reply_to: ref("tg", "900"), reply_preview: default_preview)
    refusing.call(Rubotty::Features::Context.new(message: message, community: community, config: {}))

    expect(models.member_report.count).to eq(0)
    expect(silent.dms_sent.first[:text]).to include("private chat")
  end

  it "leaves anything that is not the verb to the rest of the chain" do
    message = message(tg, text: "just talking", native_id: "1000", author: author(native_id: "u1"))
    outcome = feature.call(Rubotty::Features::Context.new(message: message, community: community, config: {}))

    expect(outcome).to be_continue
    expect(models.member_report.count).to eq(0)
  end

  # One alert per message, not per reporter, or twenty people reporting one
  # thing is twenty DMs each.
  it "raises the count on a second report rather than alerting again" do
    report
    report

    expect(models.member_report.count).to eq(1)
    expect(models.member_report.first.reports).to eq(2)
    expect(notifier.alerts.length).to eq(1)
  end
end
