# frozen_string_literal: true

require "spec_helper"
require "sequel"

# The administrator roster: the shipped YAML as a floor, granted rows on top,
# and the union of the two as the answer. What matters here is that a row and
# a shipped entry resolve the same, that only one of them can be taken away,
# and that taking away the last row locks nobody out.
RSpec.describe Rubotty::ControlPlane::DashboardAdministrators, :control_plane do
  let(:db) { migrated_db }
  let(:models) { build_models(db) }
  let(:audit) { Rubotty::Core::AuditLog::Sequel.new(db: db) }

  # A floor naming one handle per matching rule, so "cannot be revoked" can be
  # asserted against both.
  let(:floor) do
    Rubotty::Security::DashboardAdministrators.new(usernames: %w[shipped],
                                                   matrix_ids: %w[@shipped:example.org])
  end

  let(:service) { described_class.new(models: models, floor: floor, audit: audit) }

  def audit_actions
    audit.query(community: described_class::AUDIT_SCOPE, source: described_class::AUDIT_SOURCE, limit: 50)
         .map(&:action)
  end

  # A handle grant resolves an already-known account once; authentication
  # later carries that account's native id.
  let(:grant_community) do
    now = Time.now
    models.community.create(slug: "grant-fixture", name: "Grant fixture", status: "active",
                             settings: "{}", created_at: now, updated_at: now)
  end

  before do
    Rubotty::ControlPlane::IdentityDirectory.new(models: models).record(
      community_id: grant_community.id, adapter: "telegram", native_id: "9001", username: "ada"
    )
  end

  describe "resolution" do
    it "answers yes for a granted row" do
      service.grant(adapter: "telegram", handle: "ada", granted_by: "admin")

      expect(service.administrator?(adapter: "telegram", native_id: "9001", username: "ada")).to be(true)
    end

    it "answers yes for a handle the deployment ships with" do
      expect(service.administrator?(adapter: "telegram", username: "shipped")).to be(true)
    end

    it "answers no for anybody in neither half" do
      expect(service.administrator?(adapter: "telegram", username: "stranger")).to be(false)
    end

    it "matches a granted row through the same normalisation the floor uses" do
      service.grant(adapter: "telegram", handle: "  A D A  ", granted_by: "admin")

      expect(service.administrator?(adapter: "telegram", native_id: "9001", username: "ada")).to be(true)
    end

    # Matrix is federated, so a bare localpart is not globally owned there.
    it "keys a granted Matrix administrator on the full id, from either field" do
      service.grant(adapter: "matrix", handle: "@ada:example.org", granted_by: "admin")

      expect(service.administrator?(adapter: "matrix", native_id: "@ada:example.org")).to be(true)
      expect(service.administrator?(adapter: "matrix", username: "@ada:example.org")).to be(true)
      expect(service.administrator?(adapter: "matrix", username: "ada")).to be(false)
    end

    # The rule that carries the most weight here: the display name is the one
    # field an impersonator controls.
    it "never matches a display name" do
      service.grant(adapter: "telegram", handle: "ada", label: "Ada Lovelace", granted_by: "admin")

      expect(service.administrator?(adapter: "telegram", username: "adalovelace")).to be(false)
    end

    it "reads a granted row on one platform as nothing on another" do
      service.grant(adapter: "telegram", handle: "ada", granted_by: "admin")

      expect(service.administrator?(adapter: "discord", username: "ada")).to be(false)
    end

    # Administrator and viewer are separate rosters, so a row in one is nothing
    # in the other.
    it "does not read a dashboard viewer as an administrator" do
      viewers = Rubotty::ControlPlane::DashboardViewers.new(
        models: models, floor: Rubotty::Security::DashboardViewers.new, audit: audit
      )
      viewers.grant(adapter: "telegram", handle: "ada", granted_by: "admin")

      expect(service.administrator?(adapter: "telegram", native_id: "9001", username: "ada")).to be(false)
    end
  end

  describe "#grant" do
    it "records who handed it over and when" do
      row = service.grant(adapter: "telegram", handle: "@ada", label: "Ada",
                          granted_by: "dashboard:administrator")

      expect(row[:adapter]).to eq("telegram")
      expect(row[:handle]).to eq("ada")
      expect(row[:label]).to eq("Ada")
      expect(row[:granted_by]).to eq("dashboard:administrator")
    end

    it "is idempotent, so a second grant is the same row" do
      first = service.grant(adapter: "telegram", handle: "ada", granted_by: "admin")
      second = service.grant(adapter: "telegram", handle: "ada", granted_by: "admin")

      expect(second[:id]).to eq(first[:id])
      expect(service.granted.length).to eq(1)
    end

    it "refuses a handle the deployment already ships with" do
      expect { service.grant(adapter: "telegram", handle: "shipped", granted_by: "admin") }
        .to raise_error(described_class::Invalid, /shipped list/)
    end

    it "refuses a platform nothing would ever match on" do
      expect { service.grant(adapter: "carrier-pigeon", handle: "ada", granted_by: "admin") }
        .to raise_error(described_class::Invalid)
    end

    it "refuses a blank handle" do
      expect { service.grant(adapter: "telegram", handle: "   ", granted_by: "admin") }
        .to raise_error(described_class::Invalid, /needs a handle/)
    end

    it "refuses a change nobody is named for" do
      expect { service.grant(adapter: "telegram", handle: "ada", granted_by: " ") }
        .to raise_error(described_class::Invalid, /who made it/)
    end

    it "writes an audit entry" do
      service.grant(adapter: "telegram", handle: "ada", granted_by: "dashboard:administrator")

      event = audit.query(community: described_class::AUDIT_SCOPE, limit: 10).first
      expect(event.action).to eq("administrator_granted")
      expect(event.subject).to eq("ada")
      expect(event.actor).to eq("dashboard:administrator")
      expect(event.adapter).to eq("telegram")
    end
  end

  describe "#revoke" do
    it "takes a granted row back" do
      row = service.grant(adapter: "telegram", handle: "ada", granted_by: "admin")

      result = service.revoke(id: row[:id], revoked_by: "admin")

      expect(result).to be_removed
      expect(service.administrator?(adapter: "telegram", native_id: "9001", username: "ada")).to be(false)
    end

    it "writes an audit entry" do
      row = service.grant(adapter: "telegram", handle: "ada", granted_by: "admin")
      service.revoke(id: row[:id], revoked_by: "dashboard:administrator")

      expect(audit_actions).to include("administrator_revoked")
    end

    it "answers :not_found for an id that was never granted" do
      expect(service.revoke(id: 9999, revoked_by: "admin").status).to eq(:not_found)
    end

    it "refuses a change nobody is named for" do
      row = service.grant(adapter: "telegram", handle: "ada", granted_by: "admin")

      expect { service.revoke(id: row[:id], revoked_by: nil) }
        .to raise_error(described_class::Invalid, /who made it/)
      expect(service.administrator?(adapter: "telegram", native_id: "9001", username: "ada")).to be(true)
    end

    # The row would go and the floor would carry on granting, so the refusal is
    # the honest answer rather than a delete that changes nothing.
    it "refuses a row the deployment also ships with" do
      id = db[:dashboard_administrators].insert(adapter: "telegram", handle: "shipped",
                                                granted_at: Time.now, granted_by: "seeded")

      result = service.revoke(id: id, revoked_by: "admin")

      expect(result).to be_protected
      expect(service.administrator?(adapter: "telegram", username: "shipped")).to be(true)
      expect(db[:dashboard_administrators].where(id: id).count).to eq(1)
    end

    it "refuses a shipped Matrix id the same way" do
      id = db[:dashboard_administrators].insert(adapter: "matrix", handle: "@shipped:example.org",
                                                granted_at: Time.now, granted_by: "seeded")

      expect(service.revoke(id: id, revoked_by: "admin")).to be_protected
    end
  end

  # The lockout question. Rows are all revocable on purpose, including the last
  # one, because an account that goes astray has to be removable in a hurry.
  # What stands underneath is the shipped floor, and the root password beyond it.
  describe "revoking the last administrator" do
    it "goes through, since a compromised account cannot be left in place" do
      row = service.grant(adapter: "telegram", handle: "ada", granted_by: "admin")

      expect(service.revoke(id: row[:id], revoked_by: "admin")).to be_removed
      expect(service.granted).to be_empty
    end

    it "leaves the shipped floor administering the deployment regardless" do
      row = service.grant(adapter: "telegram", handle: "ada", granted_by: "admin")
      service.revoke(id: row[:id], revoked_by: "admin")

      expect(service.administrator?(adapter: "telegram", username: "shipped")).to be(true)
      expect(service.baked_in).not_to be_empty
    end
  end

  describe "#baked_in?" do
    it "marks a shipped handle as not removable and a granted one as removable" do
      service.grant(adapter: "telegram", handle: "ada", granted_by: "admin")

      expect(service.baked_in?(adapter: "telegram", handle: "shipped")).to be(true)
      expect(service.baked_in?(adapter: "telegram", handle: "ada")).to be(false)
    end
  end

  # The table arrives with its own migration. Code that lands first has to read
  # the floor and carry on rather than take the control plane down with it.
  describe "before the table exists" do
    let(:bare) do
      bare_db = migrated_db
      bare_db.drop_table(:dashboard_administrators)
      described_class.new(models: build_models(bare_db), floor: floor, logger: Rubotty::Log.null)
    end

    it "still recognises everyone the deployment ships with" do
      expect(bare.administrator?(adapter: "telegram", username: "shipped")).to be(true)
    end

    it "reads an empty roster instead of raising" do
      expect(bare.granted).to eq([])
      expect(bare.administrator?(adapter: "telegram", native_id: "9001", username: "ada")).to be(false)
    end

    it "refuses a grant it cannot record, rather than reporting one it did not write" do
      expect { bare.grant(adapter: "telegram", handle: "ada", native_id: "9001", granted_by: "admin") }
        .to raise_error(described_class::Invalid, /not available on this deployment yet/)
    end
  end
end
