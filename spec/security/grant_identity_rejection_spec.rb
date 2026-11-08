# frozen_string_literal: true

require "spec_helper"
require "tempfile"

RSpec.describe "fail-closed privileged identity inputs", :control_plane do
  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }

  before { without_owner_floor }

  it "does not resolve an operator through a persisted account on an unknown adapter" do
    operator = models.operator.where(community_id: community.id).first
    models.person_identity.create(person_id: operator.person_id, community_id: community.id,
      adapter: "future_platform", native_id: "account-55", username: "configured-owner", created_at: Time.now)
    flow = Rubotty::ControlPlane::OperatorFlow.new(models: models)

    expect(flow.resolve_operator(community_id: community.id, adapter: "future_platform",
      native_id: "account-55", username: "configured-owner")).to be_nil
    expect(flow.resolve_operator(community_id: community.id, adapter: "telegram", native_id: "80000012").id)
      .to eq(operator.id)
    expect(models.person_identity.where(adapter: "future_platform", native_id: "account-55").count).to eq(1)
  end

  {
    Rubotty::ControlPlane::DashboardAdministrators => [:administrator?, :dashboard_administrators],
    Rubotty::ControlPlane::DashboardViewers => [:viewer?, :dashboard_viewers],
    Rubotty::ControlPlane::CommunityViewers => [:viewer?, :community_viewers]
  }.each do |service_class, (predicate, table)|
    it "requires an explicit account grant rather than inferring #{service_class.name} from an old XMPP occupant observation" do
      Rubotty::ControlPlane::IdentityDirectory.new(models: models).record(
        community_id: community.id, adapter: "xmpp", native_id: "occupant:Alice", username: "alice"
      )
      floor_class = table == :dashboard_administrators ? Rubotty::Security::DashboardAdministrators : Rubotty::Security::DashboardViewers
      service = service_class.new(models: models, floor: floor_class.new)
      scope = table == :community_viewers ? { community_id: community.id } : {}

      expect { service.grant(**scope, adapter: "xmpp", handle: "alice", granted_by: "fixture-owner") }
        .to raise_error(service_class::Invalid, /does not provide a durable account identity/)
      expect(db[table].count).to eq(0)

      granted = service.grant(**scope, adapter: "xmpp", handle: "alice", native_id: "alice@example.org",
        granted_by: "fixture-owner")
      expect(granted[:native_id]).to eq("jid:alice@example.org")
      expect(service.public_send(predicate, **scope, adapter: "xmpp", native_id: "occupant:Alice")).to be(false)
      expect(service.public_send(predicate, **scope, adapter: "xmpp", native_id: "jid:alice@example.org")).to be(true)
      expect(models.observed_identity.where(adapter: "xmpp", native_id: "occupant:Alice").count).to eq(1)
    end
  end

  it "ignores a null Matrix configuration entry while preserving the exact configured owner" do
    Tempfile.create(["finite-owner-config", ".yml"]) do |file|
      file.write("matrix:\n  -\n  - \"@Owner:Example.ORG\"\n")
      file.flush
      floor = Rubotty::Security::ProtectedOperators.load(file.path)

      expect(floor.entries).to eq([{ handle: "@Owner:Example.ORG", kind: "matrix" }])
      expect(floor.owner?(adapter: "matrix", native_id: "@Owner:Example.ORG")).to be(true)
      expect(floor.owner?(adapter: "matrix", native_id: nil, username: nil)).to be(false)
      expect(floor.owner?(adapter: "matrix", native_id: "@owner:example.org")).to be(false)
    end
  end

  it "grants no owner rights from syntactically valid YAML that is not a configuration mapping" do
    Tempfile.create(["finite-owner-list", ".yml"]) do |file|
      file.write("- usernames\n- configured-owner\n- '@Owner:Example.ORG'\n")
      file.flush
      floor = Rubotty::Security::ProtectedOperators.load(file.path)

      expect(floor).to be_empty
      expect(floor.entries).to be_empty
      expect(floor.owner?(adapter: "telegram", username: "configured-owner")).to be(false)
      expect(floor.owner?(adapter: "matrix", native_id: "@Owner:Example.ORG")).to be(false)
    end
  end
end
