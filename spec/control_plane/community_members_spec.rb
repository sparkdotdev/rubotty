# frozen_string_literal: true

require "spec_helper"

# The mechanism behind RehostedFiles' serve ceiling: summing whatever live
# adapters can answer, or refusing to guess the moment one of them cannot.
RSpec.describe Rubotty::ControlPlane::CommunityMembers, :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }

  def counting_adapter(count)
    adapter = double("adapter")
    allow(adapter).to receive(:community_member_count).and_return(count)
    adapter
  end

  describe ".aggregate" do
    it "sums every connection's live count" do
      adapters = { [:telegram, "telegram"] => counting_adapter(40), [:discord, "discord"] => counting_adapter(9) }

      expect(described_class.aggregate(community_id: community.id, models: models, adapters: adapters)).to eq(49)
    end

    it "counts a member on two platforms twice, since nothing here deduplicates" do
      adapters = { [:telegram, "telegram"] => counting_adapter(5), [:discord, "discord"] => counting_adapter(5) }

      expect(described_class.aggregate(community_id: community.id, models: models, adapters: adapters)).to eq(10)
    end

    it "answers nil the moment one connection cannot be counted, never folding it in as zero" do
      adapters = { [:telegram, "telegram"] => counting_adapter(40), [:discord, "discord"] => counting_adapter(nil) }

      expect(described_class.aggregate(community_id: community.id, models: models, adapters: adapters)).to be_nil
    end

    it "answers nil when a connection's adapter is not running at all" do
      adapters = { [:telegram, "telegram"] => counting_adapter(40) }

      expect(described_class.aggregate(community_id: community.id, models: models, adapters: adapters)).to be_nil
    end

    it "answers nil when an adapter does not expose a count at all" do
      mute = double("adapter with no count method")
      adapters = { [:telegram, "telegram"] => counting_adapter(40), [:discord, "discord"] => mute }

      expect(described_class.aggregate(community_id: community.id, models: models, adapters: adapters)).to be_nil
    end

    it "answers nil for a community with no platform connections at all" do
      empty = models.community.create(slug: "empty-co", name: "Empty Co", status: "active", settings: "{}",
                                      created_at: Time.now, updated_at: Time.now)

      expect(described_class.aggregate(community_id: empty.id, models: models, adapters: {})).to be_nil
    end

    it "treats a non-integer or negative answer as uncountable" do
      adapters = { [:telegram, "telegram"] => counting_adapter("lots"),
                   [:discord, "discord"] => counting_adapter(9) }
      expect(described_class.aggregate(community_id: community.id, models: models, adapters: adapters)).to be_nil

      negative = { [:telegram, "telegram"] => counting_adapter(-1), [:discord, "discord"] => counting_adapter(9) }
      expect(described_class.aggregate(community_id: community.id, models: models, adapters: negative)).to be_nil
    end

    it "answers nil rather than raise when an adapter's count blows up" do
      broken = double("broken adapter")
      allow(broken).to receive(:community_member_count).and_raise(StandardError, "gateway down")
      adapters = { [:telegram, "telegram"] => counting_adapter(40), [:discord, "discord"] => broken }

      expect(described_class.aggregate(community_id: community.id, models: models, adapters: adapters)).to be_nil
    end
  end
end
