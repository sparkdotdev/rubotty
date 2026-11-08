# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard/action_permissions"
require "rubotty/dashboard/role"

# The role model behind the web panel's authorization layer, a plain Ruby value
# object exercised directly with no session or HTTP request involved. The
# Sinatra-level guards that wrap it are covered in authorization_spec.rb.
RSpec.describe Rubotty::Dashboard::Role do
  let(:community) { Struct.new(:id).new(7) }
  let(:other_community) { Struct.new(:id).new(9) }

  describe ".administrator" do
    subject(:role) { described_class.administrator }

    it { is_expected.to be_administrator }
    it { is_expected.not_to be_operator }

    it "can take any action, community-scoped or not" do
      expect(role.can?(:anything, community: nil)).to be(true)
      expect(role.can?(:anything, community: community)).to be(true)
    end

    it "is scoped to every community, including none in particular" do
      expect(role.scoped_to?(community)).to be(true)
      expect(role.scoped_to?(nil)).to be(true)
    end
  end

  describe ".operator" do
    subject(:role) { described_class.operator(community_ids: [community.id]) }

    it { is_expected.to be_operator }
    it { is_expected.not_to be_administrator }

    it "defaults to an empty community scope" do
      expect(described_class.operator.community_ids).to eq([])
    end

    it "is scoped only to the communities it was granted, the #162 write-own rule" do
      expect(role.scoped_to?(community)).to be(true)
      expect(role.scoped_to?(other_community)).to be(false)
      expect(role.scoped_to?(nil)).to be(false)
    end

    it "can narrow the write allow list from the database-backed matrix" do
      narrowed = described_class.operator(community_ids: [community.id], write_actions: [:edit_faq])

      expect(narrowed.can?(:edit_faq, community: community)).to be(true)
      expect(narrowed.can?(:edit_word_filter, community: community)).to be(false)
    end

    # Read-all: every READ_ACTIONS entry is allowed against ANY community, granted or
    # not, and against no community at all. Listing is the only genuinely global read,
    # since an operator has to see a community exists to ask for access to it.
    describe "the list-all allow list" do
      described_class::GLOBAL_READ_ACTIONS.each do |action|
        it "allows #{action} against a granted community" do
          expect(role.can?(action, community: community)).to be(true)
        end

        it "allows #{action} against a community it was never granted" do
          expect(role.can?(action, community: other_community)).to be(true)
        end

        it "allows #{action} with no community at all" do
          expect(role.can?(action, community: nil)).to be(true)
        end
      end
    end

    # Reading one community's CONTENTS is scoped, since unrelated communities share
    # a deployment.
    describe "the read-own allow list" do
      described_class::SCOPED_READ_ACTIONS.each do |action|
        it "allows #{action} against a granted community" do
          expect(role.can?(action, community: community)).to be(true)
        end

        it "denies #{action} against a community it was never granted" do
          expect(role.can?(action, community: other_community)).to be(false)
        end

        # The aggregate page's shell carries nothing until a community is
        # picked, and it says so with Role::DEPLOYMENT. Inverted from allowing
        # a nil community: that answered true for every operator, so a read
        # that lost its argument read somebody else's community (#1793).
        it "allows #{action} at deployment scope, since that is only the page shell" do
          expect(role.can?(action, community: described_class::DEPLOYMENT)).to be(true)
        end

        it "denies #{action} with no community at all" do
          expect(role.can?(action, community: nil)).to be(false)
        end
      end
    end

    it "still lets an administrator read every community" do
      admin = described_class.administrator

      described_class::READ_ACTIONS.each do |action|
        expect(admin.can?(action, community: other_community)).to be(true)
      end
    end

    # Write-own: every WRITE_ACTIONS entry is allowed only against a community in
    # community_ids.
    describe "the write-own allow list" do
      # An operator holding every grant an administrator could hand over, which
      # is the widest an operator ever gets.
      let(:granted) do
        described_class.operator(community_ids: [community.id],
                                 write_actions: described_class::WRITE_ACTIONS)
      end

      it "names every grant the permissions page offers" do
        expect(described_class::WRITE_ACTIONS)
          .to match_array(Rubotty::Dashboard::ActionPermissions::ACTIONS.keys)
      end

      it "allows each one against a granted community" do
        described_class::WRITE_ACTIONS.each do |action|
          expect(granted.can?(action, community: community)).to be(true), "#{action} was denied"
        end
      end

      it "denies each one against a community it was never granted" do
        described_class::WRITE_ACTIONS.each do |action|
          expect(granted.can?(action, community: other_community)).to be(false), "#{action} was allowed"
        end
      end

      it "denies each one with no community to scope the write to" do
        described_class::WRITE_ACTIONS.each do |action|
          expect(granted.can?(action, community: nil)).to be(false), "#{action} was allowed unscoped"
          expect(granted.can?(action, community: described_class::DEPLOYMENT)).to be(false),
                 "#{action} was allowed at deployment scope"
        end
      end

      it "grants nothing until an administrator hands a specific action over" do
        described_class::WRITE_ACTIONS.each do |action|
          expect(role.can?(action, community: community)).to be(false), "#{action} was allowed by default"
        end
      end
    end

    # Both Rooms grants wire into every Rooms write route, while the four GET
    # routes that draw those controls, and the nav link to them, are gated on
    # view_rooms. Without this an administrator ticking "Rooms: create and
    # delete" hands over controls the operator cannot reach.
    describe "a read a write grant carries with it" do
      %i[manage_rooms manage_discovered].each do |grant|
        it "reads the Rooms pages of a community it holds #{grant} in" do
          scoped = described_class.operator(community_ids: [community.id], write_actions: [grant])

          expect(scoped.can?(:view_rooms, community: community)).to be(true)
        end

        it "reads no other community's Rooms pages on #{grant}" do
          scoped = described_class.operator(community_ids: [community.id], write_actions: [grant])

          expect(scoped.can?(:view_rooms, community: other_community)).to be(false)
        end

        it "reads no other oversight page on #{grant} alone" do
          scoped = described_class.operator(community_ids: [community.id], write_actions: [grant])
          others = described_class::OVERSIGHT_READ_ACTIONS - [:view_rooms]

          others.each do |action|
            expect(scoped.can?(action, community: community)).to be(false), "#{action} was allowed"
          end
        end
      end

      it "leaves an operator with neither Rooms grant where it was" do
        expect(role.can?(:view_rooms, community: community)).to be(false)
      end

      it "names only reads the oversight list already has" do
        expect(described_class::READS_IMPLIED_BY_WRITES.keys - described_class::OVERSIGHT_READ_ACTIONS)
          .to be_empty
      end

      it "names only writes an administrator can actually grant" do
        expect(described_class::READS_IMPLIED_BY_WRITES.values.flatten - described_class::WRITE_ACTIONS)
          .to be_empty
      end
    end

    # Nothing here is on either allow list, so each falls through can?'s default even
    # against a granted community. An operator is what this is about: a few of these
    # are reads the viewer dimension does answer yes to, which the viewer section
    # further down covers.
    describe "the always-deny list" do
      denied = %i[
        list_platform_connections edit_platform_connections view_tokens edit_tokens
        start_bot stop_bot disconnect_bot
        view_join_links create_join_link
        create_community delete_community
        decide_operator_request manage_operators
      ]

      it "shares nothing with the write allow list, so none of it can be granted" do
        expect(denied & described_class::WRITE_ACTIONS).to be_empty
      end

      denied.each do |action|
        it "denies #{action} even against a granted community" do
          expect(role.can?(action, community: community)).to be(false)
        end

        it "denies #{action} against an ungranted community" do
          expect(role.can?(action, community: other_community)).to be(false)
        end

        it "denies #{action} with no community at all" do
          expect(role.can?(action, community: nil)).to be(false)
        end
      end
    end

    it "denies an action nobody has named yet, defaulting closed rather than open" do
      expect(role.can?(:some_future_action, community: community)).to be(false)
    end
  end

  # Viewer crosses the two kinds instead of sitting below them: one Role can carry
  # viewer AND an operator's community scope at once. Reads answer from the viewer
  # half, writes from the operator half, and nothing about being a viewer widens a write.
  describe ".viewer" do
    subject(:role) { described_class.viewer }

    it { is_expected.to be_viewer }

    # Still an operator kind, because viewer is a dimension rather than a kind:
    # session handling, the login gate and the request-access route all read the
    # kind, and a third value would have meant teaching each of them about it.
    it { is_expected.to be_operator }
    it { is_expected.not_to be_administrator }

    it "is not a viewer by default, so the dimension has to be asked for" do
      expect(described_class.operator).not_to be_viewer
    end

    # Anything but a literal true, so a session value or a JSON round trip that
    # leaves a string behind cannot turn into deployment-wide reads.
    it "takes only a literal true as viewer status" do
      expect(described_class.operator(viewer: "yes")).not_to be_viewer
      expect(described_class.operator(viewer: 1)).not_to be_viewer
      expect(described_class.operator(viewer: nil)).not_to be_viewer
    end

    describe "reading" do
      described_class::READ_ACTIONS.each do |action|
        it "allows #{action} against a community it was never granted" do
          expect(role.can?(action, community: other_community)).to be(true)
        end
      end

      described_class::OVERSIGHT_READ_ACTIONS.each do |action|
        it "allows #{action}, which an operator is refused" do
          expect(role.can?(action, community: other_community)).to be(true)
          expect(described_class.operator(community_ids: [other_community.id])
                                .can?(action, community: other_community)).to be(false)
        end
      end

      # Accounts and API keys are guarded by the administrator check rather than
      # by an action, so the guarantee here is that no read action names them.
      it "names no oversight read for accounts or API keys" do
        expect(described_class::OVERSIGHT_READ_ACTIONS).not_to include(:view_accounts, :view_api_keys)
      end
    end

    describe "writing" do
      # The core promise: viewer status on its own authorises no change at all,
      # whatever grants the deployment has handed out.
      it "is refused every write action, in any community" do
        granted = described_class.viewer(write_actions: described_class::WRITE_ACTIONS)

        described_class::WRITE_ACTIONS.each do |action|
          expect(granted.can?(action, community: community)).to be(false), "#{action} was allowed"
          expect(granted.can?(action, community: other_community)).to be(false), "#{action} was allowed"
          expect(granted.can?(action, community: nil)).to be(false), "#{action} was allowed unscoped"
        end
      end

      it "is scoped to no community, so scoped_to? answers no everywhere" do
        expect(role.scoped_to?(community)).to be(false)
        expect(role.scoped_to?(other_community)).to be(false)
      end
    end
  end

  describe "a viewer who also operates one community" do
    subject(:role) do
      described_class.operator(community_ids: [community.id], write_actions: [:configure_faq], viewer: true)
    end

    it { is_expected.to be_viewer }

    it "reads a community it operates and one it does not, alike" do
      expect(role.can?(:view_community, community: community)).to be(true)
      expect(role.can?(:view_community, community: other_community)).to be(true)
    end

    it "reads the administration screens everywhere, the same as a plain viewer" do
      expect(role.can?(:view_platforms, community: other_community)).to be(true)
    end

    # The overlap: the operator half decides the write, and it stops where an
    # ordinary operator of that community would stop.
    it "writes its granted action in the community it operates, and nowhere else" do
      expect(role.can?(:configure_faq, community: community)).to be(true)
      expect(role.can?(:configure_faq, community: other_community)).to be(false)
    end

    it "is still refused a write it holds no grant for, even where it operates" do
      expect(role.can?(:configure_word_filter, community: community)).to be(false)
    end

    it "is still refused an administrator-only action where it operates" do
      expect(role.can?(:manage_operators, community: community)).to be(false)
    end
  end

  # The same dimension, one community wide: every read there, no write there,
  # and no sight at all of any other community.
  describe ".community_viewer" do
    subject(:role) { described_class.community_viewer(viewer_community_ids: [community.id]) }

    it { is_expected.to be_operator }

    # Not the deployment-wide dimension, which is the whole distinction: it
    # reads every OTHER community too.
    it { is_expected.not_to be_viewer }
    it { is_expected.not_to be_administrator }

    describe "reading" do
      described_class::READ_ACTIONS.each do |action|
        it "allows #{action} in the community it reads" do
          expect(role.can?(action, community: community)).to be(true)
        end
      end

      described_class::OVERSIGHT_READ_ACTIONS.each do |action|
        it "allows #{action} there, which an operator is refused" do
          expect(role.can?(action, community: community)).to be(true)
          expect(described_class.operator(community_ids: [community.id])
                                .can?(action, community: community)).to be(false)
        end
      end

      it "reads nothing at all in a community it was not named in" do
        (described_class::READ_ACTIONS + described_class::OVERSIGHT_READ_ACTIONS).each do |action|
          next if described_class::GLOBAL_READ_ACTIONS.include?(action)

          expect(role.can?(action, community: other_community)).to be(false), "#{action} was allowed"
        end
      end
    end

    describe "writing" do
      it "is refused every write action, in the community it reads and outside it" do
        granted = described_class.community_viewer(
          viewer_community_ids: [community.id], write_actions: described_class::WRITE_ACTIONS
        )

        described_class::WRITE_ACTIONS.each do |action|
          expect(granted.can?(action, community: community)).to be(false), "#{action} was allowed"
          expect(granted.can?(action, community: other_community)).to be(false), "#{action} was allowed"
        end
      end

      # Reading a community is not a licence to hand the same reading on.
      it "cannot grant a viewer of the community it reads" do
        expect(role.can?(:manage_community_viewers, community: community)).to be(false)
      end
    end
  end

  # The page the community viewer is handed out on. An operator of a community
  # reads it there and nowhere else, so the form is where the rule says it is.
  describe "reading a community's operators" do
    subject(:operator) { described_class.operator(community_ids: [community.id]) }

    it "is allowed to an operator of that community" do
      expect(operator.can?(:view_operators, community: community)).to be(true)
    end

    it "is refused to that operator in a community it does not operate" do
      expect(operator.can?(:view_operators, community: other_community)).to be(false)
    end

    it "is allowed to a viewer of that community, and to one of the whole deployment" do
      expect(described_class.community_viewer(viewer_community_ids: [community.id])
                            .can?(:view_operators, community: community)).to be(true)
      expect(described_class.viewer.can?(:view_operators, community: other_community)).to be(true)
    end

    # Reading the page is not reading the roster of every community at once.
    it "does not widen the reads that stayed oversight-only" do
      described_class::OVERSIGHT_READ_ACTIONS.each do |action|
        expect(operator.can?(action, community: community)).to be(false), "#{action} was allowed"
      end
    end
  end

  # Who may hand the community-scoped viewer out: an operator of that community,
  # because it reaches no further than they already reach.
  describe "granting a community viewer" do
    it "is allowed to an operator of that community, with no separate grant" do
      operator = described_class.operator(community_ids: [community.id])

      expect(operator.can?(:manage_community_viewers, community: community)).to be(true)
    end

    it "is refused to that operator in a community it does not operate" do
      operator = described_class.operator(community_ids: [community.id])

      expect(operator.can?(:manage_community_viewers, community: other_community)).to be(false)
      expect(operator.can?(:manage_community_viewers, community: nil)).to be(false)
    end

    it "is allowed to an administrator anywhere" do
      expect(described_class.administrator.can?(:manage_community_viewers, community: other_community)).to be(true)
    end

    # The deployment-wide dimension reads every OTHER community too, so nothing
    # short of an administrator hands it out. The dashboard enforces that with
    # require_admin! rather than an action, so the guarantee here is that no
    # action an operator can hold names it.
    it "shares no action with the deployment-wide grant, which is administrator-only" do
      expect(described_class::SCOPED_GRANT_ACTIONS & described_class::WRITE_ACTIONS).to be_empty
      expect(described_class::SCOPED_GRANT_ACTIONS).not_to include(:manage_viewers)
    end
  end

  # The read scope as ids, for a query to be built from rather than a result
  # set to be filtered afterwards. It exists so a caller cannot forget the
  # filter, so the thing worth holding is that it says exactly what #can? says:
  # a divergence would hand somebody rows the matrix had already refused them.
  describe "#readable_community_ids" do
    it "is nil, meaning every community, for an administrator" do
      expect(described_class.administrator.readable_community_ids).to be_nil
    end

    it "is nil for a deployment-wide viewer, who reads the whole deployment" do
      expect(described_class.viewer.readable_community_ids).to be_nil
    end

    it "names the operated and the viewed communities for everyone else" do
      role = described_class.operator(community_ids: [community.id],
                                      viewer_community_ids: [other_community.id])

      expect(role.readable_community_ids).to contain_exactly(community.id, other_community.id)
    end

    it "answers for the same communities #can? does, over every shape of the role" do
      roles = [
        described_class.administrator,
        described_class.viewer,
        described_class.operator,
        described_class.operator(community_ids: [community.id]),
        described_class.community_viewer(viewer_community_ids: [other_community.id]),
        described_class.community_viewer(viewer_community_ids: [other_community.id],
                                         community_ids: [community.id])
      ]

      roles.each do |role|
        ids = role.readable_community_ids
        [community, other_community].each do |row|
          scoped = ids.nil? || ids.include?(row.id)
          expect(scoped).to eq(role.can?(:view_community, community: row)),
                            "#{role.kind} disagreed about community #{row.id}"
        end
      end
    end
  end
end
