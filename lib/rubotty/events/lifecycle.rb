# frozen_string_literal: true

require "digest"
require "json"
require "sequel"

module Rubotty
  module Events
    # The single driver of an event's side-effects: it watches the events table
    # and drives the announcer and the {Reminders} ladder, so both write
    # surfaces, /event in the bot and the dashboard form, behave the same.
    class Lifecycle
      # The state-store key holding the cursor, an epoch string.
      CURSOR_KEY = "events:lifecycle:cursor"

      # Prefix for one event's fingerprint key.
      FINGERPRINT_PREFIX = "events:lifecycle:fp:"

      # Fingerprint prefixes, so a poll can tell "was announced live, now gone",
      # which is a cancellation to broadcast, from "never was live".
      LIVE = "live"
      GONE = "gone"

      # @param models [ControlPlane::Models] bound to the control-plane database
      # @param announcer [Events::Announcer] broadcasts the card and drives the
      #   native mirror on create, update and cancel
      # @param reminders [Events::Reminders] the durable reminder ladder
      # @param store [#get_state, #put_state] holds the cursor and fingerprints
      # @param logger [#info, #warn, nil]
      # @param clock [#call] injectable time source, for a deterministic test
      def initialize(models:, announcer:, reminders:, store:, logger: nil, clock: -> { Time.now })
        @models = models
        @announcer = announcer
        @reminders = reminders
        @store = store
        @logger = logger
        @clock = clock
      end

      # One poll: reconcile every event at or after the cursor, then advance
      # the cursor, returning how many rows it saw. The window is inclusive,
      # so a row written in the cursor's own second is never skipped.
      def check
        cursor = read_cursor
        floor = Time.at(cursor)
        rows = @models.event.where { updated_at >= floor }.order(:updated_at, :id).all
        return 0 if rows.empty?

        max_seen = cursor
        clean = true
        rows.each do |row|
          reconcile(Event.new(row))
          epoch = updated_epoch(row)
          max_seen = epoch if epoch > max_seen
        rescue StandardError => e
          clean = false
          @logger&.warn { "events lifecycle: reconciling event #{row[:id]} failed: #{e.class}: #{e.message}" }
        end
        # Only advance past a clean pass, so a failure retries the whole window.
        write_cursor(max_seen) if clean && max_seen > cursor
        rows.size
      rescue Sequel::Error => e
        @logger&.warn { "events lifecycle: could not read the events table: #{e.message}" }
        0
      end

      private

      # Drive the side-effects for one event, exactly once per distinct state.
      def reconcile(event)
        key = FINGERPRINT_PREFIX + event.id.to_s
        desired = fingerprint(event)
        stored = @store.get_state(key)
        return if stored == desired

        if event.scheduled?
          announce_live(event, stored)
        else
          announce_gone(event, stored)
        end
        @store.put_state(key, desired)
      end

      # A scheduled event: a create the first time unless a prior path already
      # broadcast it, an update whenever its fingerprint moves after that.
      def announce_live(event, stored)
        if stored.nil?
          @announcer.announce_created(event) unless already_broadcast?(event)
        else
          @announcer.announce_updated(event)
        end
        @reminders.schedule_for(event)
      end

      # A cancelled or completed event: retract it only if it was ever announced
      # as live. The reminder ladder is withdrawn regardless.
      def announce_gone(event, stored)
        @announcer.announce_cancelled(event) if stored&.start_with?(LIVE)
        @reminders.cancel_for(event)
      end

      # The salient shape of an event, hashed and prefixed live or gone.
      # native_refs and event_cards are excluded because the announcer writes
      # them, so folding them in would let announcing move its own gate.
      def fingerprint(event)
        salient = [
          event.title, event.description, event.timezone, event.kind,
          event.game_title, event.server_address, event.url, event.rsvp_mode,
          event.starts_at&.to_i, event.ends_at&.to_i,
          JSON.generate(event.reminder_intervals), event.recurrence_interval
        ].join("")
        "#{event.scheduled? ? LIVE : GONE}:#{Digest::SHA256.hexdigest(salient)}"
      end

      # A tracked card copy is evidence the event was announced before, so it is
      # adopted rather than re-announced.
      def already_broadcast?(event)
        @models.event_card.where(event_id: event.id).limit(1).any?
      rescue StandardError
        false
      end

      def read_cursor
        raw = @store.get_state(CURSOR_KEY)
        raw.nil? ? 0 : raw.to_i
      rescue StandardError => e
        @logger&.warn { "events lifecycle: could not read the cursor: #{e.message}" }
        0
      end

      def write_cursor(epoch)
        @store.put_state(CURSOR_KEY, epoch.to_i.to_s)
      rescue StandardError => e
        @logger&.warn { "events lifecycle: could not persist the cursor: #{e.message}" }
      end

      # The row's updated_at as an epoch, whether Sequel handed back a Time or a
      # string.
      def updated_epoch(row)
        value = row[:updated_at]
        (value.respond_to?(:to_time) ? value.to_time : Time.parse(value.to_s)).to_i
      end
    end
  end
end
