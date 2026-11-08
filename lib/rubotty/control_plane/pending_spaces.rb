# frozen_string_literal: true

require "json"

module Rubotty
  module ControlPlane
    # Pending-review control plane for a space the bot was just added to: it
    # posts a one-time notice, stays for a bounded window, and appears on the
    # dashboard; a decision that never arrives is still a leave, on a timer. A
    # pending item is a SPACE, not yet a community, so approving one creates a
    # new community or attaches to an existing one. One row per space ever: a
    # rejoin while pending refreshes its fields without restarting the clock,
    # and a denied row is a soft blacklist entry until an administrator
    # {#clear}s it.
    class PendingSpaces
      PENDING = "pending"
      APPROVED = "approved"
      DENIED = "denied"

      # The durable scheduler's handler kind for the auto-leave timer.
      EXPIRE_KIND = "pending_space_expire"

      # The durable scheduler's handler kind for the post-approval channel sweep,
      # registered only where the adapter map is live, so an approval made in the
      # dashboard waits for whichever bot process is running.
      ENUMERATE_KIND = "pending_space_enumerate"

      # Seconds a space waits for a decision before the auto-leave fires.
      DEFAULT_TTL = 1800

      # Window and cap {#on_traffic!} rate-limits itself over: traffic is
      # outsider-controlled, so without a ceiling anyone could fill the table
      # from new spaces. A join event is never rate-limited.
      TRAFFIC_WINDOW = 3600
      TRAFFIC_LIMIT = 20

      # Posted once, on join, into a newly pended space.
      PENDING_NOTICE =
        "This is a private bot. It is pending review and will leave automatically in about 30 minutes " \
        "unless approved by the operator. If you believe this is a mistake, please contact the bot's operator."

      # Posted once when a leave happens, from a deny or from the window expiring.
      DEPARTURE_NOTICE =
        "This request to add the bot was not approved, so it is leaving. If you believe this is a mistake, " \
        "please contact the bot's operator."

      # Aliased onto {JoinGuard}'s constant so the wording cannot drift between the
      # two unauthorized-space flows.
      INERT_NOTICE = JoinGuard::INERT_NOTICE

      # What {#on_join!} decided: :stay (a known community slipped through),
      # :pending (#post_notice says whether THIS call should post
      # {PENDING_NOTICE}), or :leave (a denied space was re-added).
      Outcome = Struct.new(:action, :row, :post_notice, keyword_init: true) do
        def stay? = action == :stay

        def pending? = action == :pending

        def leave? = action == :leave
      end

      # The outcome of {#approve}, {#deny} or {#clear}.
      Result = Struct.new(:status, :row, :community, keyword_init: true) do
        def approved? = status == :approved

        def denied? = status == :denied
      end

      # @param authorization [AuthorizationDirectory, nil] a space it MAPS to a
      #   community is never pended, and a space its whitelist protects by title is
      #   pended without an auto-leave timer
      # @param scheduler [Core::DurableScheduler, nil] backs the auto-leave timer;
      #   nil degrades it to a no-op
      def initialize(models:, authorization: nil, scheduler: nil, adapters: {}, registry: nil,
                     admin_notifier: nil, ttl: DEFAULT_TTL, logger: nil, clock: -> { Time.now })
        @models = models
        @authorization = authorization
        @scheduler = scheduler
        @adapters = adapters
        @registry = registry
        @admin_notifier = admin_notifier
        @ttl = ttl
        @logger = logger
        @clock = clock
      end

      # The full join-time decision: create or touch the pending row, schedule the
      # auto-leave timer and notify the administrator on first creation, and report
      # what the adapter should do about the in-space notice. Never raises.
      #
      # @return [Outcome]
      def on_join!(adapter:, account:, external_id:, name: nil, inviter_native_id: nil,
                   inviter_username: nil, inviter_display: nil, member_count: nil, sample_channels: [])
        adapter = adapter.to_s
        account = account.to_s
        external_id = external_id.to_s
        row = existing(adapter, account, external_id)

        # Never pend a space a platform connection MAPS to a community. A title on
        # the {ProtectedCommunities} whitelist deliberately does not count: it
        # keeps the bot from ever leaving, which is a different question from who
        # owns the space, and a space nobody owns has to reach the board.
        mapped = @authorization&.mapped?(adapter: adapter, account: account, external_id: external_id)
        if mapped || row&.state == APPROVED
          learn_name!(adapter, account, external_id, name, row)
          return Outcome.new(action: :stay, row: row)
        end
        return Outcome.new(action: :leave, row: row, post_notice: false) if row&.state == DENIED

        shielded = protected_title?(name)
        created = row.nil?
        row = upsert_pending!(
          row, adapter: adapter, account: account, external_id: external_id, name: name,
          inviter_native_id: inviter_native_id, inviter_username: inviter_username,
          inviter_display: inviter_display, member_count: member_count, sample_channels: sample_channels
        )
        # No timer and no notice for a protected title: nothing is going to leave.
        schedule_timer!(row) if created && !shielded
        notify_admin!(row) if created
        Outcome.new(action: :pending, row: row, post_notice: !shielded && row.notice_posted_at.nil?)
      rescue StorageError => e
        @logger&.warn { "pending spaces: on_join! failed for #{adapter}/#{external_id}: #{e.message}" }
        Outcome.new(action: :stay, row: nil)
      end

      # Pends a space from its own traffic, for a join event that never arrived
      # (a bot down when added never sees one). Never posts a notice and never
      # touches an existing row, so repeated traffic can't restart the review
      # clock or un-deny a denied space.
      #
      # @return [Models::PendingSpace, nil] the row created, nil when it did nothing
      def on_traffic!(adapter:, account:, external_id:, name: nil)
        adapter = adapter.to_s
        account = account.to_s
        external_id = external_id.to_s
        return nil if external_id.empty?
        return nil unless existing(adapter, account, external_id).nil?
        return nil unless traffic_budget?

        outcome = on_join!(adapter: adapter, account: account, external_id: external_id, name: name)
        return nil unless outcome.pending?

        @logger&.info { "pending spaces: pended #{adapter}/#{external_id} from its traffic, with no join event" }
        outcome.row
      rescue StorageError => e
        @logger&.warn { "pending spaces: on_traffic! failed for #{adapter}/#{external_id}: #{e.message}" }
        nil
      end

      # A previously denied space was re-added: try to leave, or fall back to the
      # deduped {INERT_NOTICE}. Silent either way, so a nuisance bot-adder retrying
      # in a loop cannot turn this into a spam source.
      #
      # @param row [Models::PendingSpace, nil] as returned on {Outcome#row}
      def reconfirm_denied!(row)
        return if row.nil? || row.state != DENIED
        return if protected_title?(row.name)

        leave_or_inert!(row, leave_notice: nil)
      end

      # Record that {PENDING_NOTICE} was posted for +row+, so a later evaluation of
      # the same space never posts it again.
      def mark_notice_posted!(row)
        return if row.nil? || row.notice_posted_at

        row.update(notice_posted_at: @clock.call, updated_at: @clock.call)
      end

      # Every space currently awaiting a decision, oldest first.
      def pending
        @models.pending_space.where(state: PENDING).order(:created_at).all
      end

      # Every denied space, most recently decided first, so one can be {#clear}ed.
      def denied
        @models.pending_space.where(state: DENIED).order(Sequel.desc(:decided_at)).all
      end

      def find(id)
        return nil if id.nil?

        @models.pending_space[id.to_i]
      end

      # Approves a pending space by writing a +platform_connections+ row: authorizes
      # presence and discovery only, so the community stays dormant until room,
      # channel mapping or feature setup happens separately. Also triggers the
      # channel sweep, since anything the adapter enumerated before this had no
      # connection to be recorded against (see {#settle_enumeration!}).
      #
      # @return [Result] :approved, :not_found, :not_pending or :invalid
      def approve(id:, admin:, community_id: nil, new_community_name: nil, make_operator: false)
        row = find(id)
        return Result.new(status: :not_found) if row.nil?
        return Result.new(status: :not_pending, row: row) unless row.state == PENDING
        return Result.new(status: :invalid, row: row) if community_id.nil? && presence(new_community_name).nil?

        community = nil
        @models.db.transaction do
          community = community_id ? @models.community[community_id.to_i] : create_community!(new_community_name)
          raise Sequel::Rollback if community.nil?

          attach_platform_connection!(row, community)
          make_operator!(row, community) if make_operator
          row.update(state: APPROVED, community_id: community.id, decided_by: admin.to_s,
                     decided_at: @clock.call, updated_at: @clock.call)
        end
        return Result.new(status: :invalid, row: row) if community.nil?

        reload_snapshot
        settle_enumeration!(row)
        @logger&.info { "pending spaces: approved #{row.adapter}/#{row.external_id} into #{community.slug}" }
        Result.new(status: :approved, row: row, community: community)
      end

      # Deny a pending space: record the denial at once, and leave immediately when
      # this process has a live adapter. A deny made in the dashboard, which has no
      # adapter connections, instead schedules {EXPIRE_KIND} at run_at: now.
      #
      # @return [Result] :denied, :not_found or :not_pending
      def deny(id:, admin:)
        row = find(id)
        return Result.new(status: :not_found) if row.nil?
        return Result.new(status: :not_pending, row: row) unless row.state == PENDING

        row.update(state: DENIED, decided_by: admin.to_s, decided_at: @clock.call, updated_at: @clock.call)
        # The same never-leave guard #expire holds: ProtectedCommunities is a
        # whitelist the dashboard can never override, misclick or not.
        settle_departure!(row) unless protected_title?(row.name)
        @logger&.info { "pending spaces: denied #{row.adapter}/#{row.external_id}" }
        Result.new(status: :denied, row: row)
      end

      # Clear a denied row, so a later join for that space starts a fresh pending
      # review instead of being silently re-denied.
      #
      # @return [Boolean] whether a row was actually cleared
      def clear(id:)
        row = find(id)
        return false if row.nil? || row.state != DENIED

        row.destroy
        true
      end

      # The durable-scheduler handler for {EXPIRE_KIND}, covering the unattended
      # timeout and the cross-process pickup of a dashboard {#deny}. Idempotent: a
      # set +left_at+ or an APPROVED row is skipped, and :deferred leaves it unset.
      def expire(job)
        payload = job.payload || {}
        row = find(payload["pending_space_id"])
        return if row.nil? || row.state == APPROVED || !row.left_at.nil?
        # The second never-leave guard, for a row that learned its title late.
        return if protected_title?(row.name)

        was_pending = row.state == PENDING
        outcome = leave_or_inert!(row, leave_notice: DEPARTURE_NOTICE)
        return if outcome == :deferred

        updates = { left_at: @clock.call, updated_at: @clock.call }
        if was_pending
          updates.merge!(state: DENIED, decided_by: "auto-expired", decided_at: @clock.call)
          @logger&.info { "pending spaces: #{row.adapter}/#{row.external_id} expired with no decision" }
        end
        row.update(updates)
      end

      # The durable-scheduler handler for {ENUMERATE_KIND}: the cross-process half
      # of the post-approval channel sweep, run wherever the adapter is live.
      # Idempotent, since {ChannelDiscovery#inventory} records a channel once.
      def enumerate(job)
        payload = job.payload || {}
        row = find(payload["pending_space_id"])
        return if row.nil? || row.state != APPROVED

        enumerate_now!(row)
      end

      # Whether this space was denied, which is the one state the bot has promised
      # to stay completely silent in.
      #
      # @return [Boolean]
      def denied?(adapter:, account:, external_id:)
        row = existing(adapter.to_s, account.to_s, external_id.to_s)
        !row.nil? && row.state == DENIED
      rescue StorageError
        false
      end

      private

      def existing(adapter, account, external_id)
        @models.pending_space.where(adapter: adapter, account: account, external_id: external_id).first
      end

      # Whether the deployment-configured whitelist protects a space carrying this title. False
      # with no authorization directory, which is what the bare-service specs use.
      def protected_title?(title)
        return false if @authorization.nil?

        @authorization.protected_title?(title)
      end

      # Whether {#on_traffic!} may pend one more space right now. Counts rows of
      # EVERY state, since a row denied a minute after it was created still takes
      # up a slot, so the ceiling bounds table growth rather than queue depth.
      def traffic_budget?
        window_start = @clock.call - TRAFFIC_WINDOW
        used = @models.pending_space.where { created_at > window_start }.count
        return true if used < TRAFFIC_LIMIT

        @logger&.warn { "pending spaces: #{used} spaces pended in the last hour, ignoring this one's traffic" }
        false
      end

      def upsert_pending!(row, adapter:, account:, external_id:, name:, inviter_native_id:,
                          inviter_username:, inviter_display:, member_count:, sample_channels:)
        now = @clock.call
        attributes = {
          name: presence(name), inviter_native_id: presence(inviter_native_id&.to_s),
          inviter_username: presence(inviter_username), inviter_display: presence(inviter_display),
          member_count: member_count, sample_channels: JSON.generate(Array(sample_channels)),
          updated_at: now
        }
        if row
          row.update(attributes)
          row
        else
          @models.pending_space.create(
            attributes.merge(
              adapter: adapter, account: account, external_id: external_id, state: PENDING,
              expires_at: now + @ttl, created_at: now
            )
          )
        end
      rescue Sequel::UniqueConstraintViolation
        # A concurrent join created the row first; fall back to it.
        existing(adapter, account, external_id) || row
      end

      def schedule_timer!(row)
        return if @scheduler.nil?

        job_id = @scheduler.schedule(
          kind: EXPIRE_KIND, run_at: row.expires_at, payload: { "pending_space_id" => row.id }
        )
        row.update(job_id: job_id) if job_id
      end

      def notify_admin!(row)
        return if @admin_notifier.nil?

        text = "New pending community: #{row.name || row.external_id} (#{row.adapter}). " \
               "Review it in the dashboard within about 30 minutes."
        @admin_notifier.notify!(text)
      rescue StandardError => e
        @logger&.warn { "pending spaces: admin notify failed: #{e.message}" }
      end

      # Carry out the departure here when a live adapter for the row exists,
      # otherwise schedule {EXPIRE_KIND} for a process that does carry one. Sets
      # +left_at+ only when something was actually settled.
      def settle_departure!(row)
        outcome = leave_or_inert!(row, leave_notice: DEPARTURE_NOTICE)
        if outcome == :deferred
          @scheduler&.schedule(kind: EXPIRE_KIND, run_at: @clock.call, payload: { "pending_space_id" => row.id })
        else
          row.update(left_at: @clock.call, updated_at: @clock.call)
        end
      end

      # Returns :left when the leave worked, :inert when a live adapter is here but
      # cannot leave (so {INERT_NOTICE} goes out, at most once per space), and
      # :deferred when this process carries no adapter for that row.
      def leave_or_inert!(row, leave_notice:)
        adapter = adapter_for(row)
        return :deferred if adapter.nil?

        if adapter.supports_leave?
          begin
            return :left if adapter.leave_space(row.external_id, notice: leave_notice)
          rescue StandardError => e
            @logger&.warn { "pending spaces: leave failed for #{row.adapter}/#{row.external_id}: #{e.message}" }
          end
        end
        post_inert_notice!(row, adapter)
        :inert
      end

      def post_inert_notice!(row, adapter)
        return if row.inert_notice_posted_at
        return unless adapter&.supports_space_notice?

        posted = adapter.post_space_notice(row.external_id, INERT_NOTICE)
        row.update(inert_notice_posted_at: @clock.call, updated_at: @clock.call) if posted
      rescue StandardError => e
        @logger&.warn { "pending spaces: inert notice failed for #{row.adapter}/#{row.external_id}: #{e.message}" }
      end

      def adapter_for(row)
        @adapters[[row.adapter.to_sym, row.account]]
      end

      # The space's channels were first enumerated while it was still pending, so
      # they had no platform connection to be recorded against and were dropped.
      # Ask for them again here, where the connection exists, on a process holding
      # the adapter or on a scheduled job for one that does.
      def settle_enumeration!(row)
        # No adapter here means the approval was made in the dashboard or the API,
        # so the sweep waits for whichever bot process holds the connection.
        if adapter_for(row).nil?
          @scheduler&.schedule(kind: ENUMERATE_KIND, run_at: @clock.call, payload: { "pending_space_id" => row.id })
          return
        end

        enumerate_now!(row)
      end

      # Truthy only when a live adapter here actually ran the enumeration.
      def enumerate_now!(row)
        adapter = adapter_for(row)
        return false if adapter.nil? || !adapter.supports_space_enumeration?

        ran = adapter.enumerate_space(row.external_id)
        @logger&.info { "pending spaces: re-enumerated #{row.adapter}/#{row.external_id} after approval" } if ran
        ran
      rescue StandardError => e
        @logger&.warn do
          "pending spaces: post-approval enumeration failed for #{row.adapter}/#{row.external_id}: #{e.message}"
        end
        false
      end

      # A space whose name only arrived after it was approved: fill in the blank
      # label its connection was created with, and the blank name on its own row.
      # An existing name is left alone, so passive joins never rewrite one.
      def learn_name!(adapter, account, external_id, name, row)
        name = presence(name)
        return if name.nil?

        row.update(name: name, updated_at: @clock.call) if row && presence(row.name).nil?
        connection = @models.platform_connection.where(
          adapter: adapter, account: account, external_id: external_id
        ).first
        return if connection.nil? || !presence(connection.label).nil?

        connection.update(label: name, updated_at: @clock.call)
        @logger&.info { "pending spaces: labelled #{adapter}/#{external_id} #{name.inspect}, learned after approval" }
      rescue StandardError => e
        @logger&.warn { "pending spaces: could not label #{adapter}/#{external_id}: #{e.message}" }
      end

      def attach_platform_connection!(row, community)
        now = @clock.call
        existing_connection = @models.platform_connection.where(
          adapter: row.adapter, account: row.account, external_id: row.external_id
        ).first
        return existing_connection if existing_connection

        @models.platform_connection.create(
          community_id: community.id, adapter: row.adapter, account: row.account,
          external_id: row.external_id, label: row.name, created_at: now, updated_at: now
        )
      end

      def create_community!(name)
        clean_name = presence(name)
        return nil if clean_name.nil?

        now = @clock.call
        @models.community.create(
          slug: unique_slug(clean_name), name: clean_name, status: "active",
          bootstrap_source: "pending-space-approval", created_at: now, updated_at: now
        )
      end

      def unique_slug(name)
        base = name.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
        base = "community" if base.empty?
        base = base[0, 56]
        candidate = base
        suffix = 2
        while @models.community.where(slug: candidate).first
          candidate = "#{base}-#{suffix}"
          suffix += 1
        end
        candidate
      end

      # Promote whoever added the bot, when a native id for them was captured at
      # join time. Mirrors {OperatorFlow}'s find-or-create shapes.
      def make_operator!(row, community)
        native_id = presence(row.inviter_native_id)
        return nil if native_id.nil?

        now = @clock.call
        handle = normalise_handle(row.inviter_username)
        identity = @models.person_identity.where(adapter: row.adapter, native_id: native_id).all.find do |candidate|
          @models.person[candidate.person_id]&.community_id == community.id
        end

        person =
          if identity
            @models.person[identity.person_id]
          else
            name = presence(row.inviter_display) || presence(handle) || native_id
            @models.person.create(community_id: community.id, name: name, created_at: now, updated_at: now)
          end

        if identity.nil?
          @models.person_identity.create(
            person_id: person.id, community_id: community.id, adapter: row.adapter, native_id: native_id,
            username: handle, created_at: now
          )
        end

        existing_operator = @models.operator.where(community_id: community.id, person_id: person.id).first
        return existing_operator if existing_operator

        @models.operator.create(
          community_id: community.id, person_id: person.id, actions: JSON.generate("all"),
          scope: JSON.generate("all"), granted_at: now, granted_by: "pending-space-approval:#{row.id}"
        )
      end

      def reload_snapshot
        @registry&.reload
      rescue StandardError => e
        @logger&.warn { "pending spaces: snapshot reload after approve failed: #{e.message}" }
      end

      def normalise_handle(value)
        clean = presence(value)
        clean&.sub(/\A@/, "")&.downcase
      end

      def presence(value)
        return nil if value.nil?

        string = value.to_s.strip
        string.empty? ? nil : string
      end
    end
  end
end
