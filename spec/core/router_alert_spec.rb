# frozen_string_literal: true

require "spec_helper"

# The handler is exercised directly rather than through Lua: what is under test
# is the order the two halves happen in and what survives when the second fails.
RSpec.describe Rubotty::Core::Router, "raising an alert", :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:community) { models.community.first }
  let(:alerts) { Rubotty::ControlPlane::Alerts.new(models: models, logger: Rubotty::Log.null) }

  # Only what the handler reads off a context: the community, and the channel
  # the audit row names.
  let(:context) { Struct.new(:community, :channel).new(community, "tg-general") }

  let(:audit) do
    Class.new do
      attr_reader :rows

      def initialize = @rows = []

      def record(**row) = @rows << row
    end.new
  end

  let(:notifier) do
    Class.new do
      attr_reader :calls

      def initialize = @calls = []

      def notify_operators!(community_id:, text:)
        @calls << { community_id: community_id, text: text }
        Rubotty::ControlPlane::AdminNotifier::Delivery.new(audience: 2, reached: 2, refused: 0, unreachable: 0)
      end
    end.new
  end

  def handler(alerts_service: alerts, admin_notifier: notifier)
    described_class.allocate.send(
      :script_alert_handler, context, audit: audit, alerts: alerts_service,
                                      admin_notifier: admin_notifier, script_name: "slur_alert",
                                      room_key: "general", logger: Rubotty::Log.null
    )
  end

  describe "quiet, which is what a bare alert(text) means" do
    it "records it and tells nobody" do
      expect(handler.call("somebody is upset in general")).to be(true)

      row = models.alert.first
      expect(row.mode).to eq("quiet")
      expect(row.text).to eq("somebody is upset in general")
      expect(notifier.calls).to be_empty
    end

    it "keeps writing the audit row, so the history an operator already reads is unchanged" do
      handler.call("something happened")

      expect(audit.rows.first).to include(source: "scripts", action: "alert",
                                          reason: "something happened", outcome: "quiet")
      expect(audit.rows.first[:community]).to eq(community.slug)
    end

    it "records the room and the script that raised it" do
      handler.call("something happened")

      row = models.alert.first
      expect(row.room_key).to eq("general")
      expect(row.script).to eq("slur_alert")
    end

    it "means the same thing whether the mode is left out or named" do
      handler.call("first")
      handler.call("second", "quiet")

      expect(models.alert.map(&:mode)).to eq(%w[quiet quiet])
      expect(notifier.calls).to be_empty
    end
  end

  describe "loud" do
    it "records it and DMs the community's operators" do
      expect(handler.call("a slur in general", "loud")).to be(true)

      expect(models.alert.first.mode).to eq("loud")
      expect(notifier.calls.first[:community_id]).to eq(community.id)
    end

    it "names the community in the DM, since an operator may run several" do
      handler.call("a slur in general", "loud")

      expect(notifier.calls.first[:text]).to eq("#{community.name}: a slur in general")
    end

    it "writes down how many operators the DM reached" do
      handler.call("a slur in general", "loud")

      expect(models.alert.first.delivered_to).to eq(2)
    end

    # The record comes first and the delivery second.
    it "keeps the alert when the DM blows up" do
      angry = Class.new do
        def notify_operators!(**) = raise(StandardError, "every gateway is down")
      end.new

      expect(handler(admin_notifier: angry).call("a slur in general", "loud")).to be(true)
      expect(models.alert.first.text).to eq("a slur in general")
      expect(models.alert.first.delivered_to).to eq(0)
    end

    it "keeps the alert when nothing can DM anybody at all" do
      expect(handler(admin_notifier: nil).call("a slur in general", "loud")).to be(true)
      expect(models.alert.count).to eq(1)
    end

    it "records a loud alert that reached nobody as reaching nobody" do
      unreachable = Class.new do
        def notify_operators!(**)
          Rubotty::ControlPlane::AdminNotifier::Delivery.new(audience: 2, reached: 0, refused: 2, unreachable: 0)
        end
      end.new
      handler(admin_notifier: unreachable).call("a slur in general", "loud")

      expect(models.alert.first.delivered_to).to eq(0)
    end
  end

  describe "a mode nobody knows" do
    it "is refused rather than quietly treated as quiet" do
      answer = handler.call("something", "urgent")

      expect(answer).to be_a(Rubotty::Scripting::Answer)
      expect(answer.to_a.first).to be(false)
      expect(answer.to_a.last).to include("quiet").and include("loud")
    end

    it "records nothing and tells nobody" do
      handler.call("something", "urgent")

      expect(models.alert.count).to eq(0)
      expect(audit.rows).to be_empty
      expect(notifier.calls).to be_empty
    end
  end

  # A script runs while a message is held up on the relay's path, so nothing
  # here may be able to stop that message being bridged.
  describe "when the alert cannot be raised at all" do
    it "survives a store that will not write" do
      broken = Class.new do
        def record(**) = raise(Sequel::DatabaseError, "no disk")

        def delivered(*) = nil
      end.new

      expect { handler(alerts_service: broken).call("something") }.not_to raise_error
    end

    it "survives an audit log that will not write" do
      allow(audit).to receive(:record).and_raise(Rubotty::StorageError, "no disk")

      expect(handler.call("something")).to be(true)
      expect(models.alert.count).to eq(1)
    end

    # A deployment with no alerts store still records the audit row it always did.
    it "still answers true with no alerts store behind it" do
      expect(handler(alerts_service: nil).call("something")).to be(true)
      expect(audit.rows.length).to eq(1)
    end

    it "is not offered at all with no audit log behind it" do
      built = described_class.allocate.send(:script_alert_handler, context, audit: nil)

      expect(built).to be_nil
    end
  end
end
