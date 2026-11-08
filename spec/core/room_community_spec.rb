# frozen_string_literal: true

require "spec_helper"

# Issue #1806, the room half of the tenancy work #1767 started on endpoints.
# A room key is unique inside one community and nowhere else, so a room that
# knows only its key leaves every scoping check parsing a string prefix.
RSpec.describe "a room knows which community owns it" do
  describe Rubotty::Core::Room do
    it "carries the community it was built for" do
      expect(described_class.owned_by(2, id: "general", endpoints: []).community_id).to eq(2)
    end

    it "derives a unique id from that community, so two tenants' general rooms differ" do
      alpha = described_class.owned_by(1, id: "general", endpoints: [])
      beta = described_class.owned_by(2, id: "general", endpoints: [])
      expect([alpha.unique_id, beta.unique_id]).to eq(["1:general", "2:general"])
    end

    it "still answers its bare key as the unique id on the config path, which has no communities" do
      plain = described_class.new(id: "general", endpoints: [])
      expect([plain.community_id, plain.unique_id]).to eq([nil, "general"])
    end

    it "keeps an explicitly given unique id rather than overwriting it" do
      room = described_class.new(id: "general", endpoints: [], unique_id: "legacy")
      expect(room.unique_id).to eq("legacy")
    end

    # The point of the constructor: a build site that forgets the community
    # fails here, instead of producing a room no scoping check can place.
    it "refuses to build without a community" do
      expect { described_class.owned_by(nil, id: "general", endpoints: []) }
        .to raise_error(ArgumentError, /needs its community/)
    end
  end

  describe Rubotty::Core::Endpoint do
    it "refuses to build without a community, the same bar the room holds" do
      expect { described_class.owned_by(nil, id: "tg", adapter_name: :fake, account: "a") }
        .to raise_error(ArgumentError, /needs its community/)
    end

    it "builds normally when given one" do
      expect(described_class.owned_by(3, id: "tg", adapter_name: :fake, account: "a").community_id).to eq(3)
    end
  end

  describe Rubotty::ControlPlane::SnapshotBuilder do
    let(:built) do
      _db, models, seeded = colliding_control_plane
      [described_class.build(models), seeded]
    end
    let(:snapshot) { built.first }
    let(:seeded) { built.last }

    it "tags every room it projects with the community that owns it" do
      owners = snapshot.communities.flat_map { |community| community.rooms.map(&:community_id) }
      expect(owners).to eq([seeded[:alpha][:community_id], seeded[:beta][:community_id]])
    end

    it "gives the two colliding general rooms distinct unique ids" do
      unique = snapshot.topology.rooms.map(&:unique_id)
      expect(unique).to eq(["#{seeded[:alpha][:community_id]}:general",
                            "#{seeded[:beta][:community_id]}:general"])
    end

    # The merged boot topology is one flat list, so this is the narrowing every
    # room lookup needs and could not previously do without parsing a key.
    it "lets CommunityScope narrow the merged topology to one tenant's rooms" do
      beta_id = seeded[:beta][:community_id]
      scoped = Rubotty::Core::CommunityScope.within(snapshot.topology.rooms, beta_id)
      expect(scoped.map(&:unique_id)).to eq(["#{beta_id}:general"])
    end

    it "does not offer the other tenant's identically keyed room" do
      alpha_id = seeded[:alpha][:community_id]
      scoped = Rubotty::Core::CommunityScope.within(snapshot.topology.rooms, alpha_id)
      expect(scoped.map(&:community_id)).to eq([alpha_id])
    end

    it "tags the synthetic API endpoint with the room's community too" do
      api = snapshot.communities.last.rooms.first.endpoints
                    .find { |endpoint| endpoint.adapter_name == Rubotty::Adapters::Api::NAME }
      expect(api.community_id).to eq(seeded[:beta][:community_id])
    end
  end
end
