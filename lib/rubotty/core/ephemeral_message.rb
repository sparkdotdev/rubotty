# frozen_string_literal: true

require "securerandom"
require "json"

module Rubotty
  module Core
    # The ephemeral-message primitive: post a bot message (or DM via
    # #post_dm), optionally edit it, then self-delete after a delay,
    # surviving a restart mid-delay. Shared by the startup banner and
    # moderation acknowledgements so this logic lives in one place.
    # A message posted to several endpoints links under one group id;
    # every removal path (explicit delete, timed self-delete, sweep)
    # removes the whole group together. Deletion is covered four ways,
    # since any one alone can fail, and nothing here ever raises.
    class EphemeralMessage
      # The durable-scheduler job kind registered for a group's deletion. Its
      # payload is just the group id; the handler reads the group's
      # still-pending members back out of the ephemeral store, so the job
      # itself carries no endpoint or adapter state to go stale.
      DELETE_KIND = "ephemeral_delete"

      # The durable-scheduler job kind for the PERIODIC overdue sweep. A
      # recurring job, so a pending deletion whose own job or in-process
      # timer went missing is reaped within one interval on a long-running
      # process rather than waiting for the next boot.
      REAP_KIND = "ephemeral_reap"

      # How often the periodic reap runs, in seconds. Minutes rather than seconds: this
      # exists as the self-healing backstop, separate from the on-time path, and each pass is one
      # indexed query on a table that is normally empty.
      DEFAULT_REAP_INTERVAL = 60

      # How long the periodic reap keeps coming back for a message it cannot
      # delete before dropping the row. Bounds a refusal that is never going to
      # change (a permission the bot will not be granted) to a day of retries
      # rather than the life of the process.
      ABANDON_AFTER = 86_400

      # A live handle to one posted group: the copies that actually landed, plus
      # the name they were posted under (so an edit keeps the same identity).
      Copy = Struct.new(:endpoint, :native_id, keyword_init: true)

      # What #post_dm targets: one operator's identity on one adapter account,
      # resolved by the caller from ControlPlane::OperatorFlow.
      # Deliberately not a Core::Endpoint: a DM has no channel and belongs to
      # no room's topology, so folding it into Endpoint would let it slip
      # into the ordinary #deliver / #capabilities_for path by accident.
      DmTarget = Struct.new(:adapter_name, :account, :native_id, keyword_init: true) do
        # The durable row's synthetic endpoint_id: stable per (adapter,
        # account, recipient), so a resend after a partial failure updates
        # the same row instead of leaving a duplicate.
        def store_key = "dm:#{adapter_name}:#{account}:#{native_id}"
      end

      # One DM actually sent: the target it went to and the {Core::DmReceipt}
      # #send_admin_dm handed back, which #delete_admin_dm needs to remove it
      # again.
      DmCopy = Struct.new(:target, :receipt, keyword_init: true)

      class Group
        # @param copies [Array<Copy>] bot-authored messages
        # @param extras [Array<Copy>] linked non-bot messages to delete only
        def initialize(service:, id:, name:, copies:, extras: [])
          @service = service
          @id = id
          @name = name
          @copies = copies.freeze
          @extras = extras.freeze
        end

        attr_reader :id, :name, :copies, :extras

        def any? = !@copies.empty?

        def native_ids = @copies.map(&:native_id)

        # Every message this group removes: the bot's own copies and whatever was
        # linked to vanish with them.
        def members = @copies + @extras

        # Edit every copy in place to +body+ (a String or RichText).
        def edit(body) = @service.edit_group(self, body)

        # Remove every copy on every platform, plus anything linked to go with
        # them, then forget the durable rows.
        def delete_now = @service.delete_group(self)
      end

      # Shared adapters, storage and optional durable scheduling for self-deleting
      # system messages. The adapter map remains live by reference.
      # @param tracker [ControlPlane::BotMessages, nil] where a PERMANENT post
      #   is written down so /clean can find it again. Nil leaves nothing
      #   recorded, which is right for a deployment with no control plane and
      #   for a feature that built its own fallback instance.
      def initialize(adapters:, session_id:, store: EphemeralStore::Null.new, topology: nil,
                     loop_guard: nil, logger: nil, default_name: "bridge", clock: -> { Time.now },
                     durable_scheduler: nil, tracker: nil)
        @adapters = adapters
        @session_id = session_id.to_s
        @store = store
        @topology = topology
        @loop_guard = loop_guard
        @logger = logger
        @default_name = default_name
        @clock = clock
        @tracker = tracker
        @durable_scheduler = durable_scheduler
        @durable_scheduler&.register(DELETE_KIND) { |job| deliver_durable_delete(job) }
        @durable_scheduler&.register(REAP_KIND) { |_job| reap_overdue }
      end

      attr_reader :session_id

      # Re-arm the durable overdue sweep each boot for pending deletes. It is
      # inert without durable scheduling.
      def arm_periodic_reap(interval: DEFAULT_REAP_INTERVAL, now: @clock.call)
        return nil if @durable_scheduler.nil?

        @durable_scheduler.forget(kind: REAP_KIND, every_community: true)
        @durable_scheduler.schedule(
          kind: REAP_KIND, run_at: now + interval, payload: {}, recurrence: interval
        )
      end

      # Post linked copies and optionally durable self-deletes. Linked source
      # messages and platform-local replies join the group where available.
      def post(endpoints:, body:, name:, delete_after: 0, also_delete: [], reply_to: nil)
        rich = coerce(body)
        after = delete_after.to_i
        group_id = SecureRandom.uuid
        delete_at = @clock.call + after
        # Preserve a lone MessageRef as one reply parent.
        parents = (reply_to.is_a?(Array) ? reply_to : [reply_to]).compact
        copies = Array(endpoints).filter_map do |endpoint|
          native_id = deliver(endpoint, rich, name, reply_to: parent_for(parents, endpoint))
          next if native_id.nil?

          if after.positive?
            record(group_id: group_id, endpoint: endpoint, native_id: native_id, delete_at: delete_at)
          else
            # The other half of the same bookkeeping: a post with no TTL is
            # never reaped, so this is the only record that it exists at all.
            track(endpoint: endpoint, native_id: native_id, name: name)
          end
          Copy.new(endpoint: endpoint, native_id: native_id)
        end
        extras = link_extras(also_delete, group_id: group_id, delete_at: delete_at, persist: after.positive?,
                                          known: Array(endpoints).to_h { |endpoint| [endpoint.id, endpoint] })
        schedule_durable_delete(group_id: group_id, run_at: delete_at) if after.positive? && !(copies + extras).empty?
        Group.new(service: self, id: group_id, name: name, copies: copies, extras: extras)
      end

      # Post linked DMs only where adapters can also delete them later.
      def post_dm(targets:, body:, name:, delete_after: 0)
        rich = coerce(body)
        after = delete_after.to_i
        group_id = SecureRandom.uuid
        delete_at = @clock.call + after
        copies = Array(targets).filter_map do |target|
          receipt = deliver_dm(target, rich)
          next if receipt.nil?

          record_dm(group_id: group_id, target: target, receipt: receipt, delete_at: delete_at) if after.positive?
          DmCopy.new(target: target, receipt: receipt)
        end
        schedule_durable_delete(group_id: group_id, run_at: delete_at) if after.positive? && !copies.empty?
        Group.new(service: self, id: group_id, name: name, copies: copies, extras: [])
      end

      # Edit every copy of +group+ to +body+; copies whose adapter cannot edit
      # are left as they are. Internal to {Group#edit}.
      def edit_group(group, body)
        rich = coerce(body)
        group.copies.each { |copy| edit_copy(copy, rich, group.name) }
        nil
      end

      # Edit a directly named persistent bot message.
      # @return [Boolean] whether its platform accepted the edit
      def edit_one(endpoint:, native_id:, body:, name: @default_name)
        edit_copy(Copy.new(endpoint: endpoint, native_id: native_id), coerce(body), name)
      end

      # Remove one directly named bot message.
      # @return [Boolean] whether it was deleted
      def delete_one(endpoint:, native_id:)
        delete_copy(Copy.new(endpoint: endpoint, native_id: native_id)) == :deleted
      end

      # Delete all linked group members, retaining rows that need later retry.
      def delete_group(group)
        failed = group.members.count { |copy| delete_copy(copy) == :failed }
        forget(group.id) if failed.zero?
        nil
      end

      # Find a linked copy's native id on another endpoint for moderation.
      def sibling_native_id(ref:, endpoint_id:)
        group_id = @store.group_id_for(endpoint_id: ref.endpoint_id, native_id: ref.native_id)
        return nil if group_id.nil?

        @store.members(group_id).find { |m| m.endpoint_id == endpoint_id.to_s }&.native_id
      rescue StorageError => e
        @logger&.debug { "ephemeral sibling lookup failed: #{e.message}" }
        nil
      end

      # Forget durable rows for the group containing a manually deleted copy.
      def forget_group_containing(endpoint_id:, native_id:)
        group_id = @store.group_id_for(endpoint_id: endpoint_id, native_id: native_id)
        forget(group_id) if group_id
        nil
      rescue StorageError => e
        @logger&.debug { "ephemeral forget failed: #{e.message}" }
        nil
      end

      # Sweep expired or prior-session groups at boot, preserving the current
      # session's pending deletes.
      # @return [Integer] copies removed
      def sweep(alive_session_ids: [@session_id], now: @clock.call)
        removed = 0
        @store.orphan_group_ids(now: now, alive_session_ids: alive_session_ids).each do |group_id|
          removed += reap_group(group_id, now: now)
        end
        removed
      rescue StorageError => e
        @logger&.warn { "ephemeral boot sweep failed: #{e.message}" }
        removed
      end

      # Reap every overdue deletion, including those from this session.
      # @return [Integer] copies removed
      def reap_overdue(now: @clock.call)
        removed = sweep(alive_session_ids: [@session_id], now: now)
        @logger&.info { "ephemeral: reaped #{removed} overdue message(s) on the periodic sweep" } if removed.positive?
        removed
      end

      # Delete a previously posted group right now, by id alone, so a caller
      # that remembers a group id across a restart can supersede it with a
      # fresh post rather than waiting on its own timer or the next boot
      # sweep to get to it. Harmless on an id already fully reaped: {#reap_group}
      # only touches rows still on record.
      # @return [Integer] copies removed
      def delete_group_now(group_id)
        reap_group(group_id)
      rescue StorageError => e
        @logger&.warn { "ephemeral: could not supersede group #{group_id}: #{e.message}" }
        0
      end

      private

      # Link requested source-message refs into durable group rows when their
      # endpoints can be resolved.
      def link_extras(refs, group_id:, delete_at:, persist:, known: {})
        Array(refs).compact.filter_map do |ref|
          endpoint = known[ref.endpoint_id] || resolve_endpoint(ref.endpoint_id)
          if endpoint.nil?
            @logger&.warn { "ephemeral: cannot pair #{ref} with its reply, no live endpoint #{ref.endpoint_id}" }
            next
          end
          next if ref.native_id.nil?

          record(group_id: group_id, endpoint: endpoint, native_id: ref.native_id, delete_at: delete_at) if persist
          Copy.new(endpoint: endpoint, native_id: ref.native_id)
        end
      end

      # Reap still-recorded group members for sweeps and durable jobs. Concurrent
      # reaps are harmless. Each member is forgotten as soon as its own copy is
      # gone, so a later pass over the same group only retries what is still
      # outstanding rather than re-deleting a copy that already succeeded.
      # @return [Integer] copies removed
      def reap_group(group_id, now: @clock.call)
        removed = 0
        @store.members(group_id).each do |member|
          copy = resolve_member(member)
          if copy.nil?
            # Drop rows that can no longer be addressed rather than retry forever.
            @logger&.warn { "ephemeral: dropping #{member.native_id}, no live endpoint #{member.endpoint_id}" }
            forget_member(member)
            next
          end

          case delete_copy(copy)
          when :failed
            # Retain the row for a failed delete so periodic reaping can retry,
            # unless it has already had its bounded retry window.
            forget_member(member) if abandon?(member, now)
          else
            removed += 1
            forget_member(member)
          end
        end
        removed
      end

      # Rebuild an endpoint Copy or DM DmCopy from a durable row.
      def resolve_member(member)
        blob = channel_blob(member)
        return dm_copy_from_row(member, blob) if blob.is_a?(Hash) && blob["kind"] == "dm"

        endpoint = resolve_endpoint(member.endpoint_id) || rebuilt_endpoint(member, blob)
        return nil if endpoint.nil?

        Copy.new(endpoint: endpoint, native_id: member.native_id)
      end

      def channel_blob(member)
        JSON.parse(member.channel.to_s)
      rescue StandardError
        nil
      end

      # Rebuild the DM receipt and adapter target needed for deletion.
      def dm_copy_from_row(member, blob)
        return nil if blob["adapter"].to_s.empty?

        target = DmTarget.new(adapter_name: blob["adapter"].to_sym, account: blob["account"].to_s, native_id: nil)
        receipt = DmReceipt.new(native_id: member.native_id, channel_ref: blob["channel_ref"])
        DmCopy.new(target: target, receipt: receipt)
      end

      # Abandon permanently undeletable rows after the bounded retry window.
      def abandon?(member, now)
        return false if member.delete_at.nil?
        return false if now - member.delete_at < ABANDON_AFTER

        @logger&.warn do
          "ephemeral: giving up on #{member.native_id} on #{member.endpoint_id}, " \
            "still undeletable #{ABANDON_AFTER} seconds past its horizon"
        end
        true
      end

      # Schedule durable group deletion as crash recovery for the local timer.
      def schedule_durable_delete(group_id:, run_at:)
        @durable_scheduler&.schedule(kind: DELETE_KIND, run_at: run_at, payload: { "group_id" => group_id })
        nil
      end

      # Reap the group owned by a durable delete job on any recovering session.
      def deliver_durable_delete(job)
        group_id = job.payload && job.payload["group_id"]
        return if group_id.to_s.empty?

        reap_group(group_id.to_s)
      rescue StorageError => e
        @logger&.warn { "ephemeral: durable delete of group #{group_id} failed: #{e.message}" }
      end

      # Post one copy and retain its id even if later bookkeeping fails.
      def deliver(endpoint, body, name, reply_to: nil)
        adapter = adapter_for(endpoint)
        return nil if adapter.nil?

        receipt = begin
          adapter.deliver(notice(endpoint, body, name, reply_to: reply_to), endpoint)
        rescue StandardError => e
          @logger&.warn { "ephemeral: could not post to #{endpoint.id}: #{e.class}: #{e.message}" }
          nil
        end
        return nil if receipt.nil? || receipt.native_id.nil?

        # Record this direct post so a banner echo is recognised as ours.
        note_delivery(endpoint, receipt.native_id)
        receipt.native_id
      end

      def note_delivery(endpoint, native_id)
        @loop_guard&.note_delivery(endpoint.id, native_id)
      rescue StandardError => e
        @logger&.warn { "ephemeral: could not note the delivery of #{native_id} on #{endpoint.id}: #{e.message}" }
      end

      # @return [Boolean] whether the platform took it, which {#edit_group}
      #   ignores and {#edit_one} answers with.
      def edit_copy(copy, body, name)
        # A DM is never edited, only removed; see the class doc for #post_dm.
        return false if copy.is_a?(DmCopy)

        adapter = adapter_for(copy.endpoint)
        return false if adapter.nil? || !adapter.capabilities_for(copy.endpoint).edits?

        adapter.edit(notice(copy.endpoint, body, name, native_id: copy.native_id), copy.endpoint, copy.native_id)
        true
      rescue StandardError => e
        @logger&.debug { "ephemeral: could not edit #{copy.native_id} on #{copy.endpoint.id}: #{e.message}" }
        false
      end

      # Remove endpoint or DM copies as deleted, unsupported or retryable failure.
      def delete_copy(copy)
        copy.is_a?(DmCopy) ? delete_dm_copy(copy) : delete_endpoint_copy(copy)
      end

      # Log endpoint delete failures so missing platform permissions are visible.
      def delete_endpoint_copy(copy)
        adapter = adapter_for(copy.endpoint)
        return :unsupported if adapter.nil? || !adapter.capabilities_for(copy.endpoint).deletes?

        adapter.delete(copy.endpoint, copy.native_id)
        :deleted
      rescue StandardError => e
        @logger&.warn { "ephemeral: could not delete #{copy.native_id} on #{copy.endpoint.id}: #{e.class}: #{e.message}" }
        :failed
      end

      # Treat a refused DM deletion as a retryable failure, retaining its row.
      def delete_dm_copy(copy)
        adapter = adapter_for_dm(copy.target)
        return :unsupported if adapter.nil? || !adapter.supports_admin_dm_delete?

        adapter.delete_admin_dm(copy.receipt) ? :deleted : :failed
      rescue StandardError => e
        @logger&.warn { "ephemeral: could not delete DM #{copy.receipt&.native_id}: #{e.class}: #{e.message}" }
        :failed
      end

      # Write a permanent post down for /clean. The room and community come from
      # the topology this instance was built with, so an endpoint in no room
      # (a DM target, a feature's own bare instance) simply records nothing.
      def track(endpoint:, native_id:, name:)
        return if @tracker.nil? || native_id.to_s.empty?

        room = @topology&.rooms_for(endpoint.id)&.first
        return if room.nil? || room.community_id.nil?

        @tracker.record(community_id: room.community_id, room_key: room.id,
                        endpoint_id: endpoint.id, native_id: native_id, kind: name)
      rescue StandardError => e
        @logger&.warn { "ephemeral: could not record the bot message on #{endpoint.id}: #{e.message}" }
      end

      def record(group_id:, endpoint:, native_id:, delete_at:)
        @store.add(
          group_id: group_id, endpoint_id: endpoint.id, channel: channel_of(endpoint),
          native_id: native_id, delete_at: delete_at, session_id: @session_id
        )
      rescue StorageError => e
        # Losing durable backup never retracts a message already delivered.
        @logger&.warn { "ephemeral: could not persist the pending deletion for #{endpoint.id}: #{e.message}" }
      end

      # Store DMs with a synthetic endpoint id and tagged channel blob.
      def record_dm(group_id:, target:, receipt:, delete_at:)
        @store.add(
          group_id: group_id, endpoint_id: target.store_key, channel: dm_channel_blob(target, receipt),
          native_id: receipt.native_id, delete_at: delete_at, session_id: @session_id
        )
      rescue StorageError => e
        @logger&.warn { "ephemeral: could not persist the pending DM deletion for #{target.store_key}: #{e.message}" }
      end

      def forget(group_id)
        @store.forget(group_id)
      rescue StorageError => e
        @logger&.debug { "ephemeral: could not forget group #{group_id}: #{e.message}" }
      end

      def forget_member(member)
        @store.forget_member(group_id: member.group_id, endpoint_id: member.endpoint_id, native_id: member.native_id)
      rescue StorageError => e
        @logger&.debug { "ephemeral: could not forget #{member.native_id} on #{member.endpoint_id}: #{e.message}" }
      end

      def resolve_endpoint(endpoint_id) = @topology&.endpoint(endpoint_id)

      # Rebuild an endpoint from durable addressing when topology cannot find it.
      def rebuilt_endpoint(member, blob)
        return nil unless blob.is_a?(Hash) && !blob["adapter"].to_s.empty?

        Endpoint.new(
          id: member.endpoint_id, adapter_name: blob["adapter"].to_sym,
          account: blob["account"].to_s, settings: blob["settings"] || {}
        )
      rescue StandardError
        nil
      end

      # Encode adapter, account and settings needed to rebuild an endpoint.
      def channel_of(endpoint)
        JSON.generate(
          "adapter" => endpoint.adapter_name.to_s, "account" => endpoint.account,
          "settings" => endpoint.settings
        )
      rescue StandardError
        nil
      end

      # Encode tagged DM addressing and the receipt data required for deletion.
      def dm_channel_blob(target, receipt)
        JSON.generate(
          "kind" => "dm", "adapter" => target.adapter_name.to_s, "account" => target.account,
          "channel_ref" => receipt.channel_ref
        )
      rescue StandardError
        nil
      end

      def notice(endpoint, body, name, native_id: nil, reply_to: nil)
        Message.new(
          kind: :system,
          ref: MessageRef.new(endpoint.id, native_id || "ephemeral-#{SecureRandom.hex(4)}"),
          origin: endpoint,
          author: Author.new(display_name: name || @default_name, kind: :system),
          body: body,
          reply_to: reply_to,
          sender_label: name || @default_name
        )
      end

      # The parent on THIS endpoint, or nil. An adapter only honours a reply
      # whose ref names its own endpoint, so handing it somebody else's would
      # be the same as handing it nothing, only harder to read.
      def parent_for(parents, endpoint)
        parents.find { |ref| ref.endpoint_id == endpoint.id }
      end

      def coerce(body) = body.is_a?(RichText) ? body : RichText.plain(body.to_s)

      def adapter_for(endpoint)
        adapter = @adapters[[endpoint.adapter_name, endpoint.account]]
        @logger&.error { "ephemeral: no adapter instance for #{endpoint}" } if adapter.nil?
        adapter
      end

      def adapter_for_dm(target)
        return nil if target.nil?

        adapter = @adapters[[target.adapter_name.to_sym, target.account.to_s]]
        @logger&.error { "ephemeral: no adapter instance for dm target #{target.adapter_name}/#{target.account}" } if adapter.nil?
        adapter
      end

      # Send a DM only when its adapter also supports later self-deletion.
      def deliver_dm(target, body)
        adapter = adapter_for_dm(target)
        return nil if adapter.nil?

        unless adapter.supports_admin_dm? && adapter.supports_admin_dm_delete?
          @logger&.info do
            "ephemeral: not DMing #{target.adapter_name}/#{target.account}, no ephemeral admin DM there yet"
          end
          return nil
        end

        adapter.send_admin_dm(target.native_id, body.to_s)
      rescue StandardError => e
        @logger&.warn { "ephemeral: could not DM #{target.adapter_name}/#{target.account}: #{e.class}: #{e.message}" }
        nil
      end
    end
  end
end
