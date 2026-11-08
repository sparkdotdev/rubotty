# frozen_string_literal: true

require "time"
require "json"
require "date"
require "sequel"

module Rubotty
  module ControlPlane
    # Create, cancel and list events: the write side of {Events::Event},
    # gated by {EventPolicy}. A pure writer: no announcing, no reminders, no
    # native mirror; {Events::Lifecycle} drives those by watching this table.
    # {#create} enforces the room's "events" feature and the issuer's
    # who_can_create; starts_at/ends_at are stored UTC. +timezone+ is the
    # IANA zone in which a bare start is read, whether that start is relative
    # ("tomorrow 4pm") or absolute ("2026-08-16 20:00"). An explicit UTC
    # marker or numeric offset always wins over the selected zone.
    class EventScheduling
      # Raised for a request that cannot be carried out. Carries a human message.
      class Invalid < Rubotty::Error; end

      # Distinguishes "not passed to {#update}" from "passed as nil (clear it)",
      # since nil is meaningful for the optional columns.
      UNSET = Object.new.freeze

      # A local wall-clock reading that the selected timezone skips during a
      # spring-forward transition. It must not fall through to a UTC parse.
      InvalidLocalTime = Class.new(StandardError)

      # @param models [ControlPlane::Models] bound to the control-plane database
      # @param policy [EventPolicy] the room policy resolver; a real one over
      #   +models+ by default, injectable for a test double
      # @param logger [#info, nil]
      # @param clock [#call] injectable time source, for deterministic tests
      def initialize(models:, policy: nil, logger: nil, clock: -> { Time.now })
        @models = models
        @policy = policy || EventPolicy.new(models: models)
        @logger = logger
        @clock = clock
      end

      # Create an event in +room+, enforcing both gates above. game_title and
      # server_address apply only to a "gaming" kind, url only to "general";
      # the other kind's fields are ignored rather than rejected.
      #
      # @param native_refs [Hash, nil] platform => native id, set only by
      #   {Events::NativeMirror} to mark an event as mirrored in
      # @param reminder_intervals [Array<Integer>, nil] nil means "use the
      #   community/room default"; an empty array means no reminders at all
      def create(community:, room:, as:, title:, starts_at:, kind:, timezone: nil, ends_at: nil,
                 game_title: nil, server_address: nil, url: nil, description: nil,
                 rsvp_mode: Events::Event::RSVP_NONE, created_by: nil, native_refs: nil,
                 reminder_intervals: nil, recurrence_interval: nil)
        unless room && room.community_id == community.id
          raise Invalid, "that room does not belong to this community."
        end

        policy = @policy.room_policy(community: community, room: room)
        raise Invalid, "events are not enabled in that room." unless policy[:enabled]
        unless @policy.permitted?(policy[:who_can_create], as)
          raise Invalid, "only operators may create an event in that room."
        end

        clean_title = presence(title)
        raise Invalid, "an event needs a title." if clean_title.nil?

        effective_zone = presence(timezone) || "UTC"
        start_time = coerce_time(starts_at, effective_zone)
        raise Invalid, "an event needs a valid start time." if start_time.nil?

        end_time = ends_at ? coerce_time(ends_at, effective_zone) : nil
        raise Invalid, "could not understand the end time." if ends_at && end_time.nil?
        raise Invalid, "the end time must be after the start time." if end_time && end_time <= start_time

        kind_value = kind.to_s.strip.downcase
        unless Events::Event::KINDS.include?(kind_value)
          raise Invalid, "kind must be #{Events::Event::KINDS.join(" or ")}."
        end

        rsvp_value = presence(rsvp_mode) || Events::Event::RSVP_NONE
        rsvp_value = rsvp_value.downcase
        unless Events::Event::RSVP_MODES.include?(rsvp_value)
          raise Invalid, "rsvp_mode must be one of #{Events::Event::RSVP_MODES.join(", ")}."
        end

        gaming = kind_value == Events::Event::KIND_GAMING
        now = @clock.call
        row = @models.event.create(
          community_id: community.id,
          room_id: room.id,
          title: clean_title[0, 200],
          description: presence(description),
          starts_at: to_stored(start_time),
          ends_at: end_time && to_stored(end_time),
          timezone: presence(timezone),
          kind: kind_value,
          game_title: gaming ? presence(game_title) : nil,
          server_address: gaming ? presence(server_address) : nil,
          url: gaming ? nil : presence(url),
          rsvp_mode: rsvp_value,
          status: Events::Event::STATUS_SCHEDULED,
          created_by: presence(created_by),
          native_refs: native_refs ? JSON.generate(native_refs) : "{}",
          reminder_intervals: store_reminder_intervals(reminder_intervals),
          recurrence_interval: coerce_recurrence_interval(recurrence_interval),
          created_at: now,
          updated_at: now
        )
        @logger&.info do
          "event created: community=#{community.slug} room=#{room.room_key} " \
            "title=#{clean_title.inspect} starts_at=#{start_time.iso8601}"
        end
        Events::Event.new(row)
      end

      # Cancel an event. Idempotent: cancelling an already-cancelled or
      # completed event is a harmless no-op that leaves the row as it was.
      #
      # @param event [Events::Event, Models::Event]
      # @return [Events::Event]
      def cancel(event:)
        row = event.is_a?(Events::Event) ? event.row : event
        was_scheduled = row.status == Events::Event::STATUS_SCHEDULED
        if was_scheduled
          row.update(status: Events::Event::STATUS_CANCELLED, updated_at: @clock.call)
          @logger&.info { "event cancelled: id=#{row.id}" }
        end
        Events::Event.new(row)
      end

      # Update an event's mutable fields and bump updated_at so
      # {Events::Lifecycle} re-broadcasts. A call that changes nothing writes
      # nothing, so a no-op never churns the detector.
      #
      # @param event [Events::Event, Models::Event]
      # @return [Events::Event]
      def update(event:, title: UNSET, starts_at: UNSET, ends_at: UNSET,
                 description: UNSET, timezone: UNSET, url: UNSET,
                 reminder_intervals: UNSET, recurrence_interval: UNSET)
        row = event.is_a?(Events::Event) ? event.row : event
        changes = {}

        unless title.equal?(UNSET)
          clean = presence(title)
          raise Invalid, "an event needs a title." if clean.nil?

          changes[:title] = clean[0, 200]
        end

        # The zone a bare starts_at/ends_at is read against: the new timezone
        # when this same call is also changing it, else whatever the event
        # already carries, else UTC. An edit that leaves timezone alone must
        # resolve a bare time the same way the original create did.
        effective_zone = presence(timezone.equal?(UNSET) ? row.timezone : timezone) || "UTC"

        unless starts_at.equal?(UNSET)
          start_time = coerce_time(starts_at, effective_zone)
          raise Invalid, "an event needs a valid start time." if start_time.nil?

          changes[:starts_at] = to_stored(start_time)
        end

        unless ends_at.equal?(UNSET)
          if ends_at.nil?
            changes[:ends_at] = nil
          else
            end_time = coerce_time(ends_at, effective_zone)
            raise Invalid, "could not understand the end time." if end_time.nil?

            changes[:ends_at] = to_stored(end_time)
          end
        end

        unless starts_at.equal?(UNSET) && ends_at.equal?(UNSET)
          existing = Events::Event.new(row)
          effective_starts = changes[:starts_at] || existing.starts_at
          effective_ends = changes.key?(:ends_at) ? changes[:ends_at] : existing.ends_at
          if effective_ends && effective_ends <= effective_starts
            raise Invalid, "the end time must be after the start time."
          end
        end

        changes[:description] = presence(description) unless description.equal?(UNSET)
        changes[:timezone] = presence(timezone) unless timezone.equal?(UNSET)
        changes[:url] = presence(url) unless url.equal?(UNSET)
        unless reminder_intervals.equal?(UNSET)
          changes[:reminder_intervals] = store_reminder_intervals(reminder_intervals)
        end
        unless recurrence_interval.equal?(UNSET)
          changes[:recurrence_interval] = coerce_recurrence_interval(recurrence_interval)
        end

        return Events::Event.new(row) if changes.empty?

        changes[:updated_at] = @clock.call
        row.update(changes)
        @logger&.info { "event updated: id=#{row.id} fields=#{changes.keys.join(",")}" }
        Events::Event.new(row)
      end

      # Cancel by id within a community, or nil. The scoping stops a caller
      # cancelling another community's event by id.
      def cancel_by_id(community:, id:)
        row = @models.event.where(community_id: community.id, id: id).first
        row && cancel(event: row)
      end

      # A single event within a community, or nil.
      def find(community:, id:)
        row = @models.event.where(community_id: community.id, id: id).first
        row && Events::Event.new(row)
      end

      # Every scheduled event not yet started, soonest first, across the whole
      # community, or just +room+ when given (the /events command's bare
      # listing). The bound is applied in SQL, so it holds on every backend
      # rather than depending on the zone a timestamp is read back in.
      def upcoming(community:, room: nil)
        now = @clock.call
        scope = @models.event.where(community_id: community.id, status: Events::Event::STATUS_SCHEDULED)
        scope = scope.where(room_id: room.id) if room
        scope.where { starts_at >= now }
             .order(:starts_at)
             .all
             .map { |row| Events::Event.new(row) }
      end

      # The community row for an id, so the /event chat command needs no Models
      # handle of its own.
      def community_by_id(id)
        @models.community[id]
      end

      # The room a channel named by endpoint_key is bridged into, or nil. Public
      # because the /event command has only a Snapshot::Channel, which carries an
      # endpoint_key. A channel briefly links into two rooms while an operator
      # moves it between them, so the newest join wins rather than an
      # unordered #first: it is the mapping the operator just made.
      def room_for_endpoint_key(community:, endpoint_key:)
        channel = @models.channel.where(community_id: community.id, endpoint_key: endpoint_key.to_s).first
        return nil if channel.nil?

        join = @models.room_channel.where(channel_id: channel.id).order(Sequel.desc(:id)).first
        join && @models.room[join.room_id]
      end

      # A UTC Time, or nil when +value+ is blank or unparsable.
      #
      # {RelativeTime}'s bounded vocabulary ("now", "6 hours", "tomorrow
      # 4pm", ...) is tried first, read against +timezone+ (UTC when that
      # is blank or unrecognised); anything else falls through to an
      # absolute calendar reading, read in +timezone+ unless it carries its
      # own "Z", "UTC", or numeric offset.
      def self.parse_time(value, timezone: nil, now: Time.now)
        return value.utc if value.is_a?(Time)

        text = value.to_s.strip
        return nil if text.empty?

        return Time.parse(text).utc if explicit_zone?(text)

        relative = RelativeTime.parse(text, timezone: timezone, now: now)
        return relative if relative

        local_absolute(text, timezone: timezone, now: now) || Time.parse("#{text} UTC").utc
      rescue InvalidLocalTime, ArgumentError, TypeError, Date::Error
        nil
      end

      # @api private
      # Whether +text+ supplies an instant of its own rather than a wall clock
      # to read in the selected timezone. Keep this deliberately narrow: a
      # bare "2026-08-16 20:00" is local, while the three explicit forms users
      # are told to use remain portable between every deployment.
      def self.explicit_zone?(text)
        text.match?(/(?:z|utc|gmt|[+-]\d{2}:?\d{2})\z/i)
      end

      # @api private
      # Read an absolute wall-clock date or time in +timezone+. Date._parse
      # gives us calendar fields without consulting the host's process zone;
      # TZInfo then applies the offset on that particular day, including DST.
      # A repeated autumn clock hour resolves to standard time, matching
      # RelativeTime, while a spring-forward gap is invalid rather than guessed.
      def self.local_absolute(text, timezone:, now:)
        fields = Date._parse(text, false)
        return nil if fields.empty? || (fields.keys & %i[year mon mday hour min sec]).empty?

        zone = RelativeTime.resolve_zone(timezone)
        current = zone.utc_to_local(now.utc)
        local = Time.utc(
          fields.fetch(:year, current.year), fields.fetch(:mon, current.month),
          fields.fetch(:mday, current.day), fields.fetch(:hour, 0),
          fields.fetch(:min, 0), fields.fetch(:sec, 0)
        )
        zone.local_to_utc(local, false) { |periods| periods.last }.utc
      rescue TZInfo::PeriodNotFound
        raise InvalidLocalTime
      end

      private

      def coerce_time(value, timezone)
        return value.utc if value.is_a?(Time)

        self.class.parse_time(value, timezone: timezone, now: @clock.call)
      end

      # Storage::Factory pins Sequel to UTC on both knobs, so a Time is converted
      # on the way in whatever zone it carries and comes back UTC.
      def to_stored(time)
        time.getutc
      end

      def presence(value)
        return nil if value.nil?

        string = value.to_s.strip
        string.empty? ? nil : string
      end

      # nil (use the community/room default) stores as nil; anything else,
      # including an empty array (explicitly no reminders), stores as its own
      # validated JSON ladder.
      def store_reminder_intervals(value)
        return nil if value.nil?

        JSON.generate(coerce_reminder_intervals(value))
      end

      # Every entry a whole number of seconds greater than zero. Raises on the
      # first one that is not, so a typo never scheduled a reminder at all is
      # reported instead of silently dropped.
      def coerce_reminder_intervals(value)
        Array(value).map do |entry|
          seconds = entry.is_a?(Integer) ? entry : Integer(entry.to_s, exception: false)
          raise Invalid, "reminder_intervals must be whole seconds greater than zero." if seconds.nil? || seconds <= 0

          seconds
        end
      end

      # nil (no recurrence) passes straight through; anything else must be a
      # whole number of seconds greater than zero.
      def coerce_recurrence_interval(value)
        return nil if value.nil?

        seconds = value.is_a?(Integer) ? value : Integer(value.to_s, exception: false)
        raise Invalid, "repeat must be a whole number of seconds greater than zero." if seconds.nil? || seconds <= 0

        seconds
      end
    end
  end
end
