# frozen_string_literal: true

require "sequel"
require_relative "../security/grant_identity"

module Rubotty
  module ControlPlane
    # Who reads ONE community and changes nothing in it: the smaller shape of
    # {DashboardViewers} (same floor+granted union, same idempotence, same
    # request queue) scoped to a single community, sharing
    # {Security::DashboardViewers}'s shipped YAML as the floor since a handle
    # named there reads every community and so this one too. An OPERATOR may
    # grant here since it reaches no further than they already do;
    # deployment-wide grants stay administrator-only. Grants bind to a durable
    # native account id; handles and display names remain labels.
    class CommunityViewers
      # Raised for a request that cannot be carried out (an unknown adapter, a
      # blank handle, a handle the shipped list already covers). The message is
      # printed as-is.
      class Invalid < Rubotty::Error; end

      VIEWERS_TABLE = :community_viewers

      REQUESTS_TABLE = :community_viewer_requests

      AUDIT_SOURCE = "community_viewers"

      # The platforms a handle may be granted on, so a typo cannot become a row
      # nothing will ever match.
      ADAPTERS = PlatformConnections::KNOWN_ADAPTERS

      HANDLE_MAX = 255

      LABEL_MAX = 200

      GRANTED_BY_MAX = 200

      # The outcome of an operation, uniform so a caller branches on +status+
      # without catching exceptions for control flow, matching {OperatorFlow}.
      Result = Struct.new(:status, :request, :viewer, :detail, keyword_init: true) do
        def ok? = %i[created approved denied removed].include?(status)

        def created? = status == :created

        def duplicate? = status == :duplicate

        def approved? = status == :approved

        def denied? = status == :denied

        def forbidden? = status == :forbidden

        def removed? = status == :removed

        def protected? = status == :protected
      end

      # @param models [ControlPlane::Models] bound to the control-plane database
      # @param registry [ControlPlane::Registry, nil] the live-Snapshot holder,
      #   reloaded after a change so a fresh grant is recognised at once
      # @param logger [#info, #warn, nil]
      # @param clock [#call] injectable time source, for deterministic tests
      # @param floor [Security::DashboardViewers] the shipped YAML underneath
      # @param audit [#record, nil] where a grant or a revocation is recorded
      def initialize(models:, registry: nil, logger: nil, clock: -> { Time.now },
                     floor: Security::DashboardViewers.default, audit: nil)
        @models = models
        @registry = registry
        @logger = logger
        @clock = clock
        @floor = floor
        @audit = audit || Core::AuditLog::Null.new
      end

      attr_reader :models, :floor

      # Does this (adapter, handle) read +community_id+, from either source? The
      # floor answers first, so a deployment whose grant table has not arrived
      # yet still recognises everyone the shipped list names.
      #
      # @param community_id [Integer]
      # @param adapter [String, Symbol] the platform the handle is on
      # @param username [String, nil] the public handle, used only by a legacy deployment floor
      # @param native_id [String, nil] the platform id; on Matrix this is the MXID
      def viewer?(community_id:, adapter:, username: nil, native_id: nil)
        return true if @floor.viewer?(adapter: adapter, username: username, native_id: native_id)

        !granted_row(community_id: community_id, adapter: adapter,
                     username: username, native_id: native_id).nil?
      end

      # Every community id this identity reads by grant, for the session a
      # web-login token opens. The floor is deliberately absent: it reads every
      # community, which the deployment-wide dimension already carries, and
      # listing every id here would say the same thing twice.
      def communities_for(adapter:, username: nil, native_id: nil)
        id = Security::GrantIdentity.native_id(adapter: adapter, native_id: native_id, username: username)
        return [] if id.nil?

        Security::GrantIdentity.exact_rows(viewers.where(adapter: adapter.to_s), native_id: id)
                               .map { |row| row[:community_id] }.uniq
      rescue ::Sequel::Error => e
        unavailable(e, "resolve which communities a handle reads")
        []
      end

      # The shipped list's entries as { handle:, kind: } hashes, for display.
      # Never for matching; use {#viewer?}.
      def baked_in = @floor.entries

      # The granted rows for one community, oldest first. Empty when the table
      # is not there yet.
      def granted(community_id:)
        viewers.where(community_id: community_id).order(:id).all
      rescue ::Sequel::Error => e
        unavailable(e, "list the granted viewers")
        []
      end

      # Let a handle read one community; idempotent, so a handle already granted
      # here comes back as its existing row with nothing rewritten. A handle the
      # shipped list already covers is refused, since granting it would write a
      # row that looks removable and is not.
      #
      # @raise [Invalid]
      def grant(community_id:, adapter:, handle:, granted_by:, label: nil, native_id: nil)
        platform = normalise_adapter(adapter)
        key = normalise_handle(handle, adapter: platform)
        actor = normalise_actor(granted_by)
        if @floor.viewer?(adapter: platform, username: key, native_id: native_id)
          raise Invalid, "#{key} already reads every community through the deployment's shipped list."
        end

        bound_id = resolve_grant_identity(community_id: community_id, adapter: platform,
                                          handle: key, native_id: native_id)
        if @floor.viewer?(adapter: platform, username: key, native_id: bound_id)
          raise Invalid, "#{key} already holds this access through the deployment's shipped list."
        end

        existing = existing_grant(community_id, platform, bound_id)
        return existing if existing

        now = @clock.call
        id = insert_viewer(community_id: community_id, platform: platform, key: key,
                           native_id: bound_id, label: label, actor: actor, now: now)
        reload
        record_audit(community_id: community_id, action: "community_viewer_granted",
                     actor: actor, subject: key, adapter: platform, now: now)
        @logger&.info { "community viewer granted: #{platform}:#{key} community=#{community_id} by=#{actor}" }
        viewers.where(id: id).first
      end

      # Take a granted row back.
      #
      # Refused, with status :protected, when the shipped list also names the
      # handle: the delete would read as a revocation while the floor kept
      # handing the same person every community.
      #
      # @return [Result] :removed, :not_found or :protected
      def revoke(community_id:, id:, revoked_by:)
        actor = normalise_actor(revoked_by)
        row = viewer_row(community_id, id)
        return Result.new(status: :not_found) if row.nil?

        if @floor.viewer?(adapter: row[:adapter], username: row[:handle], native_id: row[:native_id])
          return Result.new(status: :protected, viewer: row)
        end

        viewers.where(id: row[:id]).delete
        reload
        record_audit(community_id: community_id, action: "community_viewer_revoked",
                     actor: actor, subject: row[:handle], adapter: row[:adapter])
        @logger&.info { "community viewer revoked: #{row[:adapter]}:#{row[:handle]} by=#{actor}" }
        Result.new(status: :removed, viewer: row)
      rescue ::Sequel::Error => e
        unavailable(e, "revoke a viewer")
        Result.new(status: :not_found)
      end

      # Whether a handle's grant is the shipped list's rather than a row, which
      # is what the page marks as not removable.
      def baked_in?(adapter:, handle:)
        @floor.viewer?(adapter: adapter, username: handle, native_id: handle)
      end

      # Record a pending request to read one community.
      #
      # Idempotent, matching {OperatorFlow#request}: an open request comes back
      # as itself rather than as a second row, and somebody who already reads
      # this community gets :already_viewer and no row at all.
      #
      # @return [Result] :created, :duplicate, :already_viewer or :invalid
      def request(community_id:, adapter:, native_id:, username: nil, display: nil)
        platform = adapter.to_s
        id = native_id.to_s
        return Result.new(status: :invalid, detail: "no requester id") if id.empty?
        id = Security::GrantIdentity.native_id(adapter: platform, native_id: id)
        return Result.new(status: :invalid, detail: "a durable native account id is required") if id.nil?

        if viewer?(community_id: community_id, adapter: platform, username: username, native_id: id)
          return Result.new(status: :already_viewer)
        end

        existing = pending_request(community_id: community_id, adapter: platform, native_id: id)
        return Result.new(status: :duplicate, request: existing) if existing

        now = @clock.call
        row_id = requests.insert(
          community_id: community_id, adapter: platform, requester_native_id: id,
          requester_username: presence(username), requester_display: presence(display),
          state: "pending", requested_at: now
        )
        record_audit(community_id: community_id, action: "community_viewer_requested",
                     actor: presence(username) || id, subject: presence(username) || id,
                     adapter: platform, now: now)
        Result.new(status: :created, request: requests.where(id: row_id).first)
      rescue ::Sequel::UniqueConstraintViolation
        # A concurrent writer won the race. The partial unique index is the
        # authority; fall back to the row it protected.
        Result.new(status: :duplicate,
                   request: pending_request(community_id: community_id, adapter: adapter.to_s,
                                            native_id: native_id.to_s))
      rescue ::Sequel::Error => e
        unavailable(e, "record a viewer request")
        Result.new(status: :invalid, detail: "viewer requests are not available on this deployment yet")
      end

      # The open requests for one community, oldest first.
      def pending(community_id:)
        requests.where(community_id: community_id, state: "pending").order(:id).all
      rescue ::Sequel::Error => e
        unavailable(e, "list the viewer requests")
        []
      end

      # One request in a community by its id, whatever its state. Scoped to the
      # community so an id from elsewhere cannot be decided from here.
      def find_request(community_id:, id:)
        return nil if id.nil?

        requests.where(community_id: community_id, id: id.to_i).first
      rescue ::Sequel::Error => e
        unavailable(e, "read a viewer request")
        nil
      end

      # Grant a pending request; +decided_by+ names who took the decision, and a
      # blank one is refused so a caller that forgot to say who is acting
      # cannot write a grant nobody is accountable for. WHETHER the caller may
      # decide is settled by the route before this is reached: every surface
      # that reaches it is an administrator or an operator of this community.
      #
      # @return [Result] :approved, :forbidden or :not_pending
      def approve(request:, decided_by:)
        actor = presence(decided_by)
        return Result.new(status: :forbidden, request: request) if request.nil? || actor.nil?
        return Result.new(status: :not_pending, request: request) unless request[:state] == "pending"

        handle = request_handle(request)
        raise Invalid, "that request carries no handle to grant." if handle.nil?

        row = grant(community_id: request[:community_id], adapter: request[:adapter], handle: handle,
                    label: request[:requester_display], granted_by: actor, native_id: request[:requester_native_id])
        requests.where(id: request[:id]).update(state: "approved", decided_at: @clock.call, decided_by: actor)
        Result.new(status: :approved,
                   request: find_request(community_id: request[:community_id], id: request[:id]),
                   viewer: row)
      end

      # Refuse a pending request. A denied request does not block a later fresh
      # one: the pending unique index only covers the open state.
      #
      # @return [Result] :denied, :forbidden or :not_pending
      def deny(request:, decided_by:)
        actor = presence(decided_by)
        return Result.new(status: :forbidden, request: request) if request.nil? || actor.nil?
        return Result.new(status: :not_pending, request: request) unless request[:state] == "pending"

        requests.where(id: request[:id]).update(state: "denied", decided_at: @clock.call, decided_by: actor)
        record_audit(community_id: request[:community_id], action: "community_viewer_request_denied",
                     actor: actor, subject: request_handle(request) || request[:requester_native_id],
                     adapter: request[:adapter])
        Result.new(status: :denied,
                   request: find_request(community_id: request[:community_id], id: request[:id]))
      end

      # The human-readable label stored alongside a native account binding:
      # full MXID on Matrix, otherwise the public username or native id. A
      # display name is never used as an account lookup or grant target.
      # Public because a grant made from somewhere other than a request row
      # ({AuthTokens}, redeeming a token) has to reach the same answer.
      def self.handle_for(adapter:, username: nil, native_id: nil)
        if adapter.to_s == "matrix"
          return Security::GrantIdentity.native_id(adapter: adapter, native_id: native_id, username: username)
        end

        [username, native_id].filter_map { |value| Security::DashboardViewers.normalise(value) }.first
      end

      # What this service has recorded in one community, most recent first.
      def audit_trail(community_id:, limit: 50)
        slug = community_slug(community_id)
        return [] if slug.nil?

        @audit.query(community: slug, source: AUDIT_SOURCE, limit: limit)
      rescue StandardError => e
        @logger&.warn { "community viewers: could not read the audit trail: #{e.message}" }
        []
      end

      private

      # Plain datasets, not model classes, so a process running ahead of these
      # tables' migration reads an empty list and falls back to the floor.
      def viewers = @models.db[VIEWERS_TABLE]

      def requests = @models.db[REQUESTS_TABLE]

      def viewer_row(community_id, id)
        return nil if id.nil?

        viewers.where(community_id: community_id, id: id.to_i).first
      end

      # The row already granting this native account id here, or nil. A table that has not
      # arrived yet reads as nil and the insert below raises the honest refusal.
      def existing_grant(community_id, platform, native_id)
        Security::GrantIdentity.exact_rows(
          viewers.where(community_id: community_id, adapter: platform), native_id: native_id
        ).first
      rescue ::Sequel::Error
        nil
      end

      def insert_viewer(community_id:, platform:, key:, native_id:, label:, actor:, now:)
        viewers.insert(
          community_id: community_id, adapter: platform, handle: key, native_id: native_id,
          label: presence(label)&.[](0, LABEL_MAX), granted_at: now, granted_by: actor
        )
      rescue ::Sequel::UniqueConstraintViolation
        existing = existing_grant(community_id, platform, native_id)
        return existing[:id] if existing

        raise Invalid, "the native account id conflicts with this database collation; an exact-identity grant is required."
      rescue ::Sequel::Error => e
        unavailable(e, "grant a viewer")
        raise Invalid, "viewer grants are not available on this deployment yet."
      end

      # The granted row matching an identity in one community, or nil.
      def granted_row(community_id:, adapter:, username:, native_id:)
        id = Security::GrantIdentity.native_id(adapter: adapter, native_id: native_id, username: username)
        return nil if id.nil?

        Security::GrantIdentity.exact_rows(
          viewers.where(community_id: community_id, adapter: adapter.to_s), native_id: id
        ).first
      rescue ::Sequel::Error => e
        unavailable(e, "resolve a viewer")
        nil
      end

      def resolve_grant_identity(community_id:, adapter:, handle:, native_id:)
        Security::GrantIdentity.resolve(models: @models, community_id: community_id,
                                        adapter: adapter, handle: handle, native_id: native_id)
      rescue Security::GrantIdentity::Invalid => e
        raise Invalid, e.message
      end

      # The handle a request should be granted under.
      def request_handle(request)
        self.class.handle_for(adapter: request[:adapter], username: request[:requester_username],
                              native_id: request[:requester_native_id])
      end

      def pending_request(community_id:, adapter:, native_id:)
        Security::GrantIdentity.exact_rows(
          requests.where(community_id: community_id, adapter: adapter, state: "pending"),
          native_id: native_id, column: :requester_native_id
        ).first
      end

      def normalise_adapter(adapter)
        platform = adapter.to_s.strip.downcase
        return platform if ADAPTERS.include?(platform)

        raise Invalid, "#{ADAPTERS.join(", ")} are the platforms a viewer can be named on."
      end

      def normalise_handle(handle, adapter: nil)
        if adapter == "matrix"
          key = presence(handle)
          raise Invalid, "a Matrix grant needs a handle." if key.nil?
          raise Invalid, "a Matrix handle cannot exceed #{HANDLE_MAX} bytes." if key.bytesize > HANDLE_MAX

          return key
        end

        key = Security::DashboardViewers.normalise(handle.to_s.sub(/\A@(?![^:]+:)/, ""))
        raise Invalid, "a viewer needs a handle." if key.nil?

        key[0, HANDLE_MAX]
      end

      def normalise_actor(value)
        actor = presence(value)
        raise Invalid, "a viewer change has to say who made it." if actor.nil?

        actor[0, GRANTED_BY_MAX]
      end

      # The audit log is keyed by slug, so a community with no row writes
      # nothing rather than filing under a blank name.
      def record_audit(community_id:, action:, actor:, subject:, adapter:, now: @clock.call)
        slug = community_slug(community_id)
        return nil if slug.nil?

        @audit.record(community: slug, source: AUDIT_SOURCE, action: action,
                      adapter: adapter, actor: actor, subject: subject, now: now)
      rescue StandardError => e
        @logger&.warn { "community viewers: could not record #{action}: #{e.message}" }
        nil
      end

      def community_slug(community_id)
        @models.community[community_id]&.slug
      rescue ::Sequel::Error
        nil
      end

      # Rebuild the Snapshot so a change is recognised on the very next message.
      # A no-op when no registry is wired, which is every surface but the bot.
      def reload
        @registry&.reload
      rescue StandardError => e
        @logger&.warn { "community viewers: snapshot reload after a change failed: #{e.message}" }
      end

      # The tables arrive with their own migration, so a process running ahead of
      # it reads nothing rather than failing. Logged, since on a migrated
      # deployment this can only mean a real database problem.
      def unavailable(error, doing)
        @logger&.warn { "community viewers: could not #{doing}: #{error.message}" }
      end

      def presence(value)
        return nil if value.nil?

        string = value.to_s.strip
        string.empty? ? nil : string
      end
    end
  end
end
