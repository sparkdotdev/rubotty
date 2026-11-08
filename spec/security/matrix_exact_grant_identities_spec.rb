# frozen_string_literal: true

require "spec_helper"

RSpec.describe "exact Matrix account authority", :control_plane do
  let(:db) { migrated_db }
  let(:models) { build_models(db) }
  let(:mxid) { "@CaseOwner:Example.ORG" }
  let(:other_case_ids) { ["@caseowner:Example.ORG", "@CaseOwner:example.org", "@caseowner:example.org"] }
  let(:community) do
    now = Time.now
    models.community.create(slug: "case-sensitive", name: "Case sensitive", status: "active",
                             settings: "{}", created_at: now, updated_at: now)
  end
  let(:flow) { Rubotty::ControlPlane::OperatorFlow.new(models: models) }

  before { without_owner_floor }

  {
    Rubotty::ControlPlane::DashboardAdministrators => [:administrator?, :dashboard_administrators],
    Rubotty::ControlPlane::DashboardViewers => [:viewer?, :dashboard_viewers],
    Rubotty::ControlPlane::CommunityViewers => [:viewer?, :community_viewers]
  }.each do |service_class, (predicate, table)|
    context service_class.name do
      let(:scope) { table == :community_viewers ? { community_id: community.id } : {} }
      let(:floor_class) do
        table == :dashboard_administrators ? Rubotty::Security::DashboardAdministrators : Rubotty::Security::DashboardViewers
      end
      let(:service) { service_class.new(models: models, floor: floor_class.new) }

      it "preserves the full granted MXID and refuses differing localpart or server case" do
        row = service.grant(**scope, adapter: "matrix", handle: mxid, granted_by: "administrator")

        expect(row.values_at(:handle, :native_id)).to eq([mxid, mxid])
        expect(service.public_send(predicate, **scope, adapter: "matrix", native_id: mxid)).to be(true)
        expect(service.public_send(predicate, **scope, adapter: "matrix", username: mxid)).to be(true)
        other_case_ids.each do |other|
          expect(service.public_send(predicate, **scope, adapter: "matrix", native_id: other, username: mxid)).to be(false)
          expect(service.public_send(predicate, **scope, adapter: "matrix", username: other)).to be(false)
        end
      end

      it "keeps two deliberately granted case-distinct accounts separate" do
        first = service.grant(**scope, adapter: "matrix", handle: mxid, granted_by: "administrator")
        second = service.grant(**scope, adapter: "matrix", handle: other_case_ids.first, granted_by: "administrator")

        expect(second[:id]).not_to eq(first[:id])
        expect(second[:native_id]).to eq(other_case_ids.first)
      end

      it "fails closed when a legacy database column compares native IDs without regard to case" do
        db.drop_table(table)
        community_scoped = table == :community_viewers
        db.create_table(table) do
          primary_key :id
          Integer :community_id if community_scoped
          String :adapter
          String :handle
          String :native_id, collate: "NOCASE"
          String :label
          DateTime :granted_at
          String :granted_by
          index [*(community_scoped ? [:community_id] : []), :adapter, :native_id], unique: true
        end
        row = service.grant(**scope, adapter: "matrix", handle: mxid, granted_by: "administrator")
        other = other_case_ids.first

        # Confirm the fixture's SQL comparison itself returns the wrong-case row.
        expect(db[table].where(native_id: other).first[:id]).to eq(row[:id])
        expect(service.public_send(predicate, **scope, adapter: "matrix", native_id: other)).to be(false)
        expect(service.public_send(predicate, **scope, adapter: "matrix", native_id: mxid)).to be(true)
        expect { service.grant(**scope, adapter: "matrix", handle: other, granted_by: "administrator") }
          .to raise_error(service_class::Invalid, /collation/)
        expect(db[table].count).to eq(1)
        if community_scoped
          expect(service.communities_for(adapter: "matrix", native_id: other)).to be_empty
          expect(service.communities_for(adapter: "matrix", native_id: mxid)).to eq([community.id])
        end
      end

      unless table == :dashboard_administrators
        it "retains the exact captured MXID when an access request is approved" do
          request = service.request(**scope, adapter: "matrix", native_id: mxid, username: "caseowner").request
          approved = service.approve(request: request, decided_by: "administrator")

          expect(approved).to be_approved
          expect(approved.viewer.values_at(:handle, :native_id)).to eq([mxid, mxid])
          expect(service.public_send(predicate, **scope, adapter: "matrix", native_id: mxid)).to be(true)
          other_case_ids.each do |other|
            expect(service.public_send(predicate, **scope, adapter: "matrix", native_id: other)).to be(false)
          end
        end
      end
    end
  end

  [
    [Rubotty::Security::ProtectedOperators, :owner?],
    [Rubotty::Security::DashboardViewers, :viewer?],
    [Rubotty::Security::DashboardAdministrators, :administrator?]
  ].each do |floor_class, predicate|
    it "preserves and matches exact configured Matrix IDs in #{floor_class.name}" do
      floor = floor_class.new(usernames: [], matrix_ids: [mxid])

      expect(floor.entries).to eq([{ handle: mxid, kind: "matrix" }])
      expect(floor.public_send(predicate, adapter: "matrix", native_id: mxid)).to be(true)
      expect(floor.public_send(predicate, adapter: "matrix", username: mxid)).to be(true)
      other_case_ids.each do |other|
        expect(floor.public_send(predicate, adapter: "matrix", native_id: other, username: mxid)).to be(false)
        expect(floor.public_send(predicate, adapter: "matrix", username: other)).to be(false)
      end
    end
  end

  it "resolves an operator and its linked reach only for the exact native account" do
    operator = flow.promote(community_id: community.id, adapter: "matrix", native_id: mxid,
                            username: "caseowner", granted_by: "administrator")
    reach = Rubotty::ControlPlane::AdminReach.new(operator_flow: flow)

    expect(flow.resolve_operator(community_id: community.id, adapter: "matrix", native_id: mxid).id).to eq(operator.id)
    expect(reach.operated(adapter: "matrix", native_id: mxid).map(&:id)).to eq([community.id])
    other_case_ids.each do |other|
      expect(flow.resolve_operator(community_id: community.id, adapter: "matrix", native_id: other, username: mxid)).to be_nil
      expect(reach.operated(adapter: "matrix", native_id: other, username: mxid)).to be_empty
    end
  end

  it "checks exact operator IDs even when a legacy identity column has a case-insensitive collation" do
    db.drop_table(:person_identities)
    db.create_table(:person_identities) do
      primary_key :id
      Integer :person_id
      Integer :community_id
      String :adapter
      String :native_id, collate: "NOCASE"
      String :username
      DateTime :claimed_at
      DateTime :created_at
      index %i[community_id adapter native_id], unique: true
    end
    operator = flow.promote(community_id: community.id, adapter: "matrix", native_id: mxid,
                            username: "caseowner", granted_by: "administrator")
    reach = Rubotty::ControlPlane::AdminReach.new(operator_flow: flow)

    expect(models.person_identity.where(native_id: other_case_ids.first).first.person_id).to eq(operator.person_id)
    expect(flow.resolve_operator(community_id: community.id, adapter: "matrix", native_id: mxid).id).to eq(operator.id)
    expect(reach.operated(adapter: "matrix", native_id: mxid).map(&:id)).to eq([community.id])
    other_case_ids.each do |other|
      expect(flow.resolve_operator(community_id: community.id, adapter: "matrix", native_id: other)).to be_nil
      expect(reach.operated(adapter: "matrix", native_id: other)).to be_empty
    end
  end

  it "keeps an exact Matrix operator identity in the runtime directory" do
    operator = Rubotty::Core::Moderation::Operator.new(name: "Case owner", identities: { matrix: [mxid] })
    directory = Rubotty::Core::Moderation::Directory.new([operator], protected_operators: nil)

    expect(directory.resolve(:matrix, mxid)).to eq(operator)
    other_case_ids.each { |other| expect(directory.resolve(:matrix, other)).to be_nil }
  end

  it "preserves exact account IDs through deployment token redemption" do
    administrators = Rubotty::ControlPlane::DashboardAdministrators.new(models: models, floor: Rubotty::Security::DashboardAdministrators.new)
    viewers = Rubotty::ControlPlane::DashboardViewers.new(models: models, floor: Rubotty::Security::DashboardViewers.new)
    tokens = Rubotty::ControlPlane::AuthTokens.new(models: models, dashboard_administrators: administrators,
                                                   dashboard_viewers: viewers)
    minter = Rubotty::ControlPlane::AuthTokens::Minter.new(administrator: true, community_ids: [], label: "administrator")
    issued = tokens.mint(minter: minter, administrator: true, viewer: true)

    outcome = tokens.redeem(token: issued.token, adapter: "matrix", native_id: mxid, username: "caseowner")

    expect(outcome.granted.administrator).to be(true)
    expect(outcome.granted.deployment_viewer).to be(true)
    expect(administrators.administrator?(adapter: "matrix", native_id: mxid)).to be(true)
    expect(viewers.viewer?(adapter: "matrix", native_id: mxid)).to be(true)
    other_case_ids.each do |other|
      expect(administrators.administrator?(adapter: "matrix", native_id: other)).to be(false)
      expect(viewers.viewer?(adapter: "matrix", native_id: other)).to be(false)
    end
  end
end
