# frozen_string_literal: true

require "yamlcamel"

module Rubotty
  module ControlPlane
    # The storage behind a scripted round: a session a script opens, and the
    # rounds inside it. Rubotty holds a bounded interval (deadline,
    # continuation, payload) and nothing about what the round is FOR; that is
    # a script's own business, kept in its own Scripting::Memory bucket like
    # any other running total. Every write answers `true`, or `false` and a
    # reason, readable without pcall. Not owned by one script: a game is
    # usually three scripts (start, answer, close), so a session is reached
    # by community and room like a shared memo bucket.
    class Participation
      # A session and its rounds, after this long without a write. The label a
      # script chose and the payload a round carries are free text somebody
      # wrote, so they expire for the same reason ScriptStats rows do.
      RETENTION = 30 * 24 * 60 * 60

      # The durable job kind that ages them out, run once a day.
      PRUNE_KIND = "script_participation_prune"

      PRUNE_INTERVAL = 24 * 60 * 60

      # Rounds in one session. A game longer than this is a series of games.
      MAX_ROUNDS = 200

      MAX_KIND = 32
      MAX_LABEL = 200
      MAX_SCRIPT_NAME = 200

      # A round's payload, YAML encoded. Bounded the way a memo's value is.
      MAX_DATA_BYTES = 4096

      # How soon and how far out a round's own close may be booked, the same
      # floor and ceiling rubotty.schedule holds a wake to.
      MIN_CLOSE_AFTER = 10
      MAX_CLOSE_AFTER = 30 * 24 * 60 * 60

      # What a session may be called. Free text, since rubotty holds no list of
      # games, but bounded and without punctuation so it reads on a dashboard.
      KIND_PATTERN = /\A[a-z0-9][a-z0-9 _-]{0,31}\z/i

      # The reason a round's own close_after booking wakes a script with,
      # read back through rubotty.wake_reason(). Kept here, not in Router or
      # Runtime, so the one place that books it and the one place that reads
      # it back can never drift apart.
      ROUND_CLOSE_REASON = "round_close"

      OPEN = "open"
      CLOSED = "closed"

      def initialize(models:, logger: nil, clock: -> { Time.now })
        @models = models
        @logger = logger
        @clock = clock
      end

      # The open session in this room, as a script sees it, or nil.
      def session(community:, room_key: "")
        row = open_session_row(community, room_key)
        return nil if row.nil?

        described_session(row)
      end

      # Start one. Refused while another is open here, rather than closing it
      # for you: two overlapping games in one room make an answer ambiguous, and
      # guessing which one somebody meant is worse than saying so.
      def open_session(community:, kind:, room_key: "", label: "")
        name = clean(kind, MAX_KIND)
        return [false, "a session needs a kind, such as trivia or poll"] if name.empty?
        return [false, "that is not a session kind"] unless name.match?(KIND_PATTERN)
        return [false, "something is already running in this room"] if open_session_row(community, room_key)

        now = @clock.call
        @models.script_session.create(
          community_id: community.id, room_key: room_key.to_s, kind: name.downcase,
          label: clean(label, MAX_LABEL), state: OPEN,
          opened_at: now, created_at: now, updated_at: now
        )
        true
      end

      # Close the session and whatever round is still open inside it. The rows
      # stay until the retention drops them, so a script can be written to read
      # them back within the same run.
      def close_session(community:, room_key: "")
        row = open_session_row(community, room_key)
        return [false, "nothing is running in this room"] if row.nil?

        now = @clock.call
        open_round_row(row)&.update(state: CLOSED, closed_at: now, updated_at: now)
        row.update(state: CLOSED, closed_at: now, updated_at: now)
        true
      end

      # The open round in this room, or nil.
      def round(community:, room_key: "")
        session_row = open_session_row(community, room_key)
        row = session_row && open_round_row(session_row)
        return nil if row.nil?

        described_round(row)
      end

      # Opens the next round, closing the one before it: +close_after+ (seconds)
      # and +on_close+ (a script name) book the round's own close together, firing
      # +on_close+ at the deadline with +data+ and ROUND_CLOSE_REASON, or leaving
      # the round open if both are omitted. The booking itself is the caller's
      # job, done only after this returns the new round's id, since a script
      # cannot book a durable job against a row that does not exist yet.
      #
      # @return [Integer, Array(false, String)] the new round's id, or a refusal
      def open_round(community:, room_key: "", close_after: nil, on_close: nil, data: nil)
        session_row = open_session_row(community, room_key)
        return [false, "nothing is running in this room"] if session_row.nil?

        deadline, close_error = close_after_deadline(close_after)
        return close_error if close_error

        script = clean(on_close, MAX_SCRIPT_NAME)
        return [false, "close_after needs an on_close script to wake"] if deadline && script.empty?

        encoded, data_error = encode_data(data)
        return data_error if data_error

        count = @models.script_round.where(session_id: session_row.id).count
        return [false, "this session already has #{MAX_ROUNDS} rounds, which is the limit"] if count >= MAX_ROUNDS

        now = @clock.call
        open_round_row(session_row)&.update(state: CLOSED, closed_at: now, updated_at: now)
        row = @models.script_round.create(
          community_id: community.id, session_id: session_row.id, position: count + 1,
          on_close: script.empty? ? nil : script, closes_at: deadline, data: encoded, state: OPEN,
          opened_at: now, created_at: now, updated_at: now
        )
        row.id
      end

      # Stop taking answers. What happens next, scoring or announcing, is the
      # script's own job against its own store; this only marks the round shut
      # and, when given one, keeps a final +data+ payload against it.
      def close_round(community:, room_key: "", data: nil)
        session_row = open_session_row(community, room_key)
        row = session_row && open_round_row(session_row)
        return [false, "no round is open in this room"] if row.nil?

        encoded = row.data
        unless data.nil?
          encoded, data_error = encode_data(data)
          return data_error if data_error
        end

        now = @clock.call
        row.update(state: CLOSED, closed_at: now, updated_at: now, data: encoded)
        session_row.update(updated_at: now)
        true
      end

      # Drop every session past the retention, and everything under it.
      def prune(now: @clock.call)
        stale = @models.script_session.where { updated_at <= (now - RETENTION) }
        ids = stale.select_map(:id)
        return 0 if ids.empty?

        @models.script_round.where(session_id: ids).delete
        @models.script_session.where(id: ids).delete
      end

      private

      # The one open session in a room. Ordered, because MariaDB cannot enforce
      # the partial unique index that makes "one" true, so a duplicate written
      # through a race has to resolve to the same row every time it is read.
      def open_session_row(community, room_key)
        return nil if community.nil?

        @models.script_session
               .where(community_id: community.id, room_key: room_key.to_s, state: OPEN)
               .order(:id).first
      end

      def open_round_row(session_row)
        @models.script_round.where(session_id: session_row.id, state: OPEN).order(:id).first
      end

      def described_session(row)
        { "kind" => row.kind.to_s, "label" => row.label.to_s, "state" => row.state.to_s,
          "opened_at" => row.opened_at.to_i,
          "rounds" => @models.script_round.where(session_id: row.id).count }
      end

      def described_round(row)
        described = {
          "id" => row.id, "position" => row.position.to_i, "opened_at" => row.opened_at.to_i,
          "data" => decode_data(row.data)
        }
        described["closes_at"] = row.closes_at.to_i unless row.closes_at.nil?
        described
      end

      def close_after_deadline(close_after)
        return [nil, nil] if close_after.nil?

        seconds = Integer(close_after, exception: false)
        return [nil, [false, "close_after has to be a whole number of seconds"]] if seconds.nil?
        return [nil, [false, "close_after has to be at least #{MIN_CLOSE_AFTER} seconds"]] if
          seconds < MIN_CLOSE_AFTER
        return [nil, [false, "close_after has to be under #{MAX_CLOSE_AFTER} seconds"]] if
          seconds > MAX_CLOSE_AFTER

        [@clock.call + seconds, nil]
      end

      def encode_data(data)
        return [nil, nil] if data.nil?

        encoded = YAMLCamel.dump(data)
        return [nil, [false, "data is too large to keep against a round"]] if encoded.bytesize > MAX_DATA_BYTES

        [encoded, nil]
      end

      def decode_data(body)
        return nil if body.to_s.empty?

        YAMLCamel.load(body.to_s)
      rescue StandardError
        nil
      end

      def clean(value, limit) = value.to_s.strip[0, limit].to_s
    end
  end
end
