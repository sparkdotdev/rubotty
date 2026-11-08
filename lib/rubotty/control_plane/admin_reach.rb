# frozen_string_literal: true

require "sequel"
require_relative "../security/grant_identity"

module Rubotty
  module ControlPlane
    # Resolves which community a DM concerns, since a DM itself carries no
    # channel. {#operated} is authoritative, reading only VERIFIED identity
    # links and keyed on account id alone (a handle can change hands);
    # {#requestable} is deliberately generous, may read passively observed
    # sightings, and grants nothing by itself. Handle-only operator rows need
    # an explicit native-id grant before they can authorise anyone. Both DM lanes number
    # their list by slug and read a bare number back on a later message, so list
    # order here must stay stable.
    class AdminReach
      # A community this sender operates, with the operators row that proves it
      # (the approver row an approve/deny needs to hand back to {OperatorFlow}).
      Membership = Struct.new(:community, :operator, keyword_init: true) do
        def id = community.id

        def slug = community.slug.to_s

        # "slug (Name)": how every reply names the community it acted on.
        def label = "#{community.slug} (#{community.name})"
      end

      # How many distinct platform identities one walk will visit: a fuse against
      # a pathological identity graph.
      MAX_IDENTITIES = 32

      # @param operator_flow [OperatorFlow] the control-plane operations service,
      #   taken whole so the account lookup shared with it
      #   ({OperatorFlow#communities_on_account}) stays one implementation.
      # @param notifier [#notify_operators!, nil] retained for API compatibility;
      #   handle presentations no longer create or announce account claims.
      # @param logger [#warn, nil]
      def initialize(operator_flow:, notifier: nil, logger: nil)
        @operator_flow = operator_flow
        @models = operator_flow.models
        @notifier = notifier
        @logger = logger
      end

      # Every community this platform identity operates, ordered by slug; this
      # is the console's authority, so a community absent from this list is
      # one the sender may not act on. Matched on account id alone, so a DM
      # carrying only a handle resolves to nothing.
      #
      # @return [Array<Membership>]
      def operated(adapter:, native_id: nil, username: nil)
        keys = identities(adapter: adapter, native_id: native_id, username: username, strict: true)
        by_community = {}
        linked_people(keys, strict: true).each do |person|
          @models.operator.where(person_id: person.id).order(:id).all.each do |operator|
            community = @models.community[operator.community_id]
            next if community.nil?

            by_community[community.id] ||= Membership.new(community: community, operator: operator)
          end
        end
        # Rows first, so a real one always beats the stand-in below.
        add_floor_communities(by_community, adapter: adapter, native_id: native_id, username: username)
        sort_communities(by_community.values) { |membership| membership.community }
      end

      # The communities an operator REQUEST from this identity could be about:
      # the ones it has been SEEN in, plus the ones served on the account the DM
      # arrived on. Union rather than intersection, since a request grants
      # nothing and the caller decides between candidates, never this method.
      #
      # @return [Array<Models::Community>]
      def requestable(adapter:, account: nil, native_id: nil, username: nil)
        keys = identities(adapter: adapter, native_id: native_id, username: username)
        found = observed_communities(keys)
        found += @operator_flow.communities_on_account(adapter: adapter, account: account) unless account.nil?
        sort_communities(found.uniq(&:id)) { |community| community }
      end

      # The identity closure: every (adapter, native id, handle) the directory
      # says is the same human as the one that sent this DM, starting with the
      # sender's own. Public because both questions above are answered through it.
      #
      # @param strict [Boolean] follow only the links proved by an account id,
      #   which is what {#operated} asks for
      # @return [Array<Hash>] { adapter:, native_id:, username: }
      def identities(adapter:, native_id: nil, username: nil, strict: false)
        id = if strict
               Security::GrantIdentity.native_id(adapter: adapter, native_id: native_id)
             else
               presence(native_id)
             end
        seed = { adapter: adapter.to_s, native_id: id, username: normalise_handle(username) }
        return [] if seed[:adapter].empty? || (seed[:native_id].nil? && seed[:username].nil?)
        return [] if strict && seed[:native_id].nil?

        walk(seed, strict: strict)
      rescue Sequel::Error => e
        @logger&.warn { "admin reach: could not resolve an identity: #{e.class}: #{e.message}" }
        []
      end

      # Retained for callers that used the old bootstrap API. A presentation
      # cannot establish a privileged identity link; grant it explicitly instead.
      def claim(adapter:, native_id: nil, username: nil)
        []
      end

      private

      # The deployment-configured owner floor grants every action in every room of every
      # community and writes no operators row, so a community where it is the
      # only grant was invisible here: missing from the console's "which one?"
      # list, and unsearchable when a reply to an alert needed the community
      # worked out from the code in it. {OperatorFlow#resolve_operator} has
      # always asked the floor first per community; this is the same question
      # asked across all of them.
      def add_floor_communities(by_community, adapter:, native_id:, username:)
        return by_community unless floor_owner?(adapter: adapter, native_id: native_id, username: username)

        @models.community.order(:slug).all.each do |community|
          by_community[community.id] ||= Membership.new(
            community: community,
            operator: @operator_flow.resolve_operator(
              community_id: community.id, adapter: adapter, native_id: native_id, username: username
            )
          )
        end
        by_community
      end

      def floor_owner?(adapter:, native_id:, username:)
        Security::ProtectedOperators.default.owner?(
          adapter: adapter, username: username, native_id: native_id
        )
      end

      # Breadth-first over the identity graph, bounded by {MAX_IDENTITIES}; the
      # bound plus the visited set guarantee termination. +strict+ travels with
      # the walk, since a handle picked up as somebody's sibling would otherwise
      # carry a DM into a community the sender proved nothing in.
      def walk(seed, strict: false)
        found = { key_of(seed) => seed }
        frontier = [seed]
        until frontier.empty? || found.size >= MAX_IDENTITIES
          probe = frontier.shift
          identity_rows(probe, strict: strict).each do |row|
            siblings(row.person_id).each do |sibling|
              key = key_of(sibling)
              next if found.key?(key)

              found[key] = sibling
              frontier << sibling
            end
          end
        end
        found.values
      end

      # The +person_identities+ rows for one identity: generously, that is the
      # native id OR the handle on that adapter, since the directory holds
      # id-bearing rows and handle-only rows for the same human and either is
      # enough to NAME them. Strictly, it is the native id alone, since only
      # the id is something the platform proved.
      def identity_rows(identity, strict: false)
        if strict
          id = Security::GrantIdentity.native_id(adapter: identity[:adapter], native_id: identity[:native_id])
          return [] if id.nil?

          return Security::GrantIdentity.exact_rows(
            @models.person_identity.where(adapter: identity[:adapter]).order(:id), native_id: id
          )
        end

        terms = []
        id = identity[:native_id]
        terms << { native_id: id } unless id.nil?
        terms << { username: identity[:username] } unless strict || identity[:username].nil?
        return [] if terms.empty?

        @models.person_identity
               .where(adapter: identity[:adapter])
               .where(terms.map { |term| Sequel[term] }.inject { |a, b| Sequel.|(a, b) })
               .order(:id).all
      end

      # The other platform identities one person carries. A row with neither an id
      # nor a handle is skipped rather than becoming a wildcard that matches every
      # row on its adapter.
      def siblings(person_id)
        @models.person_identity.where(person_id: person_id).order(:id).all.filter_map do |row|
          entry = {
            adapter: row.adapter.to_s, native_id: presence(row.native_id),
            username: normalise_handle(row.username)
          }
          entry if entry[:native_id] || entry[:username]
        end
      end

      # Every person row carrying any identity in the closure, deduplicated. The
      # person rows are community-scoped, so this is already "the same human, in
      # each community that knows them".
      def linked_people(keys, strict: false)
        people = {}
        keys.each do |identity|
          identity_rows(identity, strict: strict).each do |row|
            person = @models.person[row.person_id]
            people[person.id] ||= person if person
          end
        end
        people.values
      end

      # The communities the passively-observed directory has seen any of these
      # identities in. Non-authoritative, which is why only {#requestable} reads it.
      def observed_communities(keys)
        ids = keys.flat_map do |identity|
          scope = @models.observed_identity.where(adapter: identity[:adapter])
          scope = if identity[:native_id]
                    scope.where(native_id: identity[:native_id])
                  else
                    scope.where(username: identity[:username])
                  end
          scope.select_map(:community_id)
        end
        ids.uniq.filter_map { |community_id| @models.community[community_id] }
      end

      # By slug, then id: a stable order, because both lanes number the list and
      # read a number back on a LATER message.
      def sort_communities(rows)
        rows.sort_by do |row|
          community = yield(row)
          [community.slug.to_s, community.id]
        end
      end

      def key_of(identity)
        "#{identity[:adapter]}\x00#{identity[:native_id]}\x00#{identity[:username]}"
      end

      def normalise_handle(value)
        handle = presence(value)
        handle&.sub(/\A@/, "")&.downcase
      end

      def presence(value)
        return nil if value.nil?

        string = value.to_s.strip
        string.empty? ? nil : string
      end
    end
  end
end
