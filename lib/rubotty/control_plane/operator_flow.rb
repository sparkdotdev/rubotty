# frozen_string_literal: true

require "sequel"
require "json"
require_relative "../security/grant_identity"

module Rubotty
  module ControlPlane
    # Operator request and approval flow, as control-plane operations shared by
    # the chat commands and the dashboard, so nothing here knows about adapters.
    # A change that affects who may act atomically swaps the Snapshot through
    # {Registry}; the seed promotes the configured operator on first projection
    # from YAML, so a brand-new community always has one who can approve the next.
    class OperatorFlow
      # The outcome of an operation, uniform so a caller branches on +status+
      # without catching exceptions for control flow. +request+/+operator+ carry
      # the affected rows; +communities+ carries the DM disambiguation candidates.
      Result = Struct.new(:status, :request, :operator, :communities, :detail, keyword_init: true) do
        # A request was freshly created, or a grant/denial went through.
        def ok? = %i[created approved denied removed].include?(status)

        def created? = status == :created

        def duplicate? = status == :duplicate

        def approved? = status == :approved

        def denied? = status == :denied

        def forbidden? = status == :forbidden

        def removed? = status == :removed

        def protected? = status == :protected
      end

      # A stand-in operators row, so a floor owner with no DB row still
      # satisfies {#approve} and {#deny}. +person_id+ is nil: there is no
      # person behind it.
      FloorOperator = Struct.new(:id, :community_id, :person_id)

      # @param models [ControlPlane::Models] bound to the control-plane database
      # @param registry [ControlPlane::Registry, nil] the live-Snapshot holder;
      #   a grant reloads it so the new operator is recognised at once. Nil in a
      #   pure-data test that asserts on rows without a running snapshot.
      # @param logger [#info, #warn, nil]
      # @param clock [#call] injectable time source, for deterministic tests
      def initialize(models:, registry: nil, logger: nil, clock: -> { Time.now })
        @models = models
        @registry = registry
        @logger = logger
        @clock = clock
      end

      attr_reader :models

      # Record a pending request to become an operator of +community_id+;
      # idempotent, so a person with an OPEN request for this community gets
      # that same request back (status :duplicate) rather than a second row.
      # Someone already an operator gets :already_operator and no row.
      #
      # @return [Result] :created, :duplicate or :already_operator
      def request(community_id:, adapter:, native_id:, username: nil, display: nil)
        adapter = adapter.to_s
        native_id = native_id.to_s
        return Result.new(status: :invalid, detail: "no requester id") if native_id.empty?
        native_id = Security::GrantIdentity.native_id(adapter: adapter, native_id: native_id)
        return Result.new(status: :invalid, detail: "a durable native account id is required") if native_id.nil?

        if Security::ProtectedOperators.default.owner?(adapter: adapter, username: username, native_id: native_id)
          return Result.new(status: :already_operator)
        end

        if resolve_operator(community_id: community_id, adapter: adapter, native_id: native_id, username: username)
          return Result.new(status: :already_operator)
        end

        existing = pending_request(community_id: community_id, adapter: adapter, native_id: native_id)
        return Result.new(status: :duplicate, request: refresh_requester(existing, username, display)) if existing

        row = @models.operator_request.create(
          community_id: community_id, adapter: adapter,
          requester_native_id: native_id, requester_username: normalise_handle(username),
          requester_display: presence(display), state: "pending", requested_at: @clock.call
        )
        Result.new(status: :created, request: row)
      rescue Sequel::UniqueConstraintViolation
        # A concurrent writer won the race. The partial unique index is the
        # authority; fall back to the row it protected, so a double-tap is a
        # duplicate, never an error.
        again = pending_request(community_id: community_id, adapter: adapter, native_id: native_id)
        Result.new(status: :duplicate, request: again)
      end

      # Resolve which community a DM to the shared bot is about, then request,
      # using ONLY the account the DM arrived on; kept for a caller with nothing
      # else to go on, {ControlLane} now resolves this through {AdminReach}
      # instead. One community on that (adapter, account) requests unambiguously,
      # several come back as :ambiguous for the caller to render.
      #
      # @return [Result] the {#request} result for one community, or :ambiguous /
      #   :no_community
      def request_from_dm(adapter:, account:, native_id:, username: nil, display: nil)
        candidates = communities_on_account(adapter: adapter, account: account)
        case candidates.size
        when 0
          Result.new(status: :no_community)
        when 1
          result = request(
            community_id: candidates.first.id, adapter: adapter,
            native_id: native_id, username: username, display: display
          )
          Result.new(status: result.status, request: result.request, communities: candidates)
        else
          Result.new(status: :ambiguous, communities: candidates)
        end
      end

      # Grant a pending request; +approver+ MUST be an operators row or a
      # {FloorOperator}, and a nil approver is refused, which is how "only
      # existing operators can approve" is enforced here too. The Snapshot is
      # rebuilt so the grant is recognised live.
      #
      # @param request [Models::OperatorRequest]
      # @param approver [Models::Operator, FloorOperator, nil]
      # @return [Result] :approved, :forbidden or :not_pending
      def approve(request:, approver:)
        return Result.new(status: :forbidden, request: request) if approver.nil?
        return Result.new(status: :forbidden, request: request) unless approver.community_id == request.community_id
        return Result.new(status: :not_pending, request: request) unless request.state == "pending"
        unless Security::GrantIdentity.native_id(adapter: request.adapter, native_id: request.requester_native_id)
          return Result.new(status: :invalid, request: request, detail: "a durable native account id is required")
        end

        operator = nil
        @models.db.transaction do
          person = find_or_create_person(request)
          link_identity(person, request)
          label = granted_by_label(approver)
          operator = ensure_operator(person: person, community_id: request.community_id, granted_by: label)
          request.update(state: "approved", decided_at: @clock.call, decided_by: label)
        end
        reload
        log_grant(request, operator, approver)
        Result.new(status: :approved, request: request, operator: operator)
      end

      # Refuse a pending request. A denied request does not block a later fresh
      # one: the pending unique index only covers the open state.
      #
      # @return [Result] :denied, :forbidden or :not_pending
      def deny(request:, approver:)
        return Result.new(status: :forbidden, request: request) if approver.nil?
        return Result.new(status: :forbidden, request: request) unless approver.community_id == request.community_id
        return Result.new(status: :not_pending, request: request) unless request.state == "pending"

        request.update(state: "denied", decided_at: @clock.call, decided_by: granted_by_label(approver))
        Result.new(status: :denied, request: request)
      end

      # Promote a platform identity to operator of a community with no request
      # row in between, for a caller that has already established the grant is
      # theirs to make (a redeemed token carries the decision that was taken
      # when it was minted). Idempotent: somebody already promoted keeps the
      # row and the scope they have.
      #
      # @param granted_by [String] what the operators row records as the source
      # @return [Models::Operator]
      def promote(community_id:, adapter:, native_id:, granted_by:, username: nil, display: nil)
        native_id = Security::GrantIdentity.native_id(adapter: adapter, native_id: native_id)
        raise Security::GrantIdentity::Invalid, "a durable native account id is required" if native_id.nil?

        operator = nil
        @models.db.transaction do
          person = find_or_create_person_for(
            community_id: community_id, adapter: adapter.to_s, native_id: native_id.to_s,
            username: username, display: display
          )
          link_identity_for(person, adapter: adapter.to_s, native_id: native_id.to_s, username: username)
          operator = ensure_operator(person: person, community_id: community_id, granted_by: granted_by)
        end
        reload
        @logger&.info { "operator promoted: community=#{community_id} operator=#{operator&.id} by=#{granted_by}" }
        operator
      end

      # Revoke an operator's DB row: a single-row delete, exactly what separating
      # "person" from "operator" was designed for.
      #
      # Refused, with status :protected, when the person behind it also holds an
      # identity the deployment-configured "always operator" floor protects: the delete would
      # look like a revocation while the floor still grants owner-level access.
      #
      # @return [Result] :removed, :not_found or :protected
      def remove(community_id:, id:)
        operator = @models.operator.where(community_id: community_id, id: id.to_i).first
        return Result.new(status: :not_found) if operator.nil?
        return Result.new(status: :protected, operator: operator) if baked_in_operator?(operator)

        operator.destroy
        reload
        Result.new(status: :removed, operator: operator)
      end

      # The operator behind this platform identity in this community, or nil.
      # The deployment-configured owner floor is asked first, at the top, the same way
      # {ControlPlane::ChannelDiscovery#operator_for?} asks it, so a deployment
      # whose operators are all baked in never has to reach the DB to be
      # recognised. Falling through that, it goes identity -> person ->
      # operator row using the durable native id. A handle alone cannot prove
      # an account, so anybody carrying only a public username fails closed.
      def resolve_operator(community_id:, adapter:, native_id: nil, username: nil)
        if Security::ProtectedOperators.default.owner?(adapter: adapter, username: username, native_id: native_id)
          return floor_operator(community_id: community_id, adapter: adapter, native_id: native_id,
                                username: username)
        end

        native_id = Security::GrantIdentity.native_id(adapter: adapter, native_id: native_id, username: username)
        return nil if native_id.nil?

        person = find_person(
          community_id: community_id, adapter: adapter.to_s,
          native_id: native_id, username: username
        )
        return nil if person.nil?

        @models.operator.where(community_id: community_id, person_id: person.id).first
      end

      # The open requests for a community, oldest first.
      def pending(community_id:)
        @models.operator_request.where(community_id: community_id, state: "pending").order(:id).all
      end

      # A single request in a community by its id, whatever its state.
      def find_request(community_id:, id:)
        return nil if id.nil?

        @models.operator_request.where(community_id: community_id, id: id.to_i).first
      end

      # The operator rows of a community, so a caller can notify them. The
      # notification medium is the caller's concern.
      def operators_for(community_id:)
        @models.operator.where(community_id: community_id).order(:id).all
      end

      # The communities served by a shared bot on this (adapter, account): the
      # distinct owners of a channel keyed to it. Used to resolve a DM's target
      # community and, for the dashboard, to list a bot's tenants.
      def communities_on_account(adapter:, account:)
        ids = @models.channel.where(adapter: adapter.to_s, account: account.to_s).select_map(:community_id).uniq
        ids.filter_map { |cid| @models.community[cid] }
      end

      private

      # The floor owner as a {FloorOperator}, labelled by whichever value
      # settled the match so {#granted_by_label} has something to show.
      def floor_operator(community_id:, adapter:, native_id:, username:)
        label = if adapter.to_s == "matrix"
                  Security::GrantIdentity.native_id(adapter: adapter, native_id: native_id, username: username)
                else
                  Security::HandleFloor.normalise(username) || Security::HandleFloor.normalise(native_id)
                end
        FloorOperator.new("floor:#{adapter}:#{label}", community_id, nil)
      end

      # The person behind a request: an existing one matched by the requester's
      # identity or handle, or a new person named for them. Names default to the
      # display name, then the handle, then the bare id.
      def find_or_create_person(request)
        find_or_create_person_for(
          community_id: request.community_id, adapter: request.adapter,
          native_id: request.requester_native_id, username: request.requester_username,
          display: request.requester_display
        )
      end

      # The same, addressed by the fields themselves rather than by a request
      # row, so {#promote} reaches it without inventing one.
      def find_or_create_person_for(community_id:, adapter:, native_id:, username: nil, display: nil)
        person = find_person(
          community_id: community_id, adapter: adapter, native_id: native_id, username: username
        )
        name = presence(display) || presence(username) || native_id.to_s
        now = @clock.call
        if person
          person.update(updated_at: now)
          person
        else
          @models.person.create(community_id: community_id, name: name, created_at: now, updated_at: now)
        end
      end

      # Ensure a person_identity row exists for the requester's platform account,
      # without duplicating one. A person may already carry this identity; if so,
      # backfill the handle when the existing row lacks it.
      def link_identity(person, request)
        link_identity_for(person, adapter: request.adapter, native_id: request.requester_native_id,
                          username: request.requester_username)
      end

      # The same, addressed by the fields themselves, for {#promote}.
      def link_identity_for(person, adapter:, native_id:, username: nil)
        platform = adapter.to_s
        id = native_id.to_s
        handle = normalise_handle(username)

        existing = Security::GrantIdentity.exact_rows(
          @models.person_identity.where(person_id: person.id, adapter: platform), native_id: id
        ).first
        if existing
          existing.update(username: handle) if existing.username.to_s.empty? && !handle.nil?
          return existing
        end

        @models.person_identity.create(
          person_id: person.id, community_id: person.community_id, adapter: platform, native_id: id,
          username: handle, created_at: @clock.call
        )
      end

      # Find or create the operators row promoting this person in this community.
      # A person already promoted keeps their existing scope; a fresh grant is
      # community-wide, the same default the seed writes.
      def ensure_operator(person:, community_id:, granted_by:)
        existing = @models.operator.where(community_id: community_id, person_id: person.id).first
        return existing if existing

        @models.operator.create(
          community_id: community_id, person_id: person.id,
          actions: JSON.generate("all"), scope: JSON.generate("all"),
          granted_at: @clock.call, granted_by: granted_by
        )
      end

      def granted_by_label(approver)
        return "protected-operator:#{approver.id}" if approver.is_a?(FloorOperator)

        person = @models.person[approver.person_id]
        presence(person&.name) || "operator:#{approver.id}"
      end

      # Does this operator row's person also hold a deployment-configured protected identity?
      # Checked against every platform identity the person carries, since a person
      # can be linked on several adapters.
      def baked_in_operator?(operator)
        identities = @models.person_identity.where(person_id: operator.person_id).all.map do |identity|
          { adapter: identity.adapter, username: identity.username, native_id: identity.native_id }
        end
        Security::ProtectedOperators.default.protects_any?(identities)
      end

      # A supplied native id is authoritative. A renamed or recycled username
      # must never attach another account to an existing person's privileges.
      def find_person(community_id:, adapter:, native_id: nil, username: nil)
        adapter = adapter.to_s
        native_id = presence(native_id)
        handle = normalise_handle(username)

        if native_id
          return person_by_identity(community_id, adapter: adapter, native_id: native_id)
        end
        return nil if handle.nil?

        person_by_identity(community_id, adapter: adapter, username: handle)
      end

      def person_by_identity(community_id, adapter:, native_id: nil, username: nil)
        scope = @models.person_identity.where(adapter: adapter)
        scope = scope.where(username: username) unless username.nil?
        identities = if native_id.nil?
                       scope.order(:id).all
                     else
                       Security::GrantIdentity.exact_rows(scope.order(:id), native_id: native_id)
                     end
        identities.each do |identity|
          person = @models.person[identity.person_id]
          return person if person && person.community_id == community_id
        end
        nil
      end

      def pending_request(community_id:, adapter:, native_id:)
        Security::GrantIdentity.exact_rows(
          @models.operator_request.where(community_id: community_id, adapter: adapter.to_s, state: "pending"),
          native_id: native_id.to_s, column: :requester_native_id
        ).first
      end

      # Keep a duplicate request's recorded handle and display name current. Never
      # fails the request over a cosmetic update.
      def refresh_requester(request, username, display)
        return request if request.nil?

        changes = {}
        handle = normalise_handle(username)
        changes[:requester_username] = handle if handle && handle != request.requester_username
        disp = presence(display)
        changes[:requester_display] = disp if disp && disp != request.requester_display
        request.update(changes) unless changes.empty?
        request
      rescue Sequel::Error => e
        @logger&.debug { "operator request: could not refresh requester details: #{e.message}" }
        request
      end

      # Rebuild the Snapshot and swap it atomically, so a just-granted operator is
      # recognised on the very next message. A no-op when no registry is wired.
      def reload
        @registry&.reload
      rescue StandardError => e
        # The rows are committed; a failed reload only delays live recognition,
        # never loses the grant.
        @logger&.warn { "operator flow: snapshot reload after a grant failed: #{e.message}" }
      end

      def log_grant(request, operator, approver)
        @logger&.info do
          "operator granted: request=#{request.id} operator=#{operator&.id} " \
            "person=#{operator&.person_id} community=#{request.community_id} by=#{approver.id}"
        end
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
