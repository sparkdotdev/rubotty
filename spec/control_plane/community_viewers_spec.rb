# frozen_string_literal: true

require "spec_helper"

# Who reads ONE community and changes nothing in it: the shipped YAML floor
# unioned with the rows granted against a single community.
RSpec.describe Rubotty::ControlPlane::CommunityViewers, :control_plane do
  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }
  let(:other) do
    id = Rubotty::ControlPlane::Seed.from_model(sample_model, models: models, slug: "other-co")
    models.community[id]
  end
  let(:audit) { Rubotty::Core::AuditLog::Sequel.new(db: db, logger: Rubotty::Log.null) }

  subject(:viewers) do
    described_class.new(models: models, audit: audit, logger: Rubotty::Log.null)
  end

  def with_floor(*handles)
    described_class.new(
      models: models, audit: audit, logger: Rubotty::Log.null,
      floor: Rubotty::Security::DashboardViewers.new(usernames: handles)
    )
  end

  def trail(row = community)
    audit.query(community: row.slug, source: described_class::AUDIT_SOURCE).map(&:action)
  end

  # A handle grant resolves an already-known account once; authentication
  # later carries that account's native id.
  before do
    Rubotty::ControlPlane::IdentityDirectory.new(models: models).record(
      community_id: community.id, adapter: "telegram", native_id: "9001", username: "ada"
    )
  end

  describe "#grant" do
    it "lets a handle read the community it was granted in" do
      viewers.grant(community_id: community.id, adapter: "telegram", handle: "@Ada", granted_by: "boss")

      expect(viewers.viewer?(community_id: community.id, adapter: "telegram", native_id: "9001", username: "ada")).to be(true)
    end

    # The whole point of the scope: reading one community says nothing about
    # any other.
    it "does not let that handle read another community" do
      viewers.grant(community_id: community.id, adapter: "telegram", handle: "ada", granted_by: "boss")

      expect(viewers.viewer?(community_id: other.id, adapter: "telegram", native_id: "9001", username: "ada")).to be(false)
    end

    it "is idempotent, writing one row and auditing once" do
      first = viewers.grant(community_id: community.id, adapter: "telegram", handle: "ada", granted_by: "boss")
      again = viewers.grant(community_id: community.id, adapter: "telegram", handle: "ada", granted_by: "boss")

      expect(again[:id]).to eq(first[:id])
      expect(db[:community_viewers].where(community_id: community.id).count).to eq(1)
      expect(trail.count("community_viewer_granted")).to eq(1)
    end

    it "matches the stable handle, never the display name" do
      viewers.grant(community_id: community.id, adapter: "telegram", handle: "ada",
                    label: "Ada Lovelace", granted_by: "boss")

      expect(viewers.viewer?(community_id: community.id, adapter: "telegram",
                             username: "Ada Lovelace")).to be(false)
    end

    it "matches the full id on a federated platform, from either field" do
      viewers.grant(community_id: community.id, adapter: "matrix",
                    handle: "@ada:example.org", granted_by: "boss")

      expect(viewers.viewer?(community_id: community.id, adapter: "matrix",
                             native_id: "@ada:example.org")).to be(true)
      expect(viewers.viewer?(community_id: community.id, adapter: "matrix", username: "ada")).to be(false)
    end

    it "refuses a platform nothing would ever match on" do
      expect do
        viewers.grant(community_id: community.id, adapter: "carrier-pigeon", handle: "ada", granted_by: "boss")
      end.to raise_error(described_class::Invalid, /platforms a viewer can be named on/)
    end

    it "refuses a grant that says nobody made it" do
      expect do
        viewers.grant(community_id: community.id, adapter: "telegram", handle: "ada", granted_by: " ")
      end.to raise_error(described_class::Invalid, /has to say who made it/)
    end

    it "records who handed it over" do
      viewers.grant(community_id: community.id, adapter: "telegram", handle: "ada", granted_by: "boss")

      expect(trail).to include("community_viewer_granted")
    end
  end

  describe "Result#ok?" do
    it "does not treat :granted as success, since grant never produces it" do
      expect(described_class::Result.new(status: :granted).ok?).to be(false)
    end

    it "treats every status grant/revoke/approve/deny actually produce as success" do
      expect(described_class::Result.new(status: :created).ok?).to be(true)
      expect(described_class::Result.new(status: :approved).ok?).to be(true)
      expect(described_class::Result.new(status: :denied).ok?).to be(true)
      expect(described_class::Result.new(status: :removed).ok?).to be(true)
    end
  end

  # The shipped YAML reads every community, so it is the floor under this one
  # too, and it cannot be revoked from here any more than from the Viewers page.
  describe "the shipped floor" do
    subject(:viewers) { with_floor("shipped") }

    it "reads the community with no row at all" do
      expect(viewers.viewer?(community_id: community.id, adapter: "telegram",
                             username: "shipped")).to be(true)
      expect(viewers.granted(community_id: community.id)).to be_empty
    end

    it "refuses a grant that would look revocable and would not be" do
      expect do
        viewers.grant(community_id: community.id, adapter: "telegram", handle: "shipped", granted_by: "boss")
      end.to raise_error(described_class::Invalid, /shipped list/)
    end

    it "cannot be revoked even when a row sits over it" do
      id = db[:community_viewers].insert(community_id: community.id, adapter: "telegram",
                                         handle: "shipped", granted_at: Time.now, granted_by: "seeded")

      result = viewers.revoke(community_id: community.id, id: id, revoked_by: "boss")

      expect(result).to be_protected
      expect(db[:community_viewers].where(id: id).count).to eq(1)
      expect(viewers.viewer?(community_id: community.id, adapter: "telegram",
                             username: "shipped")).to be(true)
    end
  end

  describe "#revoke" do
    it "takes a granted row back and records it" do
      row = viewers.grant(community_id: community.id, adapter: "telegram", handle: "ada", granted_by: "boss")

      result = viewers.revoke(community_id: community.id, id: row[:id], revoked_by: "boss")

      expect(result).to be_removed
      expect(viewers.viewer?(community_id: community.id, adapter: "telegram", native_id: "9001", username: "ada")).to be(false)
      expect(trail).to include("community_viewer_revoked")
    end

    # Scoped, so an id from another community is simply not there.
    it "does not reach a row in another community" do
      row = viewers.grant(community_id: community.id, adapter: "telegram", handle: "ada", granted_by: "boss")

      result = viewers.revoke(community_id: other.id, id: row[:id], revoked_by: "boss")

      expect(result.status).to eq(:not_found)
      expect(viewers.viewer?(community_id: community.id, adapter: "telegram", native_id: "9001", username: "ada")).to be(true)
    end
  end

  describe "#communities_for" do
    it "answers every community a handle reads by grant, and no other" do
      viewers.grant(community_id: community.id, adapter: "telegram", handle: "ada", granted_by: "boss")

      expect(viewers.communities_for(adapter: "telegram", native_id: "9001", username: "ada")).to eq([community.id])
      expect(viewers.communities_for(adapter: "telegram", username: "nobody")).to be_empty
    end
  end

  describe "a request" do
    it "records one and audits it" do
      result = viewers.request(community_id: community.id, adapter: "telegram",
                               native_id: "9001", username: "ada", display: "Ada")

      expect(result).to be_created
      expect(viewers.pending(community_id: community.id).size).to eq(1)
      expect(trail).to include("community_viewer_requested")
    end

    it "comes back as itself rather than as a second row" do
      viewers.request(community_id: community.id, adapter: "telegram", native_id: "9001", username: "ada")
      again = viewers.request(community_id: community.id, adapter: "telegram", native_id: "9001", username: "ada")

      expect(again).to be_duplicate
      expect(viewers.pending(community_id: community.id).size).to eq(1)
    end

    it "is not filed at all by somebody who already reads the community" do
      viewers.grant(community_id: community.id, adapter: "telegram", handle: "ada", granted_by: "boss")

      result = viewers.request(community_id: community.id, adapter: "telegram",
                               native_id: "9001", username: "ada")

      expect(result.status).to eq(:already_viewer)
      expect(viewers.pending(community_id: community.id)).to be_empty
    end

    it "is granted on approval" do
      filed = viewers.request(community_id: community.id, adapter: "telegram",
                              native_id: "9001", username: "ada").request

      result = viewers.approve(request: filed, decided_by: "operator:1")

      expect(result).to be_approved
      expect(viewers.viewer?(community_id: community.id, adapter: "telegram", native_id: "9001", username: "ada")).to be(true)
      expect(viewers.find_request(community_id: community.id, id: filed[:id])[:state]).to eq("approved")
    end

    it "grants nothing on denial, and records the refusal" do
      filed = viewers.request(community_id: community.id, adapter: "telegram",
                              native_id: "9001", username: "ada").request

      result = viewers.deny(request: filed, decided_by: "operator:1")

      expect(result).to be_denied
      expect(viewers.viewer?(community_id: community.id, adapter: "telegram", native_id: "9001", username: "ada")).to be(false)
      expect(trail).to include("community_viewer_request_denied")
    end

    it "refuses a decision that names nobody as having taken it" do
      filed = viewers.request(community_id: community.id, adapter: "telegram",
                              native_id: "9001", username: "ada").request

      expect(viewers.approve(request: filed, decided_by: nil)).to be_forbidden
      expect(viewers.deny(request: filed, decided_by: " ")).to be_forbidden
    end

    it "is not decided twice" do
      filed = viewers.request(community_id: community.id, adapter: "telegram",
                              native_id: "9001", username: "ada").request
      viewers.deny(request: filed, decided_by: "operator:1")

      again = viewers.deny(request: viewers.find_request(community_id: community.id, id: filed[:id]),
                           decided_by: "operator:1")

      expect(again.status).to eq(:not_pending)
    end

    it "is only found inside the community it was filed in" do
      filed = viewers.request(community_id: community.id, adapter: "telegram",
                              native_id: "9001", username: "ada").request

      expect(viewers.find_request(community_id: other.id, id: filed[:id])).to be_nil
      expect(viewers.pending(community_id: other.id)).to be_empty
    end
  end

  # A process whose code arrives before the migration reads nothing rather than
  # failing to build its control plane at all.
  describe "before the tables arrive" do
    before do
      db.drop_table?(:community_viewer_requests)
      db.drop_table?(:community_viewers)
    end

    it "reads an empty list and still answers the floor" do
      floored = with_floor("shipped")

      expect(floored.granted(community_id: community.id)).to be_empty
      expect(floored.pending(community_id: community.id)).to be_empty
      expect(floored.viewer?(community_id: community.id, adapter: "telegram", native_id: "9001", username: "ada")).to be(false)
      expect(floored.viewer?(community_id: community.id, adapter: "telegram", username: "shipped")).to be(true)
    end

    it "refuses a grant honestly rather than raising something a route cannot read" do
      expect do
        viewers.grant(community_id: community.id, adapter: "telegram", handle: "ada", granted_by: "boss")
      end.to raise_error(described_class::Invalid, /not available on this deployment yet/)
    end

    it "answers a request with an honest refusal" do
      result = viewers.request(community_id: community.id, adapter: "telegram",
                               native_id: "9001", username: "ada")

      expect(result.status).to eq(:invalid)
    end
  end
end
