# frozen_string_literal: true

require "monitor"

module Rubotty
  module Adapters
    module Telegram
      # Reassembles Telegram media groups (albums) into one canonical
      # message. Telegram has no "album" update: four photos sent as one
      # album produce FOUR separate updates tied together only by a shared
      # `media_group_id`, with the caption on exactly one of them and not
      # reliably the first, so a message carrying one is held for a short
      # window (no completion signal exists, so a timer is the only option)
      # and later parts of the same group are merged in. Ordering within
      # the group is by message id, the order the user picked the files in.
      class AlbumBuffer
        DEFAULT_WINDOW = 1.5

        # Telegram caps an album at 10 items. Each new part pushes the flush
        # deadline forward, so this cap is the backstop that stops a stream
        # sharing one media_group_id from holding the buffer open forever.
        MAX_PARTS = 10

        Pending = Struct.new(:message, :parts, :deadline)

        # @param window [Float] seconds to wait for further parts
        # @param flush [#call] receives the completed canonical message
        def initialize(window: DEFAULT_WINDOW, flush:, clock: -> { Time.now }, logger: nil)
          @window = window
          @flush = flush
          @clock = clock
          @logger = logger
          @pending = {}
          @monitor = Monitor.new
          @thread = nil
        end

        # @param message [Core::Message]
        # @param group_id [String, nil]
        # @return [Core::Message, nil] the message to emit immediately, or nil
        #   when it has been buffered
        def offer(message, group_id)
          return message if group_id.nil?

          capped = @monitor.synchronize do
            existing = @pending[group_id]
            if existing
              existing.parts << message
              existing.deadline = @clock.call + @window
            else
              existing = Pending.new(message, [message], @clock.call + @window)
              @pending[group_id] = existing
            end

            # Decided under the lock, flushed outside it.
            @pending.delete(group_id) if existing.parts.size >= MAX_PARTS
          end

          flush_one(group_id, capped) if capped
          ensure_timer
          nil
        end

        # Emit every group whose window has closed.
        def flush_expired
          due = @monitor.synchronize do
            now = @clock.call
            ready = @pending.select { |_, pending| pending.deadline <= now }
            ready.each_key { |key| @pending.delete(key) }
            ready
          end
          due.each { |group_id, pending| flush_one(group_id, pending) }
          due.size
        end

        # Emit everything, regardless of deadline, so a shutdown does not lose a
        # part assembled album.
        def flush_all
          due = @monitor.synchronize do
            current = @pending
            @pending = {}
            current
          end
          due.each { |group_id, pending| flush_one(group_id, pending) }
          due.size
        end

        def pending? = @monitor.synchronize { !@pending.empty? }

        def stop
          thread = @monitor.synchronize do
            current = @thread
            @thread = nil
            current
          end
          thread&.kill
          flush_all
        end

        private

        # Release one group, naming it on failure instead of losing it quietly.
        def flush_one(group_id, pending)
          @flush.call(combine(pending))
        rescue StandardError => e
          @logger&.warn { "could not flush Telegram album #{group_id}: #{e.class}: #{e.message}" }
        end

        # Merge the parts into the first message: all attachments, and whichever
        # caption exists. The first part by message id wins for identity.
        def combine(pending)
          ordered = pending.parts.sort_by { |part| part.ref.native_id.to_i }
          first = ordered.first
          captioned = ordered.find { |part| !part.body.blank? } || first

          first.with(
            body: captioned.body,
            attachments: ordered.flat_map(&:attachments)
          )
        end

        def ensure_timer
          @monitor.synchronize do
            return if @thread&.alive?

            @thread = Thread.new do
              Thread.current.name = "telegram-albums"
              loop do
                sleep(@window / 3.0)
                begin
                  flush_expired
                rescue StandardError => e
                  @logger&.warn { "Telegram album timer failed: #{e.class}: #{e.message}" }
                end
              end
            end
          end
        end
      end
    end
  end
end
