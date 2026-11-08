# frozen_string_literal: true

require "spec_helper"
require "rubotty"

# The rollup behind the analytics page's model-backed panel. Everything here is
# a measurement: a spec that could store a prompt or an answer would be a
# retention promise broken, so the columns deliberately have nowhere to put one.
RSpec.describe Rubotty::ControlPlane::ModelCallStats, :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:community) { models.community.first }
  let(:other) { seeded_second_community }
  let(:now) { Time.now }

  subject(:stats) { described_class.new(models: models, logger: Rubotty::Log.null, clock: -> { now }) }

  # A second tenant in the same datastore, so every read can be shown not to
  # cross into it.
  def seeded_second_community
    models.community.create(slug: "other", name: "Other", status: "active",
                            created_at: now, updated_at: now)
  end

  def report_for(row = community) = stats.report(community: row)

  def feature_named(name, row = community)
    report_for(row).fetch(:features).find { |feature| feature[:key] == name }
  end

  describe "recording one call" do
    it "counts the attempt and files its wait in a bucket" do
      stats.record(community_id: community.id, feature: "content_policy", seconds: 1.4)

      content_policy = feature_named("content_policy")
      expect(content_policy[:calls]).to eq(1)
      expect(content_policy[:latency]).to eq([{ label: "1s to 2s", count: 1 }])
    end

    it "separates a failure from a success without losing the attempt" do
      stats.record(community_id: community.id, feature: "content_policy", seconds: 0.3)
      stats.record(community_id: community.id, feature: "content_policy", seconds: 0.4, failed: true)

      expect(feature_named("content_policy")).to include(calls: 2, failures: 1)
    end

    it "counts a second ask at the same question as a retry, since it spends the budget twice" do
      stats.record(community_id: community.id, feature: "topic_routing", seconds: 0.2, failed: true)
      stats.record(community_id: community.id, feature: "topic_routing", seconds: 0.2, retried: true)

      expect(feature_named("topic_routing")).to include(calls: 2, failures: 1, retries: 1)
    end

    it "counts an answer that stopped on the budget rather than on itself" do
      stats.record(community_id: community.id, feature: "room_summaries", seconds: 2.0,
                   budget_tokens: 240, used_tokens: 240, truncated: true)

      expect(feature_named("room_summaries")).to include(truncated: 1, budget_tokens: 240, used_tokens: 240)
    end

    it "keeps no tokens for a call that never answered, since none were generated" do
      stats.record(community_id: community.id, feature: "room_summaries", seconds: 9.0,
                   failed: true, budget_tokens: 240)

      expect(feature_named("room_summaries")).to include(budget_tokens: 0, used_tokens: 0)
    end

    it "drops a call attributed to a feature no page could name" do
      expect(stats.record(community_id: community.id, feature: "something_else", seconds: 1.0)).to be(false)
      expect(report_for.fetch(:features)).to be_empty
    end

    it "drops a call that cannot name its community, rather than filing it under none" do
      expect(stats.record(community_id: nil, feature: "content_policy", seconds: 1.0)).to be(false)
      expect(report_for.fetch(:features)).to be_empty
    end
  end

  describe "discarded jobs" do
    it "counts a job dropped past its own age limit, which nothing else leaves a trace of" do
      stats.discarded(community_id: community.id, feature: "content_policy")

      expect(feature_named("content_policy")).to include(discarded: 1, calls: 0)
    end
  end

  describe "unusable answers" do
    it "counts an answer that could not be read as a decision apart from calls and failures" do
      stats.record(community_id: community.id, feature: "topic_routing", seconds: 0.5)
      stats.unusable(community_id: community.id, feature: "topic_routing")

      expect(feature_named("topic_routing")).to include(calls: 1, failures: 0, unusable: 1)
    end
  end

  describe "reading it back" do
    it "answers only the community asked for" do
      stats.record(community_id: community.id, feature: "content_policy", seconds: 1.0)
      stats.record(community_id: other.id, feature: "content_policy", seconds: 1.0, failed: true)

      expect(feature_named("content_policy")).to include(calls: 1, failures: 0)
      expect(feature_named("content_policy", other)).to include(calls: 1, failures: 1)
    end

    it "totals the counters across features so the headline needs no second pass" do
      stats.record(community_id: community.id, feature: "content_policy", seconds: 1.0)
      stats.record(community_id: community.id, feature: "topic_routing", seconds: 1.0, failed: true)

      expect(report_for.fetch(:totals)).to include(calls: 2, failures: 1)
    end

    it "leaves out a window that predates everything recorded" do
      stats.record(community_id: community.id, feature: "content_policy", seconds: 1.0)

      expect(stats.report(community: community, since: now + (2 * 86_400)).fetch(:features)).to be_empty
    end

    it "reports an empty deployment as available with nothing in it, not as broken" do
      expect(report_for).to include(available: true, features: [])
    end
  end

  describe "percentiles" do
    it "lands on the bucket holding the sample, the tail included" do
      9.times { stats.record(community_id: community.id, feature: "content_policy", seconds: 0.2) }
      stats.record(community_id: community.id, feature: "content_policy", seconds: 45.0)

      expect(feature_named("content_policy")).to include(median: "0.25s", slowest: "1m")
    end

    it "says so when the slowest calls ran off the end of the histogram" do
      counts = { described_class::OVERFLOW => 5 }

      expect(described_class.percentile(counts, 0.95)).to eq("over 2m")
    end

    it "has no percentile at all when nothing was timed" do
      expect(described_class.percentile({}, 0.5)).to be_nil
    end
  end

  describe "coalescing" do
    it "loses no count when several threads record the same feature at once" do
      threads = 4.times.map do
        Thread.new { 25.times { stats.record(community_id: community.id, feature: "content_policy", seconds: 0.1) } }
      end
      threads.each(&:join)

      expect(feature_named("content_policy")[:calls]).to eq(100)
    end
  end

  describe "retention" do
    it "drops every row past the retention and keeps the rest" do
      stats.record(community_id: community.id, feature: "content_policy", seconds: 1.0)
      stats.flush
      models.model_call_stat.dataset.update(counted_on: (now.utc.to_date - 200))
      stats.record(community_id: community.id, feature: "topic_routing", seconds: 1.0)

      expect(stats.prune).to be_positive
      expect(report_for.fetch(:features).map { |feature| feature[:key] }).to eq(["topic_routing"])
    end
  end
end
