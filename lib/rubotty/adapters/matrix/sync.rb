# frozen_string_literal: true

module Rubotty
  module Adapters
    module Matrix
      # The Matrix receive loop: long poll `/sync` and hand each timeline
      # event to the adapter. Matrix has no gateway socket, so the
      # client-server API holds a `/sync` request open until something
      # happens; this is a source of raw (room_id, event) pairs and nothing
      # more, it does not parse and does not know what a room is.
      class Sync
        DEFAULT_TIMEOUT_MS = 30_000

        MIN_BACKOFF = 1
        MAX_BACKOFF = 60
        MIN_IDLE_SLEEP = 0.05

        # @param client [Client]
        # @param on_event [#call] receives (room_id, event Hash) on a thread this
        #   transport owns. It must not raise; the adapter wraps it.
        # @param on_invite [#call, nil] receives (room_id, stripped state Array)
        #   for a room sitting in rooms.invite. Nil skips invite handling.
        # @param skip_backlog [Boolean] resume from now rather than replaying
        #   history the bridge missed while it was down
        def initialize(client:, on_event:, on_invite: nil, logger: nil, timeout_ms: DEFAULT_TIMEOUT_MS,
                       skip_backlog: true)
          @client = client
          @on_event = on_event
          @on_invite = on_invite
          @logger = logger
          @timeout_ms = timeout_ms
          @skip_backlog = skip_backlog
          @running = false
          @since = nil
          @thread = nil
        end

        attr_reader :logger

        def running? = @running

        def describe = "sync (timeout #{@timeout_ms}ms)"

        def start
          return self if @running

          @since = initial_since
          @running = true
          @thread = Thread.new { loop_forever }
          self
        end

        def stop
          @running = false
          @thread&.kill
          @thread&.join(5)
          @thread = nil
          self
        end

        private

        # A fast sync with no wait establishes the cursor, so the first real poll
        # returns only events that arrive AFTER startup and a bridge that was
        # down does not flood every room with history on restart.
        def initial_since
          return nil unless @skip_backlog

          response = @client.sync(since: nil, timeout_ms: 0)
          response.is_a?(Hash) ? response["next_batch"] : nil
        rescue AdapterError => e
          logger&.warn { "could not establish the initial sync cursor: #{e.message}" }
          nil
        end

        def loop_forever
          Thread.current.name = "matrix-sync"
          failures = 0
          while @running
            begin
              poll_once
              failures = 0
            rescue RateLimitedError => e
              wait = e.retry_after || MIN_BACKOFF
              logger&.warn { "matrix rate limited, sleeping #{wait}s" }
              sleep_interruptibly(wait)
            rescue AdapterError => e
              failures += 1
              wait = backoff(failures)
              logger&.warn { "matrix sync failed (#{e.message}), retrying in #{wait}s" }
              sleep_interruptibly(wait)
            end
          end
        end

        def poll_once
          response = @client.sync(since: @since, timeout_ms: @timeout_ms)
          unless response.is_a?(Hash)
            sleep(MIN_IDLE_SLEEP)
            return
          end

          # Advance the cursor BEFORE handling, so an event that raises is not
          # redelivered forever.
          @since = response["next_batch"] || @since
          each_join_event(response) { |room_id, event| deliver(room_id, event) }
          each_invite(response) { |room_id, state_events| deliver_invite(room_id, state_events) }
          sleep(MIN_IDLE_SLEEP) if @timeout_ms.to_i <= 0
        end

        def each_join_event(response)
          joined = response.dig("rooms", "join")
          return unless joined.is_a?(Hash)

          joined.each do |room_id, room|
            warn_if_limited(room_id, room)
            events = room.dig("timeline", "events")
            Array(events).each do |event|
              yield room_id, event if event.is_a?(Hash)
            end
          end
        end

        # A limited timeline means the server truncated the gap between this
        # poll and the last (a busy room, or the first poll after a fast
        # initial sync); there is no cheap way to backfill it from here, so
        # this only logs the gap rather than silently continuing as though
        # nothing between the two polls was missed.
        def warn_if_limited(room_id, room)
          return unless room.dig("timeline", "limited")

          logger&.warn { "matrix sync: #{room_id}'s timeline is limited, some events between polls were dropped" }
        end

        # rooms.invite carries no timeline, only the stripped state (name, join
        # rules, and the m.room.member that invited us) a client shows as a
        # preview before accepting.
        def each_invite(response)
          invited = response.dig("rooms", "invite")
          return unless invited.is_a?(Hash)

          invited.each do |room_id, room|
            yield room_id, room.dig("invite_state", "events")
          end
        end

        def deliver(room_id, event)
          @on_event.call(room_id, event)
        rescue StandardError => e
          logger&.error { "error handling a Matrix event: #{e.class}: #{e.message}" }
        end

        def deliver_invite(room_id, state_events)
          return if @on_invite.nil?

          @on_invite.call(room_id, state_events)
        rescue StandardError => e
          logger&.error { "error handling a Matrix room invite: #{e.class}: #{e.message}" }
        end

        def backoff(failures)
          [MIN_BACKOFF * (2**[failures - 1, 6].min), MAX_BACKOFF].min
        end

        def sleep_interruptibly(seconds)
          deadline = Time.now + seconds
          sleep(0.05) while @running && Time.now < deadline
        end
      end
    end
  end
end
