# frozen_string_literal: true

require "spec_helper"
require "sequel"

# The viewer roster: the shipped YAML as a floor, granted rows on top, and the
# union of the two as the answer. The floor's own file parsing is exercised in
# spec/security/dashboard_viewers_spec.rb; what matters here is that a row and a
# shipped entry resolve the same, and that only one of them can be taken away.
RSpec.describe Rubotty::ControlPlane::DashboardViewers, :control_plane do
  let(:db) { migrated_db }
  let(:models) { build_models(db) }
  let(:audit) { Rubotty::Core::AuditLog::Sequel.new(db: db) }

  # A floor naming one handle per matching rule, so "cannot be revoked" can be
  # asserted against both.
  let(:floor) do
    Rubotty::Security::DashboardViewers.new(usernames: %w[shipped], matrix_ids: %w[@shipped:example.org])
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

      expect(service.viewer?(adapter: "telegram", native_id: "9001", username: "ada")).to be(true)
    end

    it "answers yes for a handle the deployment ships with" do
      expect(service.viewer?(adapter: "telegram", username: "shipped")).to be(true)
    end

    it "answers no for anybody in neither half" do
      expect(service.viewer?(adapter: "telegram", username: "stranger")).to be(false)
    end

    it "matches a granted row through the same normalisation the floor uses" do
      service.grant(adapter: "telegram", handle: "  A D A  ", granted_by: "admin")

      expect(service.viewer?(adapter: "telegram", native_id: "9001", username: "ada")).to be(true)
    end

    # Matrix is federated, so a bare localpart is not globally owned there.
    it "keys a granted Matrix viewer on the full id, from either field" do
      service.grant(adapter: "matrix", handle: "@ada:example.org", granted_by: "admin")

      expect(service.viewer?(adapter: "matrix", native_id: "@ada:example.org")).to be(true)
      expect(service.viewer?(adapter: "matrix", username: "@ada:example.org")).to be(true)
      expect(service.viewer?(adapter: "matrix", username: "ada")).to be(false)
    end

    it "never matches a display name" do
      service.grant(adapter: "telegram", handle: "ada", label: "Ada Lovelace", granted_by: "admin")

      expect(service.viewer?(adapter: "telegram", username: "adalovelace")).to be(false)
    end

    it "reads a granted row on one platform as nothing on another" do
      service.grant(adapter: "telegram", handle: "ada", granted_by: "admin")

      expect(service.viewer?(adapter: "discord", username: "ada")).to be(false)
    end
  end

  describe "#grant" do
    it "records who handed it over and when" do
      row = service.grant(adapter: "telegram", handle: "@ada", label: "Ada", granted_by: "dashboard:administrator")

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
      expect(event.action).to eq("viewer_granted")
      expect(event.subject).to eq("ada")
      expect(event.actor).to eq("dashboard:administrator")
      expect(event.adapter).to eq("telegram")
    end

    it "returns the granted row itself, never a Result" do
      row = service.grant(adapter: "telegram", handle: "ada", granted_by: "admin")

      expect(row).not_to be_a(described_class::Result)
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

  describe "#revoke" do
    it "takes a granted row back" do
      row = service.grant(adapter: "telegram", handle: "ada", granted_by: "admin")

      result = service.revoke(id: row[:id], revoked_by: "admin")

      expect(result).to be_removed
      expect(service.viewer?(adapter: "telegram", native_id: "9001", username: "ada")).to be(false)
    end

    it "writes an audit entry" do
      row = service.grant(adapter: "telegram", handle: "ada", granted_by: "admin")
      service.revoke(id: row[:id], revoked_by: "dashboard:administrator")

      expect(audit_actions).to include("viewer_revoked")
    end

    it "answers :not_found for an id that was never granted" do
      expect(service.revoke(id: 9999, revoked_by: "admin").status).to eq(:not_found)
    end

    # The row would go and the floor would carry on granting, so the refusal is
    # the honest answer rather than a delete that changes nothing.
    it "refuses a row the deployment also ships with" do
      id = db[:dashboard_viewers].insert(adapter: "telegram", handle: "shipped",
                                         granted_at: Time.now, granted_by: "seeded")

      result = service.revoke(id: id, revoked_by: "admin")

      expect(result).to be_protected
      expect(service.viewer?(adapter: "telegram", username: "shipped")).to be(true)
      expect(db[:dashboard_viewers].where(id: id).count).to eq(1)
    end

    it "refuses a shipped Matrix id the same way" do
      id = db[:dashboard_viewers].insert(adapter: "matrix", handle: "@shipped:example.org",
                                         granted_at: Time.now, granted_by: "seeded")

      expect(service.revoke(id: id, revoked_by: "admin")).to be_protected
    end
  end

  describe "#request" do
    it "records a pending row" do
      result = service.request(adapter: "telegram", native_id: "9001", username: "ada", display: "Ada")

      expect(result).to be_created
      expect(result.request[:state]).to eq("pending")
      expect(service.pending.map { |row| row[:requester_username] }).to eq(["ada"])
    end

    it "hands back the open request rather than filing a second" do
      service.request(adapter: "telegram", native_id: "9001", username: "ada")
      second = service.request(adapter: "telegram", native_id: "9001", username: "ada")

      expect(second).to be_duplicate
      expect(service.pending.length).to eq(1)
    end

    it "files nothing for somebody who already reads every community" do
      expect(service.request(adapter: "telegram", native_id: "1", username: "shipped").status)
        .to eq(:already_viewer)
      expect(service.pending).to be_empty
    end

    it "writes an audit entry" do
      service.request(adapter: "telegram", native_id: "9001", username: "ada")

      expect(audit_actions).to include("viewer_requested")
    end
  end

  describe "#approve" do
    it "grants the requester and marks the request approved" do
      filed = service.request(adapter: "telegram", native_id: "9001", username: "ada", display: "Ada").request

      result = service.approve(request: filed, decided_by: "dashboard:administrator")

      expect(result).to be_approved
      expect(result.request[:state]).to eq("approved")
      expect(result.request[:decided_by]).to eq("dashboard:administrator")
      expect(service.viewer?(adapter: "telegram", native_id: "9001", username: "ada")).to be(true)
    end

    it "writes the grant to the audit log" do
      filed = service.request(adapter: "telegram", native_id: "9001", username: "ada").request
      service.approve(request: filed, decided_by: "dashboard:administrator")

      expect(audit_actions).to include("viewer_granted")
    end

    it "refuses a decision nobody is named for" do
      filed = service.request(adapter: "telegram", native_id: "9001", username: "ada").request

      expect(service.approve(request: filed, decided_by: nil)).to be_forbidden
      expect(service.viewer?(adapter: "telegram", native_id: "9001", username: "ada")).to be(false)
    end

    it "refuses a request already decided" do
      filed = service.request(adapter: "telegram", native_id: "9001", username: "ada").request
      service.deny(request: filed, decided_by: "admin")

      expect(service.approve(request: service.find_request(id: filed[:id]), decided_by: "admin").status)
        .to eq(:not_pending)
    end

    it "grants the full id for a Matrix requester" do
      filed = service.request(adapter: "matrix", native_id: "@ada:example.org", username: "ada").request
      service.approve(request: filed, decided_by: "admin")

      expect(service.viewer?(adapter: "matrix", native_id: "@ada:example.org")).to be(true)
    end
  end

  describe "#deny" do
    it "grants nothing and leaves a later ask open" do
      filed = service.request(adapter: "telegram", native_id: "9001", username: "ada").request

      result = service.deny(request: filed, decided_by: "dashboard:administrator")

      expect(result).to be_denied
      expect(service.viewer?(adapter: "telegram", native_id: "9001", username: "ada")).to be(false)
      expect(service.granted).to be_empty
      expect(service.request(adapter: "telegram", native_id: "9001", username: "ada")).to be_created
    end

    it "writes an audit entry" do
      filed = service.request(adapter: "telegram", native_id: "9001", username: "ada").request
      service.deny(request: filed, decided_by: "admin")

      expect(audit_actions).to include("viewer_request_denied")
    end
  end

  # The tables arrive with their own migration. Code that lands first has to read
  # the floor and carry on rather than take the control plane down with it.
  describe "before the tables exist" do
    let(:bare) do
      bare_db = migrated_db
      bare_db.drop_table(:dashboard_viewer_requests)
      bare_db.drop_table(:dashboard_viewers)
      described_class.new(models: build_models(bare_db), floor: floor, logger: Rubotty::Log.null)
    end

    it "still recognises everyone the deployment ships with" do
      expect(bare.viewer?(adapter: "telegram", username: "shipped")).to be(true)
    end

    it "reads an empty roster instead of raising" do
      expect(bare.granted).to eq([])
      expect(bare.pending).to eq([])
      expect(bare.viewer?(adapter: "telegram", native_id: "9001", username: "ada")).to be(false)
    end

    it "answers a request it cannot record" do
      expect(bare.request(adapter: "telegram", native_id: "9001", username: "ada").status).to eq(:invalid)
    end
  end
end
