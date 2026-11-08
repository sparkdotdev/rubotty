# frozen_string_literal: true

require "spec_helper"

# The store behind the dashboard's Alerts page and behind rubotty.alert's two
# modes.
RSpec.describe Rubotty::ControlPlane::Alerts, :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:community) { models.community.first }
  let(:other) do
    models.community.create(slug: "other", name: "Other", status: "active", settings: "{}",
                            created_at: Time.now, updated_at: Time.now)
  end
  let(:alerts) { described_class.new(models: models, logger: Rubotty::Log.null) }

  describe "recording" do
    it "defaults to quiet, so a script written before loud existed is unchanged" do
      row = alerts.record(community_id: community.id, text: "somebody is upset in general")

      expect(row.mode).to eq(described_class::QUIET)
      expect(row.delivered_to).to eq(0)
      expect(row.seen_at).to be_nil
    end

    it "records a loud alert with the same row a quiet one gets" do
      row = alerts.record(community_id: community.id, text: "a slur in general", mode: described_class::LOUD)

      expect(row.mode).to eq(described_class::LOUD)
      expect(row.text).to eq("a slur in general")
    end

    it "keeps the room and the script that raised it, so the page can say where to look" do
      row = alerts.record(community_id: community.id, text: "hello", room_key: "general", script: "slur_alert")

      expect(row.room_key).to eq("general")
      expect(row.script).to eq("slur_alert")
    end

    it "cuts the text to the length the column holds rather than refusing it" do
      row = alerts.record(community_id: community.id, text: "x" * 900)

      expect(row.text.length).to eq(described_class::MAX_TEXT)
    end

    it "records nothing for text that is only whitespace" do
      expect(alerts.record(community_id: community.id, text: "   ")).to be_nil
      expect(models.alert.count).to eq(0)
    end

    # A script raising an alert runs while a message is held up, so a broken
    # table must not become a broken bridge.
    it "answers nil rather than raising when the write fails" do
      allow(models.alert).to receive(:create).and_raise(Sequel::DatabaseError, "no disk")

      expect { alerts.record(community_id: community.id, text: "hello") }.not_to raise_error
      expect(alerts.record(community_id: community.id, text: "hello")).to be_nil
    end

    it "notes how many operators a loud alert's DM reached" do
      row = alerts.record(community_id: community.id, text: "a slur", mode: described_class::LOUD)
      alerts.delivered(row, 2)

      expect(models.alert[row.id].delivered_to).to eq(2)
    end
  end

  describe "reading" do
    it "answers newest first" do
      alerts.record(community_id: community.id, text: "first")
      alerts.record(community_id: community.id, text: "second")

      expect(alerts.recent(community_id: community.id).map(&:text)).to eq(%w[second first])
    end

    it "never answers with another community's alerts" do
      alerts.record(community_id: other.id, text: "somebody else's problem")
      alerts.record(community_id: community.id, text: "ours")

      expect(alerts.recent(community_id: community.id).map(&:text)).to eq(["ours"])
    end

    # The cutoff is in the query, so this holds on a deployment whose sweep has
    # never run.
    it "leaves out anything past the retention even before a sweep" do
      old = Time.now - described_class::RETENTION - 60
      models.alert.create(community_id: community.id, text: "ancient", mode: described_class::QUIET,
                          room_key: "", script: "", delivered_to: 0, created_at: old)
      alerts.record(community_id: community.id, text: "current")

      expect(alerts.recent(community_id: community.id).map(&:text)).to eq(["current"])
    end

    # What one script's own page is drawn from. The match is on the name each
    # alert was written with, since that is all the row carries.
    describe "one script's alerts" do
      it "answers that script's alerts, newest first, and nobody else's" do
        alerts.record(community_id: community.id, text: "first", script: "guard")
        alerts.record(community_id: community.id, text: "second", script: "guard")
        alerts.record(community_id: community.id, text: "theirs", script: "welcome")

        expect(alerts.for_script(community_id: community.id, script: "guard").map(&:text))
          .to eq(%w[second first])
      end

      it "never answers with another community's alerts from a script of the same name" do
        alerts.record(community_id: other.id, text: "theirs", script: "guard")
        alerts.record(community_id: community.id, text: "ours", script: "guard")

        expect(alerts.for_script(community_id: community.id, script: "guard").map(&:text)).to eq(["ours"])
      end

      it "leaves out anything past the retention even before a sweep" do
        old = Time.now - described_class::RETENTION - 60
        models.alert.create(community_id: community.id, text: "ancient", mode: described_class::QUIET,
                            room_key: "", script: "guard", delivered_to: 0, created_at: old)
        alerts.record(community_id: community.id, text: "current", script: "guard")

        expect(alerts.for_script(community_id: community.id, script: "guard").map(&:text)).to eq(["current"])
      end

      # The column defaults to empty, so a blank name would otherwise answer
      # with every alert nothing named a script for.
      it "answers nothing at all for a blank name" do
        alerts.record(community_id: community.id, text: "raised by nothing in particular")

        expect(alerts.for_script(community_id: community.id, script: "")).to eq([])
        expect(alerts.for_script(community_id: community.id, script: nil)).to eq([])
      end
    end

    it "counts only this community's unseen alerts" do
      alerts.record(community_id: other.id, text: "theirs")
      alerts.record(community_id: community.id, text: "ours")

      expect(alerts.unseen_count(community_id: community.id)).to eq(1)
    end
  end

  describe "marking seen" do
    it "marks one" do
      row = alerts.record(community_id: community.id, text: "hello")

      expect(alerts.mark_seen(id: row.id, community_id: community.id)).to be(true)
      expect(models.alert[row.id].seen_at).not_to be_nil
    end

    # Scoped in the WHERE clause, so an id from another community matches
    # nothing at all.
    it "never marks an alert belonging to another community" do
      row = alerts.record(community_id: other.id, text: "theirs")

      expect(alerts.mark_seen(id: row.id, community_id: community.id)).to be(false)
      expect(models.alert[row.id].seen_at).to be_nil
    end

    it "answers false for one that was already seen" do
      row = alerts.record(community_id: community.id, text: "hello")
      alerts.mark_seen(id: row.id, community_id: community.id)

      expect(alerts.mark_seen(id: row.id, community_id: community.id)).to be(false)
    end

    it "marks everything this community has outstanding, and nothing else" do
      alerts.record(community_id: other.id, text: "theirs")
      2.times { |i| alerts.record(community_id: community.id, text: "ours #{i}") }

      expect(alerts.mark_all_seen(community_id: community.id)).to eq(2)
      expect(alerts.unseen_count(community_id: community.id)).to eq(0)
      expect(alerts.unseen_count(community_id: other.id)).to eq(1)
    end
  end

  describe "the bounds that keep this small" do
    it "evicts a community's oldest once it is over the cap" do
      stub_const("#{described_class}::COMMUNITY_LIMIT", 3)
      4.times { |i| alerts.record(community_id: community.id, text: "alert #{i}") }

      expect(models.alert.where(community_id: community.id).count).to eq(3)
      expect(alerts.recent(community_id: community.id).map(&:text)).to eq(["alert 3", "alert 2", "alert 1"])
    end

    it "evicts only the community that is over the cap" do
      stub_const("#{described_class}::COMMUNITY_LIMIT", 2)
      alerts.record(community_id: other.id, text: "theirs")
      3.times { |i| alerts.record(community_id: community.id, text: "ours #{i}") }

      expect(models.alert.where(community_id: other.id).count).to eq(1)
    end

    it "deletes what is past the retention when swept directly" do
      age_one_out

      expect(alerts.prune).to eq(1)
      expect(models.alert.count).to eq(0)
    end

    # The sweep runs from the write path too, so nothing has to remember prune.
    it "sweeps the retention while writing, so nothing waits on a caller" do
      age_one_out
      alerts.record(community_id: community.id, text: "current")

      expect(models.alert.map(&:text)).to eq(["current"])
    end

    def age_one_out
      models.alert.create(community_id: community.id, text: "ancient", mode: described_class::QUIET,
                          room_key: "", script: "", delivered_to: 0,
                          created_at: Time.now - described_class::RETENTION - 60)
    end
  end
end
