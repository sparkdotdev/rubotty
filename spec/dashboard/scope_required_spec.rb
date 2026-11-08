# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"

# Three seams let a scope go missing: a read gate that answered true for any
# operator on a nil community (#1793), a control that made the grant mandatory
# and the community optional (#1794), and a nav entry offered wherever it named
# no gate at all (#1805). The two communities are the shared fixture's.
RSpec.describe "the dashboard asks for a community alongside every grant" do
  let(:alpha) { colliding_community(CollidingCommunities::ALPHA) }
  let(:beta) { colliding_community(CollidingCommunities::BETA) }
  let(:role) { Rubotty::Dashboard::Role.operator(community_ids: [alpha.id]) }

  describe "a scoped read (#1793)" do
    # Inverted from answering true on a nil community: three routes relied on
    # that for their deployment-wide pages, and they now say Role::DEPLOYMENT.
    Rubotty::Dashboard::Role::SCOPED_READ_ACTIONS.each do |action|
      it "denies #{action} when the community went missing" do
        expect(role.can?(action, community: nil)).to be(false)
      end

      it "allows #{action} in the community this operator runs, and refuses the other" do
        expect(role.can?(action, community: alpha)).to be(true)
        expect(role.can?(action, community: beta)).to be(false)
      end

      it "allows #{action} at deployment scope, which narrows its own rows" do
        expect(role.can?(action, community: Rubotty::Dashboard::Role::DEPLOYMENT)).to be(true)
      end
    end

    # The defect was the asymmetry: two adjacent private methods answered a nil
    # community in opposite directions.
    it "answers a nil community the same way for a read as for a write" do
      expect(role.can?(:view_community, community: nil)).to eq(role.can?(:manage_rooms, community: nil))
    end

    it "will not answer at all without being told the scope" do
      expect { role.can?(:view_community) }.to raise_error(ArgumentError, /community/)
    end
  end

  describe "a control that spends a grant (#1794)" do
    let(:surface) do
      Class.new do
        include Rubotty::Dashboard::Primitives::Identity

        def may?(action, community:) = !community.nil?
      end.new
    end

    it "will not draw one without the community the grant is spent against" do
      expect { surface.button("Mute", action: :moderate_user) }.to raise_error(ArgumentError, /community/)
    end

    it "draws it flat where the role may not press it in this community" do
      expect(surface.button("Mute", action: :moderate_user, community: nil)).to include("rb-button--flat")
      expect(surface.button("Mute", action: :moderate_user, community: beta)).not_to include("rb-button--flat")
    end
  end

  describe "a navigation entry (#1805)" do
    def offer(item, community)
      Rubotty::Dashboard::Nav.send(:permits?, role, item, community)
    end

    # Inverted from offering an entry that named no gate: a community section
    # added with neither a grant nor admin_only appeared in every community.
    it "is hidden when it names no gate at all" do
      item = Rubotty::Dashboard::Nav::Item.new(key: "new", label: "New", path: "new")
      expect(offer(item, alpha)).to be(false)
      expect(offer(item, beta)).to be(false)
    end

    it "is offered when it says out loud that it is ungated" do
      item = Rubotty::Dashboard::Nav::Item.new(key: "new", label: "New", path: "new", open: true)
      expect(offer(item, alpha)).to be(true)
    end

    it "still offers an admin_only entry to an administrator and nobody else" do
      item = Rubotty::Dashboard::Nav::Item.new(key: "keys", label: "API keys", path: "api-keys", admin_only: true)
      expect(offer(item, alpha)).to be(false)
      expect(Rubotty::Dashboard::Nav.send(:permits?, Rubotty::Dashboard::Role.administrator, item, alpha)).to be(true)
    end

    it "still gates an entry that carries a grant, community by community" do
      item = Rubotty::Dashboard::Nav::Item.new(key: "audit", label: "Audit", path: "audit", grant: :view_audit_log)
      expect(offer(item, alpha)).to be(true)
      expect(offer(item, beta)).to be(false)
    end

    it "leaves every catalogued entry naming a gate, so none rides on the default" do
      items = (Rubotty::Dashboard::Nav::COMMUNITY_GROUPS + Rubotty::Dashboard::Nav::DEPLOYMENT_GROUPS)
              .flat_map(&:items)
      ungated = items.reject { |item| item.grant || item.admin_only || item.open }
      expect(ungated.map(&:key)).to be_empty
    end
  end
end
