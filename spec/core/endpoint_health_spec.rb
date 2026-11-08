# frozen_string_literal: true

require "spec_helper"

# The outbound half of what the bot reports about itself. A Fluxer outage
# took every room bridging it to a crawl for hours while the process still
# answered healthy: true, because nothing counted a failed delivery.
# RelayOutcomes says itself that it only watches what a sweep asked it to.
RSpec.describe Rubotty::Core::EndpointHealth do
  let(:now) { Time.utc(2026, 9, 14, 12, 0, 0) }

  subject(:health) { described_class.new(clock: -> { now }) }

  def row(id) = health.report.find { |entry| entry["endpoint_id"] == id }

  describe "the consecutive failure run" do
    # The number a circuit breaker wants: "this destination is not accepting
    # posts", as against "one send went wrong".
    it "counts a run of failures against one destination" do
      3.times { health.failed("fx", error: "timed out") }

      expect(health.failures("fx")).to eq(3)
    end

    it "is cleared by one receipt, which is what reachable again looks like" do
      3.times { health.failed("fx", error: "timed out") }

      health.delivered("fx", seconds: 0.2)

      expect(health.failures("fx")).to eq(0)
      expect(row("fx").values_at("sent", "failed")).to eq([1, 3])
    end

    it "answers zero for a destination it has never seen" do
      expect(health.failures("nobody")).to eq(0)
    end
  end

  describe "what a failure records" do
    # The class as well as the message, since a timeout and a refusal want
    # telling apart, and the exception itself is not held: that would pin its
    # backtrace here for as long as the entry lived.
    it "keeps the error's class and message, not the exception" do
      health.failed("fx", error: Errno::ETIMEDOUT.new("connect(2) timed out"))

      expect(row("fx")["last_error"]).to include("Errno::ETIMEDOUT", "connect(2) timed out")
    end

    it "takes a plain string reason as given" do
      health.failed("fx", error: "the bridge refused it")

      expect(row("fx")["last_error"]).to eq("the bridge refused it")
    end

    it "leaves the error out rather than writing a null when there was none to name" do
      health.failed("fx")

      expect(row("fx")).not_to have_key("last_error")
    end

    it "stamps when it last succeeded and last failed, separately" do
      health.delivered("fx", seconds: 0.1)
      health.failed("fx", error: "gone")

      expect(row("fx")["last_sent_at"]).to eq("2026-09-14T12:00:00Z")
      expect(row("fx")["last_failed_at"]).to eq("2026-09-14T12:00:00Z")
    end
  end

  describe "latency" do
    it "buckets by the same edges the model call stats read, and names them" do
      health.delivered("fx", seconds: 0.1)
      health.delivered("fx", seconds: 3.0)

      expect(row("fx")["latency"].map { |entry| entry["label"] }).to eq(["under 0.25s", "2s to 4s"])
    end

    it "collects everything past the top edge in one bucket, which is where a dying endpoint lands" do
      health.failed("fx", error: "timed out", seconds: 40.0)

      expect(row("fx")["latency"]).to eq([{ "label" => "over 15s", "count" => 1 }])
    end

    it "leaves latency out entirely when nothing was timed" do
      health.failed("fx", error: "never attempted")

      expect(row("fx")).not_to have_key("latency")
    end
  end

  describe "the report" do
    it "puts the longest failure run first, since that is the one worth looking at" do
      health.delivered("fine", seconds: 0.1)
      2.times { health.failed("bad", error: "x") }
      5.times { health.failed("worst", error: "x") }

      expect(health.report.map { |entry| entry["endpoint_id"] }).to eq(%w[worst bad fine])
    end

    it "is empty before anything has been delivered anywhere" do
      expect(health.report).to eq([])
    end

    it "ignores a blank endpoint id rather than opening a row for it" do
      health.delivered("", seconds: 1.0)

      expect(health.report).to eq([])
    end

    # A churn of one-off ids must not grow this without limit, so the coldest
    # entry is dropped once the bound is reached.
    it "holds no more than MAX_ENDPOINTS destinations" do
      (described_class::MAX_ENDPOINTS + 20).times { |index| health.delivered("e#{index}", seconds: 0.1) }

      expect(health.report.length).to eq(described_class::MAX_ENDPOINTS)
    end

    it "drops the coldest rather than the newest when it runs out of room" do
      (described_class::MAX_ENDPOINTS + 1).times { |index| health.delivered("e#{index}", seconds: 0.1) }
      ids = health.report.map { |entry| entry["endpoint_id"] }

      expect(ids).to include("e#{described_class::MAX_ENDPOINTS}")
      expect(ids).not_to include("e0")
    end
  end
end
