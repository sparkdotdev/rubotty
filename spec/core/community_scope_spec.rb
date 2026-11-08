# frozen_string_literal: true

require "spec_helper"

# The tenancy guard itself. Issue #1767: an event created in SECOND's "general"
# room was announced into SAMPLE's, because a resolution keyed on something other
# than a community picked the first candidate it found across all of them.
RSpec.describe Rubotty::Core::CommunityScope do
  let(:alpha) { endpoint("alpha-tg", community_id: 1) }
  let(:beta) { endpoint("beta-tg", community_id: 2) }
  let(:unowned) { endpoint("config-tg") }

  describe ".permits?" do
    it "permits an endpoint acted on for its own community" do
      expect(described_class.permits?(alpha, 1)).to be(true)
    end

    it "refuses an endpoint belonging to another community" do
      expect(described_class.permits?(alpha, 2)).to be(false)
    end

    it "refuses a missing endpoint rather than treating nil as unscoped" do
      expect(described_class.permits?(nil, 1)).to be(false)
    end

    # The config-file path has one community and no ids at all, and must not
    # start refusing its own deliveries.
    it "permits an endpoint with no community of its own" do
      expect(described_class.permits?(unowned, 1)).to be(true)
    end
  end

  describe ".assert!" do
    it "returns the endpoint when it belongs to the community" do
      expect(described_class.assert!(alpha, 1)).to be(alpha)
    end

    it "raises rather than letting the caller proceed into another tenant" do
      expect { described_class.assert!(alpha, 2, doing: "posting a card") }
        .to raise_error(described_class::Violation, /posting a card.*alpha-tg.*community 1.*not 2/)
    end

    it "carries both community ids on the error, so a log names the crossing" do
      described_class.assert!(beta, 1)
    rescue described_class::Violation => e
      expect([e.endpoint_id, e.actual_community_id, e.expected_community_id]).to eq(["beta-tg", 2, 1])
    end
  end

  describe ".within" do
    let(:mixed) { [alpha, beta, unowned] }

    it "keeps only the named community's endpoints" do
      expect(described_class.within(mixed, 1)).to eq([alpha])
    end

    # The whole point: choosing a candidate must never reach past the tenant,
    # so an endpoint whose community is unknown is not a fallback.
    it "does not offer an unowned endpoint as a candidate for a real community" do
      expect(described_class.within(mixed, 2)).to eq([beta])
    end

    it "matches the unowned endpoints for the config path, which has no ids" do
      expect(described_class.within(mixed, nil)).to eq([unowned])
    end
  end

  describe ".permit_or_log" do
    let(:logs) { StringIO.new }
    let(:logger) { Rubotty::Log.build(level: "info", io: logs) }

    it "permits and says nothing for an endpoint in the right community" do
      expect(described_class.permit_or_log(alpha, 1, logger: logger)).to be(true)
      expect(logs.string).to be_empty
    end

    it "refuses loudly rather than raising, so one bad endpoint keeps the fan-out" do
      expect(described_class.permit_or_log(alpha, 2, logger: logger, doing: "announcing")).to be(false)
      expect(logs.string).to match(/ERROR.*announcing REFUSED.*alpha-tg.*community 1.*not 2/)
    end
  end
end
