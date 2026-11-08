# frozen_string_literal: true

require "rubotty/dashboard/action_permissions"

module Rubotty
  module Dashboard
    # The two roles the web panel authorizes against, and the viewer dimension
    # that crosses them: administrator is the root-password session
    # (DASHBOARD_SECRET) with full control, operator is scoped to
    # control-plane +operators+ rows (list-all, read-own, write-own). Viewer
    # is a dimension on the same role: reads consult it, writes stay on the
    # operator rules, so viewer status alone can never widen or authorise a
    # write. It comes in two sizes, deployment-wide (+viewer+) and
    # community-scoped (+viewer_community_ids+), both read-only alike.
    class Role
      ADMINISTRATOR = :administrator
      OPERATOR = :operator

      # The scope of a page about the deployment rather than any one community,
      # passed where a community would go. A read at that scope has to say so:
      # a nil community is an argument that went astray on the way here, and
      # denies rather than answering true for every operator.
      DEPLOYMENT = :deployment

      # Every read an operator may take: nothing here exposes a secret
      # (counts, lifecycle status, redacted audit entries, aggregate
      # analytics). +view_operators+ is included since an operator hands out
      # that community's viewer from the same page; the deployment-wide
      # controls there are gated separately.
      READ_ACTIONS = %i[list_communities view_community view_audit_log view_analytics
                        view_operators].freeze

      # The reads allowed against any community. Only listing is global: an
      # operator has to see that a community exists in order to ask for access
      # to it, and the list carries names and counts, nothing said inside.
      GLOBAL_READ_ACTIONS = %i[list_communities].freeze

      SCOPED_READ_ACTIONS = (READ_ACTIONS - GLOBAL_READ_ACTIONS).freeze

      # The reads an operator never gets and a viewer does: the read half of
      # the administration pages, whose write half stays administrator-only
      # either way. Accounts, API keys and operator login links are absent on
      # purpose since they list credential names and live sign-in links,
      # reconnaissance rather than oversight.
      OVERSIGHT_READ_ACTIONS = %i[view_platforms view_discovered view_rooms
                                  view_scripts view_endpoints view_guests].freeze

      # An oversight read that a grantable write carries with it, since a grant
      # reaching none of the pages it acts on hands over controls nobody can
      # find. Only the Rooms writes need this: every other grant sits behind
      # :view_community, which an operator already holds in the community that
      # scopes it.
      READS_IMPLIED_BY_WRITES = { view_rooms: %i[manage_rooms manage_discovered] }.freeze

      # Empty deliberately. An operator changes nothing until an administrator
      # hands over a specific grant on the permissions page.
      DEFAULT_WRITE_ACTIONS = [].freeze

      # The writes an operator of a community holds by virtue of operating it,
      # without a separate grant. Handing somebody the read of one community
      # reaches no further than the operator handing it over already reaches,
      # which is why an operator there can grant it while the deployment-wide
      # dimension stays administrator-only.
      SCOPED_GRANT_ACTIONS = %i[manage_community_viewers].freeze

      # Every write an administrator can hand over: every grant the
      # permissions page offers, all write-own (allowed only against a
      # community in +community_ids+, denied outright when none scopes it).
      # Anything absent from here can never be granted, staying
      # administrator-only.
      WRITE_ACTIONS = ActionPermissions::ACTIONS.keys.freeze

      attr_reader :kind, :community_ids, :write_actions, :viewer_community_ids

      def self.administrator
        new(kind: ADMINISTRATOR)
      end

      # @param community_ids [Array<Integer>] the communities this operator may act on
      # @param viewer [Boolean] whether this person also reads the whole deployment
      # @param viewer_community_ids [Array<Integer>] the communities this person
      #   reads without operating them
      def self.operator(community_ids: [], write_actions: DEFAULT_WRITE_ACTIONS, viewer: false,
                        viewer_community_ids: [])
        new(kind: OPERATOR, community_ids: community_ids, write_actions: write_actions,
            viewer: viewer, viewer_community_ids: viewer_community_ids)
      end

      # A viewer who operates nothing: every read, no write anywhere. The same
      # object an operator gets, with an empty write scope, because the two are
      # dimensions of one role rather than separate kinds.
      def self.viewer(community_ids: [], write_actions: DEFAULT_WRITE_ACTIONS)
        operator(community_ids: community_ids, write_actions: write_actions, viewer: true)
      end

      # A viewer of named communities and nothing else: those reads, no write
      # anywhere, and no sight of any other community.
      def self.community_viewer(viewer_community_ids:, community_ids: [],
                                write_actions: DEFAULT_WRITE_ACTIONS)
        operator(community_ids: community_ids, write_actions: write_actions,
                 viewer_community_ids: viewer_community_ids)
      end

      def initialize(kind:, community_ids: [], write_actions: DEFAULT_WRITE_ACTIONS, viewer: false,
                     viewer_community_ids: [])
        @kind = kind
        @community_ids = community_ids.to_a.freeze
        @write_actions = write_actions.map(&:to_sym).freeze
        # Strict true, so a stray session value or a JSON round trip that leaves
        # a string behind reads as no viewer status at all.
        @viewer = viewer == true
        @viewer_community_ids = viewer_community_ids.to_a.freeze
      end

      def administrator? = kind == ADMINISTRATOR

      def operator? = kind == OPERATOR

      # Whether this role carries the deployment-wide viewer dimension: reads
      # every community, changes nothing on that account.
      def viewer? = @viewer

      # Whether this role reads +community+ without operating it: the
      # deployment-wide dimension, or a grant naming that one community.
      def views?(community)
        return true if viewer?
        return false if community.nil? || community == DEPLOYMENT

        viewer_community_ids.include?(community.id)
      end

      # Whether this role may take +action+ against +community+, or against
      # {DEPLOYMENT} for a page that is about the whole deployment rather than
      # one community. Required, so a lost community denies rather than passing
      # silently. Strict allow list: anything not named above is denied.
      def can?(action, community:)
        return true if administrator?
        return false unless operator?

        return true if GLOBAL_READ_ACTIONS.include?(action)
        return oversees?(action, community) if OVERSIGHT_READ_ACTIONS.include?(action)
        return readable?(community) if SCOPED_READ_ACTIONS.include?(action)
        return scoped_to?(community) if SCOPED_GRANT_ACTIONS.include?(action)

        writable?(action, community)
      end

      # The communities this role may read, as ids, or nil for every one,
      # SCOPED rather than fetched-then-filtered since a read that fetches
      # first is one forgotten check away from handing over another
      # community's rows, the shape every multi-tenant defect here has taken.
      # Agrees with {#can?}(:view_community) by construction.
      def readable_community_ids
        return nil if administrator? || viewer?

        (community_ids + viewer_community_ids).uniq
      end

      # Whether this role's write scope includes +community+. Nothing is
      # granted at {DEPLOYMENT} scope: every grantable write is write-own.
      def scoped_to?(community)
        return true if administrator?
        return false if community.nil? || community == DEPLOYMENT

        community_ids.include?(community.id)
      end

      private

      # An oversight read: the viewer dimension, or one of the writes
      # {READS_IMPLIED_BY_WRITES} names, held against this same community. The
      # write check is the ordinary one, so this widens no scope of its own.
      def oversees?(action, community)
        return true if views?(community)

        Array(READS_IMPLIED_BY_WRITES[action.to_sym])
          .any? { |write| writable?(write, community) }
      end

      # The read half: a deployment-wide viewer reads every community, a
      # community-scoped one only the communities it was named in. {DEPLOYMENT}
      # is the landing shell, which carries nothing of its own and narrows its
      # rows to {#readable_community_ids}. A nil community is a lost argument
      # and denies, the way {#writable?} already did on the same nil.
      def readable?(community)
        return true if views?(community)
        return true if community == DEPLOYMENT

        scoped_to?(community)
      end

      # The write half, which never consults the viewer dimension: a change is
      # the operator rules or nothing. That is what makes a viewer read-only
      # without a route having to know it exists.
      def writable?(action, community)
        return false unless write_actions.include?(action.to_sym)

        scoped_to?(community)
      end
    end
  end
end
