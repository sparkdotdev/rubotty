# frozen_string_literal: true

require "sequel"
require_relative "../security/grant_identity"

module Rubotty
  module ControlPlane
    # Who holds the dashboard's administrator role. Resolution is the UNION of
    # two sources, the arrangement {DashboardViewers} already uses: the shipped
    # {Security::DashboardAdministrators} YAML is the FLOOR (an administrator
    # whatever the database says, never revocable here), and granted rows sit on
    # top of it. Only an administrator grants or revokes, since anything less
    # would be a route from one community to every other. Grants bind to a
    # durable platform native id; handles and display names remain labels.
    # Matrix requires a full MXID.
    class DashboardAdministrators
      # Raised for a request that cannot be carried out (an unknown adapter, a
      # blank handle, a handle the shipped list already covers). The message is
      # printed as-is.
      class Invalid < Rubotty::Error; end

      ADMINISTRATORS_TABLE = :dashboard_administrators

      # The audit log is keyed by community and an administrator belongs to none
      # of them, so this shares the one deployment-wide name the viewer roster
      # and the tokens already file under.
      AUDIT_SCOPE = DashboardViewers::AUDIT_SCOPE

      AUDIT_SOURCE = "dashboard_administrators"

      # The platforms a handle may be granted on, so a typo cannot become a row
      # nothing will ever match.
      ADAPTERS = PlatformConnections::KNOWN_ADAPTERS

      HANDLE_MAX = 255

      LABEL_MAX = 200

      GRANTED_BY_MAX = 200

      # The outcome of a revocation, uniform so a caller branches on +status+
      # without catching exceptions for control flow, matching {DashboardViewers}.
      # A grant hands back its row instead, since there is only one way it ends.
      Result = Struct.new(:status, :administrator, :detail, keyword_init: true) do
        def ok? = status == :removed

        def removed? = status == :removed

        def protected? = status == :protected

        def not_found? = status == :not_found
      end

      # @param models [ControlPlane::Models] bound to the control-plane database
      # @param registry [ControlPlane::Registry, nil] the live-Snapshot holder,
      #   reloaded after a change so a fresh grant is recognised at once
      # @param logger [#info, #warn, nil]
      # @param clock [#call] injectable time source, for deterministic tests
      # @param floor [Security::DashboardAdministrators] the shipped YAML underneath
      # @param audit [#record, nil] where a grant or a revocation is recorded
      def initialize(models:, registry: nil, logger: nil, clock: -> { Time.now },
                     floor: Security::DashboardAdministrators.default, audit: nil)
        @models = models
        @registry = registry
        @logger = logger
        @clock = clock
        @floor = floor
        @audit = audit || Core::AuditLog::Null.new
      end

      attr_reader :models, :floor

      # Does this (adapter, handle) hold the administrator role, from either
      # source? The floor answers first, so a deployment whose grant table has
      # not arrived yet still recognises everyone the shipped list names.
      #
      # @param adapter [String, Symbol] the platform the handle is on
      # @param username [String, nil] the public handle, used only by a legacy deployment floor
      # @param native_id [String, nil] the platform id; on Matrix this is the MXID
      def administrator?(adapter:, username: nil, native_id: nil)
        return true if @floor.administrator?(adapter: adapter, username: username, native_id: native_id)

        !granted_row(adapter: adapter, username: username, native_id: native_id).nil?
      end

      # The shipped list's entries as { handle:, kind: } hashes, for display.
      # Never for matching; use {#administrator?}.
      def baked_in = @floor.entries

      # Every granted row, oldest first. Empty when the table is not there yet.
      def granted
        administrators.order(:id).all
      rescue ::Sequel::Error => e
        unavailable(e, "list the granted administrators")
        []
      end

      # Hand the administrator role to a handle. Idempotent: a handle already
      # granted comes back as its existing row with nothing rewritten. A
      # handle the shipped list already covers is refused, since granting it
      # would write a row that looks removable and is not.
      #
      # @raise [Invalid]
      def grant(adapter:, handle:, granted_by:, label: nil, native_id: nil)
        platform = normalise_adapter(adapter)
        key = normalise_handle(handle, adapter: platform)
        actor = normalise_actor(granted_by)
        if @floor.administrator?(adapter: platform, username: key, native_id: native_id)
          raise Invalid, "#{key} already administers this deployment through its shipped list."
        end

        bound_id = resolve_grant_identity(adapter: platform, handle: key, native_id: native_id)
        if @floor.administrator?(adapter: platform, username: key, native_id: bound_id)
          raise Invalid, "#{key} already holds this access through the deployment's shipped list."
        end

        existing = existing_grant(platform, bound_id)
        return existing if existing

        now = @clock.call
        id = insert_administrator(platform: platform, key: key, native_id: bound_id, label: label, actor: actor, now: now)
        reload
        record_audit(action: "administrator_granted", actor: actor, subject: key, adapter: platform, now: now)
        @logger&.info { "dashboard administrator granted: #{platform}:#{key} by=#{actor}" }
        administrators.where(id: id).first
      end

      # Take a granted row back. Every row is revocable, including the last
      # one, since the shipped floor and root password stand underneath it.
      #
      # Refused, with status :protected, when the shipped list also names the
      # handle: the delete would read as a revocation while the floor kept
      # handing the same person the deployment.
      #
      # @return [Result] :removed, :not_found or :protected
      def revoke(id:, revoked_by:)
        actor = normalise_actor(revoked_by)
        row = administrator_row(id)
        return Result.new(status: :not_found) if row.nil?

        if @floor.administrator?(adapter: row[:adapter], username: row[:handle], native_id: row[:native_id])
          return Result.new(status: :protected, administrator: row)
        end

        administrators.where(id: row[:id]).delete
        reload
        record_audit(action: "administrator_revoked", actor: actor, subject: row[:handle],
                     adapter: row[:adapter])
        @logger&.info { "dashboard administrator revoked: #{row[:adapter]}:#{row[:handle]} by=#{actor}" }
        Result.new(status: :removed, administrator: row)
      rescue ::Sequel::Error => e
        unavailable(e, "revoke an administrator")
        Result.new(status: :not_found)
      end

      # Whether a handle's standing is the shipped list's rather than a row,
      # which is what the page marks as not removable.
      def baked_in?(adapter:, handle:)
        @floor.administrator?(adapter: adapter, username: handle, native_id: handle)
      end

      # What this service has recorded, most recent first, for the page that
      # hands the role out. The largest role on the deployment is the one most
      # worth being able to account for later, and its trail lives under one
      # name rather than in any community's log.
      def audit_trail(limit: 50)
        @audit.query(community: AUDIT_SCOPE, source: AUDIT_SOURCE, limit: limit)
      rescue StandardError => e
        @logger&.warn { "dashboard administrators: could not read the audit trail: #{e.message}" }
        []
      end

      private

      # A plain dataset, not a model class, so a process running ahead of this
      # table's migration reads an empty list and falls back to the floor.
      def administrators = @models.db[ADMINISTRATORS_TABLE]

      def administrator_row(id)
        return nil if id.nil?

        administrators.where(id: id.to_i).first
      end

      # The row already granting this native account id, or nil. A table that has not
      # arrived yet reads as nil and the insert below raises the honest refusal.
      def existing_grant(platform, native_id)
        Security::GrantIdentity.exact_rows(administrators.where(adapter: platform), native_id: native_id).first
      rescue ::Sequel::Error
        nil
      end

      def insert_administrator(platform:, key:, native_id:, label:, actor:, now:)
        administrators.insert(
          adapter: platform, handle: key, native_id: native_id, label: presence(label)&.[](0, LABEL_MAX),
          granted_at: now, granted_by: actor
        )
      rescue ::Sequel::UniqueConstraintViolation
        existing = existing_grant(platform, native_id)
        return existing[:id] if existing

        raise Invalid, "the native account id conflicts with this database collation; an exact-identity grant is required."
      rescue ::Sequel::Error => e
        unavailable(e, "grant an administrator")
        raise Invalid, "administrator grants are not available on this deployment yet."
      end

      # The granted row matching the proven native account, or nil. A full
      # Matrix MXID may be carried as the username when no native id is given.
      def granted_row(adapter:, username:, native_id:)
        id = Security::GrantIdentity.native_id(adapter: adapter, native_id: native_id, username: username)
        return nil if id.nil?

        Security::GrantIdentity.exact_rows(administrators.where(adapter: adapter.to_s), native_id: id).first
      rescue ::Sequel::Error => e
        unavailable(e, "resolve an administrator")
        nil
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

        raise Invalid, "#{ADAPTERS.join(", ")} are the platforms an administrator can be named on."
      end

      def normalise_handle(handle, adapter: nil)
        if adapter == "matrix"
          key = presence(handle)
          raise Invalid, "a Matrix grant needs a handle." if key.nil?
          raise Invalid, "a Matrix handle cannot exceed #{HANDLE_MAX} bytes." if key.bytesize > HANDLE_MAX

          return key
        end

        key = Security::DashboardAdministrators.normalise(handle.to_s.sub(/\A@(?![^:]+:)/, ""))
        raise Invalid, "an administrator needs a handle." if key.nil?

        key[0, HANDLE_MAX]
      end

      def normalise_actor(value)
        actor = presence(value)
        raise Invalid, "an administrator change has to say who made it." if actor.nil?

        actor[0, GRANTED_BY_MAX]
      end

      # A lost audit line never fails the change it describes, matching every
      # other caller of the log.
      def record_audit(action:, actor:, subject:, adapter:, now: @clock.call)
        @audit.record(community: AUDIT_SCOPE, source: AUDIT_SOURCE, action: action,
                      adapter: adapter, actor: actor, subject: subject, now: now)
      rescue StandardError => e
        @logger&.warn { "dashboard administrators: could not record #{action}: #{e.message}" }
        nil
      end

      # Rebuild the Snapshot so a change is recognised on the very next message.
      # A no-op when no registry is wired, which is every surface but the bot.
      def reload
        @registry&.reload
      rescue StandardError => e
        @logger&.warn { "dashboard administrators: snapshot reload after a change failed: #{e.message}" }
      end

      # The table arrives with its own migration, so a process running ahead of
      # it reads nothing rather than failing. Logged, since on a migrated
      # deployment this can only mean a real database problem.
      def unavailable(error, doing)
        @logger&.warn { "dashboard administrators: could not #{doing}: #{error.message}" }
      end

      def presence(value)
        return nil if value.nil?

        string = value.to_s.strip
        string.empty? ? nil : string
      end
    end
  end
end
