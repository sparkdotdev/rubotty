# frozen_string_literal: true

require "spec_helper"

# The one acknowledgement template every deferred command shares; the module owns
# only the wording, and the ephemeral primitive does the editing and deleting.
RSpec.describe Rubotty::Core::CommandAck do
  describe ".pending" do
    it "builds the fixed 'Acknowledged, <summary> in <t> seconds.' shape" do
      expect(described_class.pending("deleting this message on all services", 15))
        .to eq("Acknowledged, deleting this message on all services in 15 seconds.")
    end

    it "singularises the unit so a one-second grace never reads '1 seconds'" do
      expect(described_class.pending("finding that user", 1))
        .to eq("Acknowledged, finding that user in 1 second.")
    end

    it "coerces a numeric-ish delay to an integer count of seconds" do
      expect(described_class.pending("pinning this message", "30"))
        .to eq("Acknowledged, pinning this message in 30 seconds.")
    end

    it "trims stray whitespace from the summary so the sentence stays clean" do
      expect(described_class.pending("  kicking this user  ", 5))
        .to eq("Acknowledged, kicking this user in 5 seconds.")
    end
  end

  describe ".unit" do
    it "is 'second' only for a delay of exactly one" do
      expect(described_class.unit(1)).to eq("second")
      expect(described_class.unit(0)).to eq("seconds")
      expect(described_class.unit(2)).to eq("seconds")
    end
  end

  # Every command surface resolves the same per-scope field, so a community tunes
  # one number.
  describe ".ttl_seconds" do
    it "defaults to the standard 30s when the scope has not set a value" do
      expect(described_class::DEFAULT_TTL_SECONDS).to eq(30)
      expect(described_class.ttl_seconds({})).to eq(30)
    end

    it "reads the standardised field from the resolved feature config" do
      expect(described_class.ttl_seconds({ ack_ttl_seconds: 45 })).to eq(45)
    end

    it "tolerates a string key, since not every config hash is symbolised" do
      expect(described_class.ttl_seconds({ "ack_ttl_seconds" => 12 })).to eq(12)
    end

    it "coerces a stringy number the dashboard or YAML might store" do
      expect(described_class.ttl_seconds({ ack_ttl_seconds: "20" })).to eq(20)
    end

    it "honours a configured 0 as 'do not self-delete'" do
      expect(described_class.ttl_seconds({ ack_ttl_seconds: 0 })).to eq(0)
    end

    it "falls back to a caller-supplied default (a bridge-wide setting) when unset" do
      expect(described_class.ttl_seconds({}, default: 15)).to eq(15)
    end

    it "falls back on an unparseable or negative value rather than trusting it" do
      expect(described_class.ttl_seconds({ ack_ttl_seconds: "soon" }, default: 30)).to eq(30)
      expect(described_class.ttl_seconds({ ack_ttl_seconds: -5 }, default: 30)).to eq(30)
    end
  end

  describe ".pair_with" do
    let(:origin) { Rubotty::Core::Endpoint.new(id: "ep", adapter_name: :fake, account: "default", settings: {}) }
    let(:config) { { Rubotty::Core::CommandAck::DELETE_COMMAND_FIELD => true } }

    def real_message(**overrides)
      Rubotty::Core::Message.new(
        kind: :chat, ref: Rubotty::Core::MessageRef.new("ep", "42"), origin: origin, **overrides
      )
    end

    it "pairs a real message's own ref when the scope wants the pair to vanish together" do
      expect(described_class.pair_with(real_message, config).map(&:native_id)).to eq(["42"])
    end

    it "pairs nothing when the scope does not want the invocation deleted" do
      off = { Rubotty::Core::CommandAck::DELETE_COMMAND_FIELD => false }
      expect(described_class.pair_with(real_message, off)).to eq([])
    end

    # A slash-command interaction's ref names no posted Discord message, so
    # pairing it leaves the ephemeral reap retrying a delete that can never
    # succeed and never reads as "already gone".
    it "never pairs a synthetic message (a slash-command interaction), even when the scope wants pairing" do
      synthetic = real_message(synthetic: true)
      expect(described_class.pair_with(synthetic, config)).to eq([])
    end

    # MessageRef#initialize always stringifies native_id, so it can never
    # actually be nil; an empty string is the real shape a fake ref takes
    # (discord/inbound.rb's message_id_of returning nil for an event with no
    # id at all), and .reply_to already guards against it the same way.
    it "refuses to pair a ref with an empty native_id, not just a nil one" do
      empty_ref = Rubotty::Core::Message.new(
        kind: :chat, ref: Rubotty::Core::MessageRef.new("ep", nil), origin: origin
      )
      expect(described_class.pair_with(empty_ref, config)).to eq([])
    end
  end
end
