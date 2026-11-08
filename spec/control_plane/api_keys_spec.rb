# frozen_string_literal: true

require "spec_helper"

# The invariants the auth system leans on: the token is stored hashed, a
# revoked key stops authenticating, and the scope always agrees with
# community_id.
RSpec.describe Rubotty::ControlPlane::ApiKeys, :control_plane do
  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }

  let(:now) { Time.at(Time.new(2026, 7, 24, 12, 0, 0).to_i) }
  let(:clock) { -> { @now } }
  before { @now = now }

  subject(:keys) { described_class.new(models: models, clock: clock) }

  def other_community
    models.community.create(
      slug: "other", name: "Other", status: "active", settings: "{}",
      created_at: now, updated_at: now
    )
  end

  describe "#issue" do
    it "returns the raw token once but stores only its digest" do
      issued = keys.issue(scope: "developer", community: community, label: "Discord relay bot")
      expect(issued.token).to be_a(String)
      expect(issued.token.length).to be >= 40
      expect(issued.key_row.key_hash).to eq(Digest::SHA256.hexdigest(issued.token))
      expect(issued.key_row.key_hash).not_to eq(issued.token)
    end

    it "mints a public_id distinct from the token and its hash" do
      issued = keys.issue(scope: "administrator", label: "CI bot")
      expect(issued.key_row.public_id).to be_a(String)
      expect(issued.key_row.public_id).not_to eq(issued.token)
      expect(issued.key_row.public_id).not_to eq(issued.key_row.key_hash)
    end

    it "scopes a developer key to the given community" do
      issued = keys.issue(scope: "developer", community: community, label: "Discord relay bot")
      expect(issued.key_row.scope).to eq("developer")
      expect(issued.key_row.community_id).to eq(community.id)
    end

    it "leaves an administrator key with no community" do
      issued = keys.issue(scope: "administrator", label: "CI bot")
      expect(issued.key_row.scope).to eq("administrator")
      expect(issued.key_row.community_id).to be_nil
    end

    it "records who issued it and stamps created_at from the clock" do
      issued = keys.issue(scope: "administrator", label: "CI bot", created_by: "dashboard")
      expect(issued.key_row.created_by).to eq("dashboard")
      expect(issued.key_row.created_at.to_i).to eq(now.to_i)
    end

    it "rejects an unknown scope" do
      expect { keys.issue(scope: "superuser", label: "X") }
        .to raise_error(described_class::Invalid, /scope/)
    end

    it "rejects an administrator key scoped to a community" do
      expect { keys.issue(scope: "administrator", community: community, label: "X") }
        .to raise_error(described_class::Invalid, /administrator key cannot be scoped/)
    end

    it "rejects a developer key with no community" do
      expect { keys.issue(scope: "developer", label: "X") }
        .to raise_error(described_class::Invalid, /developer key needs a community/)
    end

    it "rejects a blank label" do
      expect { keys.issue(scope: "administrator", label: "  ") }
        .to raise_error(described_class::Invalid, /label/)
    end

    it "scopes a developer key to one platform_account, for a bridge integration key" do
      issued = keys.issue(scope: "developer", community: community, label: "acme bridge",
                          platform_account: "acme-bridge")
      expect(issued.key_row.platform_account).to eq("acme-bridge")
    end

    it "leaves platform_account nil on an ordinary key" do
      issued = keys.issue(scope: "developer", community: community, label: "ordinary")
      expect(issued.key_row.platform_account).to be_nil
    end

    it "rejects an administrator key scoped to a platform_account, since it has no single community to scope it in" do
      expect { keys.issue(scope: "administrator", label: "X", platform_account: "acme-bridge") }
        .to raise_error(described_class::Invalid, /platform-account key must be scoped to a community/)
    end
  end

  describe "#authenticate" do
    it "returns the live key row for the correct token" do
      issued = keys.issue(scope: "administrator", label: "CI bot")
      expect(keys.authenticate(token: issued.token)&.id).to eq(issued.key_row.id)
    end

    it "returns nil for an unknown token" do
      keys.issue(scope: "administrator", label: "CI bot")
      expect(keys.authenticate(token: "not-a-real-token")).to be_nil
    end

    it "returns nil for a blank token without touching the database" do
      expect(keys.authenticate(token: "")).to be_nil
      expect(keys.authenticate(token: nil)).to be_nil
    end

    it "rejects the token once the key is revoked" do
      issued = keys.issue(scope: "administrator", label: "CI bot")
      keys.revoke_by_public_id(public_id: issued.key_row.public_id)
      expect(keys.authenticate(token: issued.token)).to be_nil
    end
  end

  describe "#list" do
    it "lists every key when no community is given" do
      keys.issue(scope: "developer", community: community, label: "Dev key")
      keys.issue(scope: "administrator", label: "Admin key")
      expect(keys.list.size).to eq(2)
    end

    it "scopes the listing to one community when given" do
      keys.issue(scope: "developer", community: community, label: "Dev key")
      keys.issue(scope: "administrator", label: "Admin key")
      rows = keys.list(community: community)
      expect(rows.size).to eq(1)
      expect(rows.first.label).to eq("Dev key")
    end

    it "orders newest first" do
      first = keys.issue(scope: "administrator", label: "First")
      second = keys.issue(scope: "administrator", label: "Second")
      expect(keys.list.map(&:id)).to eq([second.key_row.id, first.key_row.id])
    end
  end

  describe "#revoke_by_public_id" do
    it "revokes a live key" do
      issued = keys.issue(scope: "administrator", label: "CI bot")
      keys.revoke_by_public_id(public_id: issued.key_row.public_id)
      expect(issued.key_row.refresh.revoked_at).not_to be_nil
    end

    it "is idempotent and preserves the first revocation time" do
      issued = keys.issue(scope: "administrator", label: "CI bot")
      keys.revoke_by_public_id(public_id: issued.key_row.public_id)
      first = issued.key_row.refresh.revoked_at
      @now = now + 100
      keys.revoke_by_public_id(public_id: issued.key_row.public_id)
      expect(issued.key_row.refresh.revoked_at.to_i).to eq(first.to_i)
    end

    it "returns nil for an unknown public_id" do
      expect(keys.revoke_by_public_id(public_id: "no-such-id")).to be_nil
    end
  end

  describe "#touch_last_used" do
    it "stamps last_used_at from the clock" do
      issued = keys.issue(scope: "administrator", label: "CI bot")
      expect(issued.key_row.last_used_at).to be_nil
      @now = now + 60
      keys.touch_last_used(issued.key_row)
      expect(issued.key_row.refresh.last_used_at.to_i).to eq((now + 60).to_i)
    end
  end

  describe ".hash_token" do
    it "is the SHA-256 hex digest of the token" do
      expect(described_class.hash_token("abc")).to eq(Digest::SHA256.hexdigest("abc"))
    end

    it "is nil for a blank token" do
      expect(described_class.hash_token("")).to be_nil
      expect(described_class.hash_token(nil)).to be_nil
    end
  end
end
