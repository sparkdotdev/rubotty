# frozen_string_literal: true

require "spec_helper"

# Exercised against the seeded SAMPLE community, so the bootstrap operator and
# the real Snapshot are in play.
RSpec.describe Rubotty::ControlPlane::OperatorFlow, :control_plane do
  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:accounts) { sample_model.accounts }
  let(:registry) { Rubotty::ControlPlane::Registry.build(models: models, accounts: accounts) }
  let(:community) { models.community.where(slug: "sample").first }

  # Local time, because SQLite stores a DateTime without its zone and reads it
  # back in local time.
  let(:now) { Time.new(2026, 7, 23, 12, 0, 0) }

  subject(:flow) do
    described_class.new(models: models, registry: registry, logger: Rubotty::Log.null, clock: -> { now })
  end

  let(:bootstrap) { models.operator.first }

  def make_request(native_id: "999888", username: "newbie", display: "New Bie")
    flow.request(community_id: community.id, adapter: "telegram",
                 native_id: native_id, username: username, display: display)
  end

  describe "#request" do
    it "creates a pending request recording the requester identity and community" do
      result = make_request
      expect(result.status).to eq(:created)

      row = result.request
      expect(row.state).to eq("pending")
      expect(row.community_id).to eq(community.id)
      expect(row.adapter).to eq("telegram")
      expect(row.requester_native_id).to eq("999888")
      expect(row.requester_username).to eq("newbie")
      expect(row.requester_display).to eq("New Bie")
      expect(row.requested_at).to be_within(1).of(now)
    end

    it "lowercases and de-sigils the recorded handle" do
      result = flow.request(community_id: community.id, adapter: "telegram",
                            native_id: "5", username: "@Loud_Handle")
      expect(result.request.requester_username).to eq("loud_handle")
    end

    it "deduplicates a repeat pending request rather than creating a second row" do
      first = make_request
      second = make_request

      expect(second.status).to eq(:duplicate)
      expect(second.request.id).to eq(first.request.id)
      expect(models.operator_request.where(community_id: community.id, state: "pending").count).to eq(1)
    end

    it "refreshes the recorded display name on a repeat request" do
      make_request(display: "Old Name")
      again = make_request(display: "New Name")
      expect(again.status).to eq(:duplicate)
      expect(again.request.requester_display).to eq("New Name")
    end

    it "short-circuits when the requester is already an operator, granting nothing new" do
      result = flow.request(community_id: community.id, adapter: "telegram", native_id: "80000012")
      expect(result.status).to eq(:already_operator)
      expect(models.operator_request.count).to eq(0)
    end

    it "refuses a request with no identifiable requester id" do
      expect(flow.request(community_id: community.id, adapter: "telegram", native_id: "").status)
        .to eq(:invalid)
    end
  end

  describe "#resolve_operator" do
    it "resolves the seeded bootstrap operator across platforms" do
      expect(flow.resolve_operator(community_id: community.id, adapter: "telegram", native_id: "80000012"))
        .to be_truthy
      expect(flow.resolve_operator(community_id: community.id, adapter: "discord", native_id: "80000000000000013"))
        .to be_truthy
    end

    it "refuses a Telegram handle when no native account id is carried" do
      without_owner_floor
      expect(flow.resolve_operator(community_id: community.id, adapter: "telegram", username: "sample_owner"))
        .to be_nil
    end

    it "fails closed for anyone unknown" do
      expect(flow.resolve_operator(community_id: community.id, adapter: "telegram", native_id: "does-not-exist"))
        .to be_nil
    end
  end

  # SAMPLE's own bootstrap operator (sample_owner) is a real DB row, so it
  # proves nothing about the floor on its own. owner_handle is baked into the
  # floor too but carries no row anywhere, the shape the reported deployment
  # had: every operator on the floor, none an explicit row.
  describe "#resolve_operator for an operator who exists only on the deployment-configured floor" do
    it "recognises them by username, with no person or operator row at all" do
      resolved = flow.resolve_operator(community_id: community.id, adapter: "telegram",
                                       native_id: "70011", username: "owner_handle")
      expect(resolved).not_to be_nil
      expect(models.person_identity.where(adapter: "telegram", native_id: "70011").count).to eq(0)
    end

    it "still refuses somebody the floor does not carry and who has no row" do
      resolved = flow.resolve_operator(community_id: community.id, adapter: "telegram",
                                       native_id: "70012", username: "not_an_owner")
      expect(resolved).to be_nil
    end

    it "lets a floor-only operator approve a pending request" do
      floor_operator = flow.resolve_operator(community_id: community.id, adapter: "telegram",
                                             native_id: "70011", username: "owner_handle")
      request = make_request.request

      result = flow.approve(request: request, approver: floor_operator)

      expect(result.status).to eq(:approved)
      expect(models.operator_request[request.id].state).to eq("approved")
      # decided_by is a free-text label rather than a foreign key, so a
      # floor-only approver with no operators row still gets recorded.
      expect(models.operator_request[request.id].decided_by).to eq("protected-operator:floor:telegram:owner_handle")
    end

    it "lets a floor-only operator deny a pending request" do
      floor_operator = flow.resolve_operator(community_id: community.id, adapter: "telegram",
                                             native_id: "70011", username: "owner_handle")
      request = make_request.request

      result = flow.deny(request: request, approver: floor_operator)

      expect(result.status).to eq(:denied)
      expect(models.operator_request[request.id].state).to eq("denied")
    end
  end

  describe "#approve" do
    let(:request) { make_request.request }

    it "promotes the requester to operator, linking a person and identity" do
      result = flow.approve(request: request, approver: bootstrap)
      expect(result.status).to eq(:approved)

      operator = result.operator
      expect(operator.community_id).to eq(community.id)
      person = models.person[operator.person_id]
      expect(person.name).to eq("New Bie")

      identity = models.person_identity.where(person_id: person.id, adapter: "telegram").first
      expect(identity.native_id).to eq("999888")
      expect(identity.username).to eq("newbie")
    end

    it "marks the request approved and records the approver" do
      flow.approve(request: request, approver: bootstrap)
      row = models.operator_request[request.id]
      expect(row.state).to eq("approved")
      expect(row.decided_by).to eq("sample_owner")
      expect(row.decided_at).to be_within(1).of(now)
    end

    it "makes the new operator resolvable at the operations layer immediately" do
      flow.approve(request: request, approver: bootstrap)
      expect(flow.resolve_operator(community_id: community.id, adapter: "telegram", native_id: "999888"))
        .to be_truthy
    end

    it "updates the live Snapshot so the new operator is recognised without a restart" do
      expect(registry.current.community("sample").operators.resolve(:telegram, "999888")).to be_nil

      flow.approve(request: request, approver: bootstrap)

      # The atomic swap means the next reader resolves them as an operator.
      operator = registry.current.community("sample").operators.resolve(:telegram, "999888")
      expect(operator).not_to be_nil
      expect(operator.may?(:delete, "gaming", community_id: community.id)).to be(true)
    end

    it "adds exactly one operator row (alongside the seeded bootstrap operator)" do
      expect { flow.approve(request: request, approver: bootstrap) }
        .to change { models.operator.where(community_id: community.id).count }.from(1).to(2)
    end

    it "does not duplicate the promotion when the person is already an operator" do
      # Grant once, then feed a pending row back through the grant path, the
      # shape of a stale approval.
      flow.approve(request: request, approver: bootstrap)
      person = models.person_identity.where(adapter: "telegram", native_id: "999888").first.person_id
      pending_again = models.operator_request.create(
        community_id: community.id, adapter: "telegram", requester_native_id: "999888",
        requester_username: "newbie", state: "pending", requested_at: now
      )
      expect { flow.approve(request: pending_again, approver: bootstrap) }
        .not_to(change { models.operator.where(community_id: community.id, person_id: person).count })
    end
  end

  describe "#deny" do
    let(:request) { make_request.request }

    it "marks the request denied and grants no operator" do
      result = flow.deny(request: request, approver: bootstrap)
      expect(result.status).to eq(:denied)
      expect(models.operator_request[request.id].state).to eq("denied")
      expect(flow.resolve_operator(community_id: community.id, adapter: "telegram", native_id: "999888"))
        .to be_nil
    end

    it "does not block a later fresh request (the pending index only covers open requests)" do
      flow.deny(request: request, approver: bootstrap)
      again = make_request
      expect(again.status).to eq(:created)
    end
  end

  describe "#remove" do
    it "deletes an ordinary operator's row" do
      operator = flow.approve(request: make_request.request, approver: bootstrap).operator

      expect { flow.remove(community_id: community.id, id: operator.id) }
        .to change { models.operator.where(community_id: community.id).count }.by(-1)
    end

    it "reports :removed and returns the deleted row" do
      operator = flow.approve(request: make_request.request, approver: bootstrap).operator

      result = flow.remove(community_id: community.id, id: operator.id)
      expect(result.status).to eq(:removed)
      expect(result.operator.id).to eq(operator.id)
    end

    it "reports :not_found for an id with no matching row, and deletes nothing" do
      result = flow.remove(community_id: community.id, id: -1)
      expect(result.status).to eq(:not_found)
    end

    it "refuses to delete a row whose person also holds a deployment-configured protected username (issue #119)" do
      # promote, not request+approve: maintainer is on the floor now that #resolve_operator
      # asks it, so a request from them short-circuits to :already_operator, same as
      # it should. promote is the path that already assumes the grant is deserved.
      operator = flow.promote(community_id: community.id, adapter: "telegram", native_id: "5551212",
                              username: "maintainer", display: "Someone", granted_by: "test")

      result = flow.remove(community_id: community.id, id: operator.id)
      expect(result.status).to eq(:protected)
      expect(models.operator[operator.id]).not_to be_nil
    end

    it "refuses to delete a row whose person holds the deployment-configured Matrix MXID (issue #119)" do
      operator = flow.promote(community_id: community.id, adapter: "matrix",
                              native_id: "@owner:matrix.example.org", username: "owner",
                              granted_by: "test")

      result = flow.remove(community_id: community.id, id: operator.id)
      expect(result.status).to eq(:protected)
      expect(models.operator[operator.id]).not_to be_nil
    end

    it "is unaffected by a deployment-configured DISPLAY name; only the username protects" do
      request = make_request(native_id: "5551213", username: "not_the_owner", display: "maintainer")
      operator = flow.approve(request: request.request, approver: bootstrap).operator

      result = flow.remove(community_id: community.id, id: operator.id)
      expect(result.status).to eq(:removed)
    end
  end

  describe "permission enforcement" do
    let(:request) { make_request.request }

    it "refuses an approve with no approver and grants nothing" do
      result = flow.approve(request: request, approver: nil)
      expect(result.status).to eq(:forbidden)
      expect(models.operator_request[request.id].state).to eq("pending")
      expect(flow.resolve_operator(community_id: community.id, adapter: "telegram", native_id: "999888"))
        .to be_nil
    end

    it "refuses an approve by an operator of a different community" do
      other = other_community_operator
      result = flow.approve(request: request, approver: other)
      expect(result.status).to eq(:forbidden)
      expect(models.operator_request[request.id].state).to eq("pending")
    end
  end

  describe "#request_from_dm" do
    it "uses the one community served by the account when there is exactly one" do
      result = flow.request_from_dm(adapter: "telegram", account: "telegram",
                                    native_id: "999888", username: "newbie", display: "New Bie")
      expect(result.status).to eq(:created)
      expect(result.request.community_id).to eq(community.id)
      expect(result.communities.map(&:slug)).to eq(["sample"])
    end

    it "returns :no_community when the account serves nobody" do
      result = flow.request_from_dm(adapter: "telegram", account: "unknown-account", native_id: "5")
      expect(result.status).to eq(:no_community)
    end

    it "returns :ambiguous with the candidate list when several communities share the account (#37)" do
      add_second_community_on_telegram
      result = flow.request_from_dm(adapter: "telegram", account: "telegram", native_id: "5")
      expect(result.status).to eq(:ambiguous)
      expect(result.communities.map(&:slug)).to contain_exactly("sample", "second")
    end
  end

  # An operator of a different community, for the community scope of the
  # approve permission check.
  def other_community_operator
    other = models.community.create(slug: "other", name: "Other", status: "active",
                                    settings: "{}", created_at: now, updated_at: now)
    person = models.person.create(community_id: other.id, name: "Otto", created_at: now, updated_at: now)
    models.operator.create(community_id: other.id, person_id: person.id,
                           actions: '"all"', scope: '"all"', granted_at: now, granted_by: "seed")
  end

  # A second community owning a channel on the shared account, so a DM to that
  # account is genuinely ambiguous.
  def add_second_community_on_telegram
    second = models.community.create(slug: "second", name: "Second", status: "active",
                                     settings: "{}", created_at: now, updated_at: now)
    conn = models.platform_connection.create(
      community_id: second.id, adapter: "telegram", account: "telegram",
      external_id: "-100999", created_at: now, updated_at: now
    )
    models.channel.create(
      community_id: second.id, platform_connection_id: conn.id,
      adapter: "telegram", account: "telegram", route_key: "-100999/1",
      endpoint_key: "tg-second", label: "second", receives: true, sends: true,
      relay: "{}", display_name: "{}", settings: '{"chat_id":"-100999","thread_id":1}',
      created_at: now, updated_at: now
    )
    second
  end
end
