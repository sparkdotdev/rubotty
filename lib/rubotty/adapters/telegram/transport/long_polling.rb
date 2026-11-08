# frozen_string_literal: true

require "json"

module Rubotty
  module Adapters
    module Telegram
      module Transport
        # getUpdates in a loop, the default because it works in every environment
        # including a laptop behind NAT and needs no configuration beyond a token.
        # The getUpdates offset is PERSISTED: Telegram treats the offset as an
        # acknowledgement and queues unacknowledged updates for about 24h, so a
        # restart replays the gap that opened while the bridge was down. This stays
        # hand written rather than using telegram-bot-ruby's own receive loop, since
        # that loop keeps its offset in memory, takes no lock, sends no
        # allowed_updates, and yields Update#current_message rather than the raw update, which would drop message_reaction and my_chat_member entirely.
        class LongPolling < Base
          DEFAULT_TIMEOUT = 30
          DEFAULT_LIMIT = 100

          # Backoff bounds for repeated failures. Telegram briefly 502s during
          # its own deploys, and a bridge that gives up on the first failure is
          # useless.
          MIN_BACKOFF = 1
          MAX_BACKOFF = 60

          # Floor on the gap between polls. A timeout of 0 (a misconfiguration,
          # and the natural setting in tests) would otherwise spin as fast as the
          # network allows and earn a rate limit within seconds.
          MIN_IDLE_SLEEP = 0.05

          # How long a persisted offset stays worth resuming from. Telegram
          # retains unacknowledged updates for roughly 24h, so past this window
          # the stale offset is discarded and polling skips to now.
          MAX_BACKLOG_AGE = 24 * 60 * 60

          # How long to pause after a FULL page, so a large gap drains in paced
          # pages rather than flooding every bridged room. A caught-up poll never
          # pauses, so steady-state latency is unaffected.
          BACKLOG_DRAIN_PAUSE = 1

          # How long a single loop iteration waits to acquire the poll lock before
          # deciding another process already has it. Short, so {#loop_forever}'s
          # own standby sleep paces the retry rather than blocking the loop.
          POLL_LOCK_TIMEOUT = 1

          # How long to wait before checking again once another instance is found
          # to be holding the poll lock.
          STANDBY_BACKOFF = 5

          def start
            return self if @running

            # A webhook may still be registered from a previous run with the other
            # transport, and Telegram refuses getUpdates while one exists.
            drop_webhook
            @offset = initial_offset
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

          def describe
            "long polling (timeout #{timeout}s)"
          end

          private

          def timeout = settings.fetch(:poll_timeout, DEFAULT_TIMEOUT)

          def limit = settings.fetch(:poll_limit, DEFAULT_LIMIT)

          def drop_webhook
            client.call("deleteWebhook", drop_pending_updates: false)
          rescue AdapterError => e
            logger.warn { "could not clear a previous webhook: #{e.message}" }
          end

          # Where to resume the getUpdates cursor. A durably-persisted offset
          # wins; with none usable, skip the backlog to "now" when skip_backlog is
          # set, otherwise start from Telegram's oldest retained update.
          def initial_offset
            resumed = resume_offset
            return resumed unless resumed.nil?

            skip_to_now_offset
          end

          # Ask for the most recent update only, acknowledge it, and start from
          # the next one, so a bridge down for a day does not flood every room
          # with a day of history on restart.
          def skip_to_now_offset
            return nil unless settings.fetch(:skip_backlog, true)

            updates = client.call("getUpdates", offset: -1, limit: 1, timeout: 0)
            last = Array(updates).last
            return nil if last.nil?

            logger.info { "skipping backlog, resuming after update #{last["update_id"]}" }
            last["update_id"] + 1
          rescue AdapterError => e
            logger.warn { "could not determine the backlog position: #{e.message}" }
            nil
          end

          # The persisted offset to resume from, or nil to fall through to
          # skip-to-now: no durable store, nothing persisted, unreadable bytes, or
          # an offset older than the retention window.
          def resume_offset
            raw = read_offset_state
            return nil if raw.nil?

            data = JSON.parse(raw)
            offset = data["offset"]
            return nil unless offset.is_a?(Integer)

            saved_at = data["saved_at"]
            age = saved_at.is_a?(Numeric) ? Time.now.to_i - saved_at.to_i : nil
            if age && age > MAX_BACKLOG_AGE
              logger.info do
                "persisted Telegram offset is #{age}s old, past the #{MAX_BACKLOG_AGE}s " \
                  "retention window; skipping the stale backlog"
              end
              return nil
            end

            logger.info { "resuming Telegram polling from persisted offset #{offset}" }
            offset
          rescue JSON::ParserError => e
            logger.warn { "could not read the persisted Telegram offset: #{e.message}" }
            nil
          end

          def loop_forever
            Thread.current.name = "telegram-poll"
            failures = 0
            while @running
              begin
                poll_once
                failures = 0
              rescue LockUnavailable
                # Telegram only allows one active poller per bot (a second one
                # gets a 409), so there is nothing to retry aggressively here.
                logger.debug { "another instance is polling Telegram for this bot; standing by" }
                sleep_interruptibly(STANDBY_BACKOFF)
              rescue RateLimitedError => e
                wait = e.retry_after || MIN_BACKOFF
                logger.warn { "rate limited, sleeping #{wait}s" }
                sleep_interruptibly(wait)
              rescue AdapterError => e
                failures += 1
                wait = backoff(failures)
                logger.warn { "poll failed (#{e.message}), retrying in #{wait}s" }
                sleep_interruptibly(wait)
              end
            end
          end

          # Wraps the getUpdates round trip in the named poll lock, so that when
          # several processes share a durable store only one is ever mid-poll.
          # Runs unlocked without a lock-capable durable store.
          def poll_once
            if lockable_store?
              storage.with_advisory_lock(poll_lock_name, timeout: POLL_LOCK_TIMEOUT) { poll_once! }
            else
              poll_once!
            end
          end

          def poll_once!
            updates = client.call(
              "getUpdates",
              offset: @offset,
              limit: limit,
              timeout: timeout,
              allowed_updates: allowed_updates
            )
            updates = [] unless updates.is_a?(Array)
            sleep(MIN_IDLE_SLEEP) if timeout <= 0
            advanced = false
            updates.each do |update|
              next unless update.is_a?(Hash)

              # The offset is advanced BEFORE handling. Telegram treats it as an
              # acknowledgement, so advancing after would redeliver anything that
              # raised and wedge the bridge on a message that never relays.
              @offset = update["update_id"] + 1
              advanced = true
              deliver(update)
            end
            # Once per non-empty page, so idle polling costs no writes.
            persist_offset if advanced
            # A full page means a backlog is still queued: pace the next pull.
            drain_backlog if backlog?(updates)
          end

          # The advisory lock name every process sharing this store must agree on.
          # Keyed by account, so a shared store keeps a distinct poll lock per
          # Telegram bot rather than serializing unrelated bots.
          def poll_lock_name
            "telegram:getUpdates:poll:#{account}"
          end

          # Whether the injected storage can actually take the poll lock. Nil, or
          # a store that does not implement it, means unlocked single-process
          # behaviour.
          def lockable_store?
            !storage.nil? && storage.respond_to?(:with_advisory_lock)
          end

          # A full page means Telegram still has more queued than one request
          # returned. Guarded on a positive limit so a misconfigured limit of 0
          # never reports a permanent backlog.
          def backlog?(updates)
            limit.positive? && updates.size >= limit
          end

          def drain_backlog
            logger.debug { "draining a Telegram backlog, pausing #{BACKLOG_DRAIN_PAUSE}s before the next page" }
            sleep_interruptibly(BACKLOG_DRAIN_PAUSE)
          end

          def persist_offset
            return if @offset.nil?

            write_offset_state(JSON.generate("offset" => @offset, "saved_at" => Time.now.to_i))
          end

          # The per-account key the offset is stored under, so one shared backend
          # keeps a distinct cursor for each Telegram account.
          def offset_state_key
            "telegram:getUpdates:offset:#{account}"
          end

          # Whether a durable KV store is actually available.
          def durable_store?
            !storage.nil? && storage.respond_to?(:get_state) && storage.respond_to?(:put_state)
          end

          def read_offset_state
            return nil unless durable_store?

            storage.get_state(offset_state_key)
          rescue StandardError => e
            logger.warn { "could not read the persisted Telegram offset: #{e.message}" }
            nil
          end

          # Best effort: a storage hiccup must never take down the poll loop, so a
          # failed write is logged and swallowed. The worst case is a restart that
          # replays a little more than strictly necessary.
          def write_offset_state(value)
            return unless durable_store?

            storage.put_state(offset_state_key, value)
          rescue StandardError => e
            logger.warn { "could not persist the Telegram offset: #{e.message}" }
          end

          def backoff(failures)
            [MIN_BACKOFF * (2**[failures - 1, 6].min), MAX_BACKOFF].min
          end

          # Sleep in short slices so that stop takes effect promptly rather
          # than after a full backoff window.
          def sleep_interruptibly(seconds)
            deadline = Time.now + seconds
            sleep(0.05) while @running && Time.now < deadline
          end
        end
      end
    end
  end
end
