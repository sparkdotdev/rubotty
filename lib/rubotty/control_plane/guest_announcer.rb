# frozen_string_literal: true

require "securerandom"

module Rubotty
  module ControlPlane
    # Announces a guest's arrival and departure to the room they joined: a
    # guest can suddenly read what members say there (a privacy affordance).
    # Trigger and delivery happen in different processes, so with a
    # +scheduler+, {#announce_join}/{#announce_departure} enqueue a durable job
    # for the bot to claim; without one, delivery is direct. The room resolves
    # from the LIVE Snapshot, since a departure can fire long after the join.
    # One notice per event relies on callers already being idempotent, not
    # dedup here (GuestInvites#record_join, GuestRetention#reclaim_for).
    class GuestAnnouncer
      DEFAULT_NAME = "rubotty"

      # The durable-scheduler job kinds this registers when given a scheduler, so
      # the process polling it (the bot) is the one that delivers.
      JOIN_KIND = "guest_announce_join"
      DEPARTURE_KIND = "guest_announce_departure"

      # @param registry [ControlPlane::Registry, nil] source of the live Snapshot
      #   the room is resolved from. Required for delivery; nil is fine for a
      #   process that only ever ENQUEUES (dashboard, guest portal).
      # @param scheduler [Core::DurableScheduler, nil] when given, delivery is
      #   routed through a durable job; the handler is registered here, at
      #   construction, before boot recovery runs. nil delivers synchronously.
      def initialize(registry: nil, models:, adapters: {}, scheduler: nil, logger: nil, name: DEFAULT_NAME)
        @registry = registry
        @models = models
        @adapters = adapters
        @scheduler = scheduler
        @logger = logger
        @name = name
        @scheduler&.register(JOIN_KIND) { |job| deliver_join(invite_from(job)) }
        @scheduler&.register(DEPARTURE_KIND) { |job| deliver_departure(invite_from(job), reason: reason_from(job)) }
      end

      # A guest has just opened their invite for the first time.
      #
      # @param invite [Models::GuestInvite]
      def announce_join(invite)
        return if invite.nil?

        if @scheduler
          @scheduler.schedule(kind: JOIN_KIND, run_at: Time.now, payload: { "invite_id" => invite.id })
        else
          deliver_join(invite)
        end
      end

      # An invite's access has just ended, whether by revocation or by
      # reaching its expiry.
      #
      # @param invite [Models::GuestInvite]
      # @param reason [String] the same reason string
      #   {GuestRetention#reclaim_for} logs with ("invite revoked" or "access
      #   expired"), rendered into a member-facing phrase on delivery
      def announce_departure(invite, reason:)
        return if invite.nil?

        if @scheduler
          @scheduler.schedule(
            kind: DEPARTURE_KIND, run_at: Time.now,
            payload: { "invite_id" => invite.id, "reason" => reason.to_s }
          )
        else
          deliver_departure(invite, reason: reason)
        end
      end

      private

      def invite_from(job)
        id = (job.payload || {})["invite_id"]
        id && @models.guest_invite[id.to_i]
      end

      def reason_from(job) = (job.payload || {})["reason"] || "session ended"

      def deliver_join(invite)
        return if invite.nil?

        with_room(invite) { |room| post_all(room, "#{guest_label(invite)} joined the room as a guest.") }
      end

      def deliver_departure(invite, reason:)
        return if invite.nil?

        with_room(invite) { |room| post_all(room, "#{guest_label(invite)} #{departure_phrase(reason)}.") }
      end

      def guest_label(invite) = "#{invite.nickname} (guest)"

      def departure_phrase(reason)
        case reason.to_s
        when "invite revoked" then "left, access was revoked"
        when "access expired" then "left, access expired"
        else "left the room"
        end
      end

      def with_room(invite)
        return if @registry.nil?

        room = resolve_room(invite)
        return if room.nil?

        yield room
      rescue StandardError => e
        @logger&.warn { "guest announcer: broadcast for invite #{invite.id} failed: #{e.class}: #{e.message}" }
      end

      # The invite's room_id (a database id) resolved to its live Core::Room:
      # found by which room CONTAINS one of its real channel endpoints
      # (endpoint_key, unique across the whole install), never by room_key
      # (unique only WITHIN a community, could resolve the WRONG one) or the
      # room's synthetic guest endpoint (only exists while guest_portal is
      # enabled, and a departure notice can be due right after it was turned
      # off). Nil, logged, when the invite's room no longer exists or has no
      # live channel in the topology.
      def resolve_room(invite)
        channel_keys = @models.room[invite.room_id]&.channels&.map(&:endpoint_key) || []
        if channel_keys.empty?
          @logger&.warn { "guest announcer: room #{invite.room_id} no longer exists, dropping the notice" }
          return nil
        end

        room = @registry.current.topology.rooms.find { |candidate| channel_keys.any? { |key| candidate.include?(key) } }
        if room.nil?
          @logger&.warn { "guest announcer: room #{invite.room_id} has no live endpoints, dropping the notice" }
        end
        room
      end

      # Every endpoint the room fans a notice out to: {Core::Room}'s own fan-out
      # rule, with no origin to exclude, since the bot is authoring this.
      def post_all(room, text)
        room.targets_for(nil).each do |endpoint|
          adapter = @adapters[[endpoint.adapter_name, endpoint.account]]
          next if adapter.nil?

          adapter.deliver(build_message(endpoint, text), endpoint)
        rescue AdapterError => e
          @logger&.warn { "guest announcer: could not post to #{endpoint.id}: #{e.message}" }
        end
      end

      def build_message(endpoint, text)
        Core::Message.new(
          kind: :system,
          ref: Core::MessageRef.new(endpoint.id, "guest-notice-#{SecureRandom.hex(4)}"),
          origin: endpoint,
          author: Core::Author.new(display_name: @name, kind: :system),
          body: Core::RichText.plain(text),
          sender_label: @name
        )
      end
    end
  end
end
