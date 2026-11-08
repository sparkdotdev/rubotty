# frozen_string_literal: true

require "sequel"
require_relative "../security/grant_identity"

module Rubotty
  module ControlPlane
    # Who holds the dashboard's viewer dimension: reads every community, changes
    # nothing. Resolution is the UNION of two sources, matching
    # {ProtectedOperators}'s arrangement: the shipped {Security::DashboardViewers}
    # YAML is the FLOOR (never revocable here), and granted rows sit on top. Only
    # an administrator grants, revokes, approves or denies, enforced at both
    # surfaces, since community-level viewer grants would leak oversight of every
    # other community. Grants bind to a durable platform native id; handles and display names
    # remain labels. Matrix requires a full MXID.
    class DashboardViewers
      # Raised for a request that cannot be carried out (an unknown adapter, a
      # blank handle, a handle the shipped list already covers). The message is
      # printed as-is.
      class Invalid < Rubotty::Error; end

      VIEWERS_TABLE = :dashboard_viewers

      REQUESTS_TABLE = :dashboard_viewer_requests

      # The audit log is keyed by community and a viewer belongs to none of them,
      # so every entry this service writes lands under one deployment-wide name.
      # Parenthesised, since no community slug can look like this.
      AUDIT_SCOPE = "(deployment)"

      AUDIT_SOURCE = "dashboard_viewers"

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

      # Does this (adapter, handle) hold viewer status, from either source?
      # The floor answers first, so a deployment whose grant table has not
      # arrived yet still recognises everyone the shipped list names.
      #
      # @param adapter [String, Symbol] the platform the handle is on
      # @param username [String, nil] the public handle, used only by a legacy deployment floor
      # @param native_id [String, nil] the platform id; on Matrix this is the MXID
      def viewer?(adapter:, username: nil, native_id: nil)
        return true if @floor.viewer?(adapter: adapter, username: username, native_id: native_id)

        !granted_row(adapter: adapter, username: username, native_id: native_id).nil?
      end

      # The shipped list's entries as { handle:, kind: } hashes, for display.
      # Never for matching; use {#viewer?}.
      def baked_in = @floor.entries

      # Every granted row, oldest first. Empty when the table is not there yet.
      def granted
        viewers.order(:id).all
      rescue ::Sequel::Error => e
        unavailable(e, "list the granted viewers")
        []
      end

      # Hands the viewer dimension to a handle, idempotently: a handle already
      # granted comes back as its existing row, nothing rewritten or audited
      # again. A handle the shipped list already covers is refused, since
      # granting it would write a row that looks removable and is not.
      #
      # @raise [Invalid]
      def grant(adapter:, handle:, granted_by:, label: nil, native_id: nil)
        platform = normalise_adapter(adapter)
        key = normalise_handle(handle, adapter: platform)
        actor = normalise_actor(granted_by)
        if @floor.viewer?(adapter: platform, username: key, native_id: native_id)
          raise Invalid, "#{key} already reads every community through the deployment's shipped list."
        end

        bound_id = resolve_grant_identity(adapter: platform, handle: key, native_id: native_id)
        if @floor.viewer?(adapter: platform, username: key, native_id: bound_id)
          raise Invalid, "#{key} already holds this access through the deployment's shipped list."
        end

        existing = existing_grant(platform, bound_id)
        return existing if existing

        now = @clock.call
        id = insert_viewer(platform: platform, key: key, native_id: bound_id, label: label, actor: actor, now: now)
        reload
        record_audit(action: "viewer_granted", actor: actor, subject: key, adapter: platform, now: now)
        @logger&.info { "dashboard viewer granted: #{platform}:#{key} by=#{actor}" }
        viewers.where(id: id).first
      end

      # Take a granted row back.
      #
      # Refused, with status :protected, when the shipped list also names the
      # handle: the delete would read as a revocation while the floor kept
      # handing the same person every community.
      #
      # @return [Result] :removed, :not_found or :protected
      def revoke(id:, revoked_by:)
        actor = normalise_actor(revoked_by)
        row = viewer_row(id)
        return Result.new(status: :not_found) if row.nil?

        if @floor.viewer?(adapter: row[:adapter], username: row[:handle], native_id: row[:native_id])
          return Result.new(status: :protected, viewer: row)
        end

        viewers.where(id: row[:id]).delete
        reload
        record_audit(action: "viewer_revoked", actor: actor, subject: row[:handle], adapter: row[:adapter])
        @logger&.info { "dashboard viewer revoked: #{row[:adapter]}:#{row[:handle]} by=#{actor}" }
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

      # Record a pending request to hold the viewer dimension.
      #
      # Idempotent, matching {OperatorFlow#request}: an open request comes back
      # as itself rather than as a second row, and somebody who already reads
      # every community gets :already_viewer and no row at all.
      #
      # @return [Result] :created, :duplicate, :already_viewer or :invalid
      def request(adapter:, native_id:, username: nil, display: nil)
        platform = adapter.to_s
        id = native_id.to_s
        return Result.new(status: :invalid, detail: "no requester id") if id.empty?
        id = Security::GrantIdentity.native_id(adapter: platform, native_id: id)
        return Result.new(status: :invalid, detail: "a durable native account id is required") if id.nil?

        if viewer?(adapter: platform, username: username, native_id: id)
          return Result.new(status: :already_viewer)
        end

        existing = pending_request(adapter: platform, native_id: id)
        return Result.new(status: :duplicate, request: existing) if existing

        now = @clock.call
        row_id = requests.insert(
          adapter: platform, requester_native_id: id,
          requester_username: presence(username), requester_display: presence(display),
          state: "pending", requested_at: now
        )
        record_audit(action: "viewer_requested", actor: presence(username) || id,
                     subject: presence(username) || id, adapter: platform, now: now)
        Result.new(status: :created, request: requests.where(id: row_id).first)
      rescue ::Sequel::UniqueConstraintViolation
        # A concurrent writer won the race. The partial unique index is the
        # authority; fall back to the row it protected.
        Result.new(status: :duplicate, request: pending_request(adapter: adapter.to_s, native_id: native_id.to_s))
      rescue ::Sequel::Error => e
        unavailable(e, "record a viewer request")
        Result.new(status: :invalid, detail: "viewer requests are not available on this deployment yet")
      end

      # The open requests, oldest first.
      def pending
        requests.where(state: "pending").order(:id).all
      rescue ::Sequel::Error => e
        unavailable(e, "list the viewer requests")
        []
      end

      # One request by its id, whatever its state.
      def find_request(id:)
        return nil if id.nil?

        requests.where(id: id.to_i).first
      rescue ::Sequel::Error => e
        unavailable(e, "read a viewer request")
        nil
      end

      # Grants a pending request; +decided_by+ names the administrator and a blank
      # one is refused, so a grant is never unaccountable. Whether the caller IS
      # an administrator is settled by the route before this is reached, not here.
      #
      # @return [Result] :approved, :forbidden or :not_pending
      def approve(request:, decided_by:)
        actor = presence(decided_by)
        return Result.new(status: :forbidden, request: request) if request.nil? || actor.nil?
        return Result.new(status: :not_pending, request: request) unless request[:state] == "pending"

        handle = request_handle(request)
        raise Invalid, "that request carries no handle to grant." if handle.nil?

        row = grant(adapter: request[:adapter], handle: handle,
                    label: request[:requester_display], granted_by: actor, native_id: request[:requester_native_id])
        requests.where(id: request[:id]).update(state: "approved", decided_at: @clock.call, decided_by: actor)
        Result.new(status: :approved, request: find_request(id: request[:id]), viewer: row)
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
        record_audit(action: "viewer_request_denied", actor: actor,
                     subject: request_handle(request) || request[:requester_native_id],
                     adapter: request[:adapter])
        Result.new(status: :denied, request: find_request(id: request[:id]))
      end

      # What this service has recorded, most recent first, for the page that
      # hands the dimension out. A deployment-wide role is exactly the one worth
      # being able to account for later, and its trail lives under one name
      # rather than in any community's log.
      def audit_trail(limit: 50)
        @audit.query(community: AUDIT_SCOPE, source: AUDIT_SOURCE, limit: limit)
      rescue StandardError => e
        @logger&.warn { "dashboard viewers: could not read the audit trail: #{e.message}" }
        []
      end

      private

      # Plain datasets, not model classes, so a process running ahead of these
      # tables' migration reads an empty list and falls back to the floor.
      def viewers = @models.db[VIEWERS_TABLE]

      def requests = @models.db[REQUESTS_TABLE]

      def viewer_row(id)
        return nil if id.nil?

        viewers.where(id: id.to_i).first
      end

      # The row already granting this native account id, or nil. A table that has not
      # arrived yet reads as nil and the insert below raises the honest refusal.
      def existing_grant(platform, native_id)
        Security::GrantIdentity.exact_rows(viewers.where(adapter: platform), native_id: native_id).first
      rescue ::Sequel::Error
        nil
      end

      def insert_viewer(platform:, key:, native_id:, label:, actor:, now:)
        viewers.insert(
          adapter: platform, handle: key, native_id: native_id, label: presence(label)&.[](0, LABEL_MAX),
          granted_at: now, granted_by: actor
        )
      rescue ::Sequel::UniqueConstraintViolation
        existing = existing_grant(platform, native_id)
        return existing[:id] if existing

        raise Invalid, "the native account id conflicts with this database collation; an exact-identity grant is required."
      rescue ::Sequel::Error => e
        unavailable(e, "grant a viewer")
        raise Invalid, "viewer grants are not available on this deployment yet."
      end

      # The granted row matching the proven native account, or nil. A full
      # Matrix MXID may be carried as the username when no native id is given.
      def granted_row(adapter:, username:, native_id:)
        id = Security::GrantIdentity.native_id(adapter: adapter, native_id: native_id, username: username)
        return nil if id.nil?

        Security::GrantIdentity.exact_rows(viewers.where(adapter: adapter.to_s), native_id: id).first
      rescue ::Sequel::Error => e
        unavailable(e, "resolve an viewer")
        nil
      end

      def request_handle(request)
        if request[:adapter].to_s == "matrix"
          return Security::GrantIdentity.native_id(adapter: "matrix", native_id: request[:requester_native_id],
                                                    username: request[:requester_username])
        end

        Security::DashboardViewers.normalise(presence(request[:requester_username]) || presence(request[:requester_native_id]))
      end

      def pending_request(adapter:, native_id:)
        Security::GrantIdentity.exact_rows(requests.where(adapter: adapter, state: "pending"),
                                           native_id: native_id, column: :requester_native_id).first
      end

      def resolve_grant_identity(adapter:, handle:, native_id:)
        Security::GrantIdentity.resolve(models: @models, adapter: adapter, handle: handle,
                                        native_id: native_id)
      rescue Security::GrantIdentity::Invalid => e
        raise Invalid, e.message
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

      # A lost audit line never fails the change it describes, matching every
      # other caller of the log.
      def record_audit(action:, actor:, subject:, adapter:, now: @clock.call)
        @audit.record(community: AUDIT_SCOPE, source: AUDIT_SOURCE, action: action,
                      adapter: adapter, actor: actor, subject: subject, now: now)
      rescue StandardError => e
        @logger&.warn { "dashboard viewers: could not record #{action}: #{e.message}" }
        nil
      end

      # Rebuild the Snapshot so a change is recognised on the very next message.
      # A no-op when no registry is wired, which is every surface but the bot.
      def reload
        @registry&.reload
      rescue StandardError => e
        @logger&.warn { "dashboard viewers: snapshot reload after a change failed: #{e.message}" }
      end

      # The tables arrive with their own migration, so a process running ahead of
      # it reads nothing rather than failing. Logged, since on a migrated
      # deployment this can only mean a real database problem.
      def unavailable(error, doing)
        @logger&.warn { "dashboard viewers: could not #{doing}: #{error.message}" }
      end

      def presence(value)
        return nil if value.nil?

        string = value.to_s.strip
        string.empty? ? nil : string
      end
    end
  end
end
