# frozen_string_literal: true

require "json"
require "yamlcamel"
require "time"
require "uri"
require "securerandom"

module Rubotty
  module ControlPlane
    # Webhook subscriptions and the queue of what is owed to each of them;
    # {WebhookPump} does the sending, and the relay path only ever writes
    # here, via {#emit}, never raising. Sending runs on Core::DurableScheduler:
    # one recurring {PUMP_KIND} job per subscription serialises deliveries,
    # and one {RECONCILE_KIND} job matches that set to active subscriptions.
    # A failed send is recorded on the delivery row rather than failing the
    # pump job, which would exhaust its attempts and orphan the subscription.
    # Every read here is scoped to a community in the WHERE clause.
    class Webhooks
      # Raised for a request an operator has to be told about.
      class Invalid < Rubotty::Error; end

      # Durable scheduler kinds, namespaced in a table shared with every other job.
      PUMP_KIND = "webhook.pump"
      RECONCILE_KIND = "webhook.reconcile"

      # Seconds between wakeups of a subscription's pump.
      PUMP_INTERVAL = 10

      # Seconds between reconciles, so the worst case before a subscription
      # created on the dashboard starts receiving.
      RECONCILE_INTERVAL = 60

      # Seconds after boot before the first reconcile. Short, because the schedule
      # is rebuilt on every start and a frequent redeploy would never reach it.
      FIRST_RECONCILE = 15

      # Attempts before a delivery is dead lettered, matching the scheduler's default.
      MAX_ATTEMPTS = 5

      # Backoff base and ceiling, both matching Core::DurableScheduler's.
      RETRY_BACKOFF = 10.0
      MAX_RETRY_BACKOFF = 3600.0

      # How long a delivery row is kept, and the only bound on the table: the
      # payload column holds message text, so this is a privacy bound as well
      # as a disk one (see PRIVACY.md). There is deliberately no row cap on
      # top, since evicting the oldest would take queued deliveries the pump
      # still owes a retry to.
      RETENTION = 14 * 24 * 60 * 60

      # Seconds the previous secret keeps working after a rotation that names no
      # window, and the ceiling on any window.
      DEFAULT_OVERLAP = 24 * 60 * 60
      MAX_OVERLAP = 30 * 24 * 60 * 60

      # The event types a subscription may ask for. Closed, so an unknown
      # type is rejected at creation time instead of leaving a subscriber
      # waiting; see Features::Bridge#notify_webhooks and
      # #notify_webhooks_change for where each is actually queued.
      MESSAGE_RELAYED = "message.relayed"
      MESSAGE_EDITED = "message.edited"
      MESSAGE_DELETED = "message.deleted"
      REACTION_ADDED = "reaction.added"
      REACTION_REMOVED = "reaction.removed"
      MEMBER_JOINED = "member.joined"
      MEMBER_LEFT = "member.left"
      EVENT_TYPES = [
        MESSAGE_RELAYED, MESSAGE_EDITED, MESSAGE_DELETED,
        REACTION_ADDED, REACTION_REMOVED, MEMBER_JOINED, MEMBER_LEFT
      ].freeze

      # Seconds a resolved subscription list is reused before a fresh read.
      CACHE_TTL = 5

      # How much message text an envelope carries.
      MAX_TEXT = 4000

      URL_MAX = 1000
      LABEL_MAX = 200

      # A new subscription with its raw secret, which is returned here and on
      # {#rotate} and nowhere else.
      Created = Struct.new(:row, :secret, keyword_init: true)

      # @param models [ControlPlane::Models] bound to the control-plane database
      # @param logger [#info, #warn, nil]
      # @param clock [#call] injectable time source, for deterministic tests
      def initialize(models:, logger: nil, clock: -> { Time.now })
        @models = models
        @logger = logger
        @clock = clock
        @cache = {}
        @cache_mutex = Mutex.new
      end

      # The event types on a subscription row, decoded. On the class so a view
      # can read them without a service instance.
      def self.event_types_of(row)
        parsed = JSON.parse(row.event_types.to_s)
        parsed.is_a?(Array) ? parsed.map(&:to_s) : []
      rescue JSON::ParserError
        []
      end

      # This community's subscriptions, newest first.
      def list(community_id:) = scope(community_id).reverse(:id).all

      # One subscription by its public id, or nil.
      def find(community_id:, public_id:)
        scope(community_id).where(public_id: public_id.to_s).first
      end

      # Register a subscriber.
      #
      # @param event_types [Array<String>] which events it wants
      # @param room_key [String] one room, or empty for every room
      # @return [Created] the row and its raw signing secret
      def create(community_id:, url:, event_types:, room_key: "", label: "")
        address = clean_url(url)
        wanted = clean_event_types(event_types)
        secret = WebhookSignature.generate_secret
        now = @clock.call
        row = @models.webhook_subscription.create(
          community_id: community_id, public_id: SecureRandom.uuid,
          url: address, label: label.to_s.strip[0, LABEL_MAX].to_s,
          event_types: JSON.generate(wanted), room_key: room_key.to_s[0, 128].to_s,
          secret: secret, active: true, created_at: now, updated_at: now
        )
        invalidate(community_id)
        @logger&.info { "webhooks: subscription #{row.public_id} created for #{redacted(address)}" }
        Created.new(row: row, secret: secret)
      end

      # Turn a subscription on or off without losing it or its history.
      def set_active(community_id:, public_id:, active:)
        row = find(community_id: community_id, public_id: public_id)
        return nil if row.nil?

        row.update(active: active ? true : false, updated_at: @clock.call)
        invalidate(community_id)
        row
      end

      # Delete a subscription. Its deliveries go with it, the foreign key cascades.
      #
      # @return [Boolean] whether anything was removed
      def delete(community_id:, public_id:)
        removed = scope(community_id).where(public_id: public_id.to_s).delete.to_i.positive?
        invalidate(community_id)
        removed
      end

      # Mint a new signing secret, keeping the old one valid for +overlap+ seconds.
      # Until the deadline every delivery carries both signatures, so the
      # subscriber can switch over whenever it likes.
      #
      # @param overlap [Integer] seconds the previous secret keeps working
      # @return [Created] the row and the NEW raw secret
      def rotate(community_id:, public_id:, overlap: DEFAULT_OVERLAP)
        row = find(community_id: community_id, public_id: public_id)
        raise Invalid, "no such subscription." if row.nil?

        window = overlap.to_i.clamp(0, MAX_OVERLAP)
        secret = WebhookSignature.generate_secret
        now = @clock.call
        row.update(
          secret: secret,
          previous_secret: row.secret,
          # A zero window retires the old secret at once, for rotating a leaked one.
          previous_secret_expires_at: window.positive? ? now + window : nil,
          updated_at: now
        )
        invalidate(community_id)
        @logger&.info { "webhooks: subscription #{row.public_id} rotated, overlap #{window}s" }
        Created.new(row: row, secret: secret)
      end

      # The secrets a delivery is signed with now: the current one, plus the
      # previous one while its window is open.
      def secrets_for(row, now: @clock.call)
        secrets = [row.secret]
        deadline = row.previous_secret_expires_at
        previous = row.previous_secret
        secrets << previous if previous && !previous.to_s.empty? && deadline && now < deadline
        secrets
      end

      # Whether a rotation window is still open, for the views that say so.
      def rotating?(row, now: @clock.call) = secrets_for(row, now: now).length > 1

      # Queue one event for every subscription that wants it. Called on a room's
      # worker thread, so it must never raise; the rescue is the whole contract.
      #
      # @param data [Hash] the event's own body
      # @return [Integer] deliveries queued
      def emit(community_id:, event_type:, data:, room_key: "")
        return 0 if community_id.nil?

        subscriptions = wanting(community_id: community_id, event_type: event_type, room_key: room_key)
        return 0 if subscriptions.empty?

        now = @clock.call
        subscriptions.count do |row|
          queue(subscription: row, community_id: community_id, event_type: event_type,
                room_key: room_key, data: data, now: now)
        end
      rescue StandardError => e
        @logger&.warn { "webhooks: could not queue #{event_type}: #{e.class}: #{e.message}" }
        0
      end

      # The envelope, as the bytes that get signed and sent. Standard Webhooks
      # covers the headers and signature; the body format is ours.
      def envelope(event_id:, event_type:, data:, now:)
        YAMLCamel.dump({
          "id" => event_id, "type" => event_type,
          "timestamp" => now.utc.iso8601,
          "data" => stringify(data)
        })
      end

      # The next delivery this subscription owes, or nil. Oldest first and only
      # what is due, so one waiting out a backoff holds the queue in order.
      def next_due(subscription_id:, now: @clock.call)
        @models.webhook_delivery
               .where(subscription_id: subscription_id, status: "queued")
               .where { next_attempt_at <= now }
               .order(:id).first
      end

      # Record a delivery that landed.
      def delivered(row, response_status:, now: @clock.call)
        row.update(status: "delivered", response_status: response_status.to_i,
                   attempts: row.attempts.to_i + 1, delivered_at: now, last_error: nil)
      end

      # Record an attempt that did not land. At {MAX_ATTEMPTS} the delivery is dead
      # lettered so one broken event cannot block every later event.
      #
      # @return [Boolean] whether it will be tried again
      def failed(row, error:, response_status: nil, now: @clock.call)
        attempts = row.attempts.to_i + 1
        message = error.to_s[0, 500]
        if attempts >= MAX_ATTEMPTS
          row.update(status: "failed", attempts: attempts, last_error: message,
                     response_status: response_status&.to_i)
          @logger&.warn do
            "webhooks: delivery #{row.event_id} to subscription #{row.subscription_id} " \
              "dead lettered after #{attempts} attempt(s): #{message}"
          end
          false
        else
          row.update(status: "queued", attempts: attempts, last_error: message,
                     response_status: response_status&.to_i,
                     next_attempt_at: now + backoff(attempts))
          true
        end
      end

      # The exponential backoff before attempt +attempts+ + 1, capped.
      def backoff(attempts) = [RETRY_BACKOFF * (2**(attempts - 1)), MAX_RETRY_BACKOFF].min

      # This community's deliveries, newest first, optionally narrowed to one
      # status or one subscription.
      def deliveries(community_id:, status: nil, subscription_id: nil, limit: 200)
        dataset = @models.webhook_delivery.where(community_id: community_id)
        dataset = dataset.where(status: status.to_s) unless status.nil?
        dataset = dataset.where(subscription_id: subscription_id) unless subscription_id.nil?
        dataset.reverse(:id).limit(limit.to_i.clamp(1, 1000)).all
      end

      # How many of this community's deliveries are dead lettered.
      def failed_count(community_id:)
        @models.webhook_delivery.where(community_id: community_id, status: "failed").count
      end

      # Put a dead-lettered delivery back on the queue with its attempts reset.
      # Only a failed delivery matches, so this cannot disturb one mid-backoff.
      #
      # @return [Boolean] whether anything was requeued
      def retry_delivery(id:, community_id:)
        @models.webhook_delivery
               .where(id: id, community_id: community_id, status: "failed")
               .update(status: "queued", attempts: 0, next_attempt_at: @clock.call, last_error: nil)
               .to_i.positive?
      end

      # Drop delivery rows past {RETENTION}, everywhere.
      #
      # @return [Integer] rows removed
      def prune(now: @clock.call)
        cutoff = now - RETENTION
        @models.webhook_delivery.where { created_at <= cutoff }.delete.to_i
      end

      # Square the set of pump jobs against the set of active subscriptions.
      # Idempotent, and the only thing that creates or removes a pump.
      #
      # @param scheduler [Core::DurableScheduler]
      # @return [Integer] pumps added
      def reconcile_pumps(scheduler:, now: @clock.call)
        return 0 if scheduler.nil?

        wanted = @models.webhook_subscription.where(active: true).select_map(%i[id community_id])
        wanted_ids = wanted.map(&:first)

        # One pass noting what already has a drainer and cancelling what should
        # not: pumps for gone subscriptions, and duplicates from the race below.
        kept = []
        scheduler.cancel(kind: PUMP_KIND, every_community: true) do |payload|
          id = payload["subscription_id"]
          next true unless wanted_ids.include?(id)
          next true if kept.include?(id)

          kept << id
          false
        end

        # A pump claimed right now is invisible above and gets a duplicate. The
        # drain lock still serialises them and the next reconcile drops the spare.
        wanted.reject { |id, _| kept.include?(id) }.count do |id, community_id|
          scheduler.schedule(
            kind: PUMP_KIND, run_at: now + PUMP_INTERVAL, recurrence: PUMP_INTERVAL,
            payload: { "subscription_id" => id }, community: community_slug(community_id)
          )
          true
        end
      end

      private

      def scope(community_id) = @models.webhook_subscription.where(community_id: community_id)

      def community_slug(community_id)
        @models.community.where(id: community_id).get(:slug)
      end

      # The active subscriptions in this community that want this event.
      def wanting(community_id:, event_type:, room_key:)
        cached(community_id).select do |row|
          next false unless row[:event_types].include?(event_type.to_s)
          # An empty room_key on the subscription means every room.
          row[:room_key].empty? || row[:room_key] == room_key.to_s
        end
      end

      # This community's active subscriptions as plain hashes, refreshed at most
      # once per {CACHE_TTL}. Hashes, so nobody can write through a cached row.
      def cached(community_id)
        now = @clock.call
        @cache_mutex.synchronize do
          entry = @cache[community_id]
          return entry[:rows] if entry && (now - entry[:at]) < CACHE_TTL

          rows = scope(community_id).where(active: true).all.map do |row|
            { id: row.id, room_key: row.room_key.to_s, event_types: decode_types(row.event_types) }
          end
          @cache[community_id] = { at: now, rows: rows }
          rows
        end
      end

      def invalidate(community_id)
        @cache_mutex.synchronize { @cache.delete(community_id) }
      end

      # Write one queued delivery. The envelope is built and stored here once, so
      # a retry sends byte-for-byte what the first attempt sent.
      def queue(subscription:, community_id:, event_type:, room_key:, data:, now:)
        event_id = "msg_#{SecureRandom.urlsafe_base64(18)}"
        @models.webhook_delivery.create(
          community_id: community_id, subscription_id: subscription[:id],
          event_id: event_id, event_type: event_type.to_s, room_key: room_key.to_s[0, 128].to_s,
          payload: envelope(event_id: event_id, event_type: event_type, data: data, now: now),
          status: "queued", attempts: 0, next_attempt_at: now, created_at: now
        )
        true
      end

      def decode_types(raw)
        parsed = JSON.parse(raw.to_s)
        parsed.is_a?(Array) ? parsed.map(&:to_s) : []
      rescue JSON::ParserError
        []
      end

      def clean_url(url)
        text = url.to_s.strip
        raise Invalid, "a webhook needs a URL." if text.empty?
        raise Invalid, "a webhook URL is longer than #{URL_MAX} characters." if text.length > URL_MAX

        uri = begin
          URI.parse(text)
        rescue URI::InvalidURIError
          raise Invalid, "that is not a URL rubotty can post to."
        end
        raise Invalid, "a webhook URL has to be https." unless uri.is_a?(URI::HTTPS)

        text
      end

      def clean_event_types(types)
        list = Array(types).flat_map { |value| value.to_s.split(",") }.map(&:strip).reject(&:empty?).uniq
        raise Invalid, "a webhook needs at least one event type." if list.empty?

        unknown = list - EVENT_TYPES
        raise Invalid, "unknown event type(s): #{unknown.join(", ")}." if unknown.any?

        list
      end

      # Keys as strings, so an envelope never depends on a Ruby object's own dump.
      def stringify(data)
        return {} unless data.is_a?(Hash)

        data.each_with_object({}) do |(key, value), out|
          out[key.to_s] = value.is_a?(Hash) ? stringify(value) : value
        end
      end

      def redacted(url) = Util::SafeUrl.redact(url)
    end
  end
end
