# frozen_string_literal: true

require "time"

module Rubotty
  module ControlPlane
    # Open, extend and close a poll: a pure writer, like {EventScheduling}. The
    # deadline runs from when the poll opened, never from the room's last message.
    class Polls
      # Carries a human message the command surfaces print as-is.
      class Invalid < Rubotty::Error; end

      # @param models [ControlPlane::Models] bound to the control-plane database
      # @param logger [#info, nil]
      # @param clock [#call] injectable time source, for deterministic tests
      def initialize(models:, logger: nil, clock: -> { Time.now })
        @models = models
        @logger = logger
        @clock = clock
      end

      # @param room [Models::Room] must belong to +community+
      # @param timezone [String, nil] the zone a session's slots were worked out
      #   in, kept so a later suggestion is read the same way
      # @return [Rubotty::Polls::Poll]
      def open(community:, room:, kind:, question:, options:, detail: nil, timezone: nil,
               multi_select: false, reply_votes: true, reply_options: false,
               duration_hours: Rubotty::Polls::Poll::DEFAULT_DURATION_HOURS, created_by: nil)
        unless room && room.community_id == community.id
          raise Invalid, "that room does not belong to this community."
        end

        kind_value = kind.to_s.strip.downcase
        unless Rubotty::Polls::Poll::KINDS.include?(kind_value)
          raise Invalid, "kind must be #{Rubotty::Polls::Poll::KINDS.join(" or ")}."
        end

        clean_question = presence(question)
        raise Invalid, "a poll needs a question." if clean_question.nil?

        hours = duration_hours.to_i
        unless Rubotty::Polls::Poll::DURATION_HOURS.include?(hours)
          raise Invalid, "duration must be one of #{Rubotty::Polls::Poll::DURATION_TOKENS.join(", ")}."
        end

        entries = Array(options).map { |entry| normalise_option(entry) }.compact
        raise Invalid, "a poll needs at least two options." if entries.size < 2
        if entries.size > Rubotty::Polls::Poll::MAX_OPTIONS
          raise Invalid, "a poll takes at most #{Rubotty::Polls::Poll::MAX_OPTIONS} options."
        end

        now = @clock.call
        row = @models.poll.create(
          community_id: community.id, room_id: room.id, kind: kind_value,
          question: clean_question[0, 500], detail: presence(detail), timezone: presence(timezone),
          multi_select: !!multi_select, reply_votes: !!reply_votes, reply_options: !!reply_options,
          closes_at: (now + (hours * 3600)).getutc, status: Rubotty::Polls::Poll::STATUS_OPEN,
          created_by: presence(created_by), created_at: now, updated_at: now
        )
        poll = Rubotty::Polls::Poll.new(row)
        entries.each_with_index { |entry, index| write_option(poll, entry, index + 1, now) }
        @logger&.info do
          "poll opened: id=#{poll.id} kind=#{kind_value} room=#{room.room_key} " \
            "options=#{entries.size} closes_at=#{poll.closes_at.iso8601}"
        end
        poll
      end

      # @param poll [Rubotty::Polls::Poll]
      # @param label [String]
      # @param starts_at [Time, nil] the instant a scheduling slot names
      # @param suggested_by [String, nil] whoever asked for it
      # @return [Rubotty::Polls::Option]
      # @raise [Invalid] when the poll is closed, full, or already carries this
      def add_option(poll:, label:, starts_at: nil, suggested_by: nil)
        raise Invalid, "that poll has already closed." unless poll.open?

        clean = presence(label)
        raise Invalid, "an option needs some text." if clean.nil?

        existing = options(poll)
        if existing.size >= Rubotty::Polls::Poll::MAX_OPTIONS
          raise Invalid, "that poll already has all #{Rubotty::Polls::Poll::MAX_OPTIONS} options it can hold."
        end
        if existing.any? { |option| same_option?(option, clean, starts_at) }
          raise Invalid, "that option is already on the list."
        end

        row = write_option(
          poll, { label: clean, starts_at: starts_at, suggested_by: presence(suggested_by) },
          existing.size + 1, @clock.call
        )
        touch(poll)
        Rubotty::Polls::Option.new(row)
      end

      # @return [Array<Rubotty::Polls::Option>] in the order they were added
      def options(poll)
        @models.poll_option.where(poll_id: poll.id).order(:position, :id).all
              .map { |row| Rubotty::Polls::Option.new(row) }
      end

      # The option at a 1-based position, or nil.
      def option_at(poll, position)
        options(poll).find { |option| option.position == position.to_i }
      end

      # Idempotent, which is what stops two workers both posting the results.
      #
      # @return [Boolean] whether this call is the one that closed it
      def close(poll:)
        return false unless poll.open?

        changed = @models.poll.where(id: poll.id, status: Rubotty::Polls::Poll::STATUS_OPEN)
                         .update(status: Rubotty::Polls::Poll::STATUS_CLOSED, updated_at: @clock.call)
        return false unless changed == 1

        poll.row.refresh
        @logger&.info { "poll closed: id=#{poll.id}" }
        true
      end

      # What the repost cadence is measured from.
      def mark_posted(poll:, at: nil)
        poll.row.update(last_posted_at: (at || @clock.call).getutc)
        true
      rescue StandardError => e
        @logger&.warn { "polls: could not record the repost time for poll #{poll.id}: #{e.message}" }
        false
      end

      # Scoped, so a caller cannot reach another community's poll by id.
      def find(community:, id:)
        row = @models.poll.where(community_id: community.id, id: id).first
        row && Rubotty::Polls::Poll.new(row)
      end

      # For a durable job that already knows which poll it holds.
      def by_id(id)
        row = @models.poll[id]
        row && Rubotty::Polls::Poll.new(row)
      end

      def community_by_id(id)
        @models.community[id]
      end

      # Public because a command surface has only a Snapshot::Channel, which
      # carries an endpoint_key.
      def room_for_endpoint_key(community:, endpoint_key:)
        channel = @models.channel.where(community_id: community.id, endpoint_key: endpoint_key.to_s).first
        return nil if channel.nil?

        join = @models.room_channel.where(channel_id: channel.id).first
        join && @models.room[join.room_id]
      end

      # @param community [Models::Community, nil] scopes to one community's
      #   polls; nil (the default) keeps the deployment-wide read every
      #   existing caller already relies on.
      # @return [Array<Rubotty::Polls::Poll>] oldest deadline first
      def open_polls(community: nil)
        scope = @models.poll.where(status: Rubotty::Polls::Poll::STATUS_OPEN)
        scope = scope.where(community_id: community.id) if community
        scope.order(:closes_at, :id).all.map { |row| Rubotty::Polls::Poll.new(row) }
      end

      # Bounded in SQL, so it holds whatever zone a backend reads a timestamp in.
      def due(now: nil)
        moment = (now || @clock.call).getutc
        @models.poll.where(status: Rubotty::Polls::Poll::STATUS_OPEN)
              .where { closes_at <= moment }.order(:closes_at, :id)
              .all.map { |row| Rubotty::Polls::Poll.new(row) }
      end

      private

      def normalise_option(entry)
        hash = entry.is_a?(Hash) ? symbolize(entry) : { label: entry }
        label = presence(hash[:label])
        return nil if label.nil?

        { label: label, starts_at: hash[:starts_at], suggested_by: presence(hash[:suggested_by]) }
      end

      def write_option(poll, entry, position, now)
        @models.poll_option.create(
          poll_id: poll.id, position: position, label: entry[:label].to_s[0, 200],
          starts_at: entry[:starts_at]&.getutc, suggested_by: entry[:suggested_by], created_at: now
        )
      end

      # A slot is the same slot when it names the same instant, whatever words
      # it was typed in.
      def same_option?(option, label, starts_at)
        return option.starts_at == starts_at.getutc unless starts_at.nil?

        option.label.to_s.strip.casecmp(label).zero?
      end

      def touch(poll)
        poll.row.update(updated_at: @clock.call)
      rescue StandardError => e
        @logger&.warn { "polls: could not touch poll #{poll.id}: #{e.message}" }
      end

      def symbolize(hash)
        hash.each_with_object({}) { |(key, value), out| out[key.to_s.to_sym] = value }
      end

      def presence(value)
        return nil if value.nil?

        string = value.to_s.strip
        string.empty? ? nil : string
      end
    end
  end
end
