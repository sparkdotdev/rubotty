# frozen_string_literal: true

module Rubotty
  module Core
    # The fallback half of the boot-time straggler sweep: {EphemeralMessage#sweep}
    # is the primary mechanism, and this catches a banner whose durable write
    # silently failed and so left no row to find. Only works on adapters with
    # readable history (not Telegram's Bot API, which is skipped and logged
    # rather than treated as clean). Deletes only a message whose author id
    # matches the adapter's own account and whose text matches
    # {BANNER_PATTERN} anchored at the start, bounded per endpoint, and runs
    # before this boot posts its own banner.
    class HistorySweep
      # How far back the fallback scan looks for a stray. Generous on purpose: the
      # number of messages fetched is capped by +limit+ regardless, so a wide window
      # costs nothing extra and just means an older stray is still found.
      DEFAULT_WINDOW = 7 * 24 * 60 * 60

      # The most messages fetched, and so the most that could be matched and removed,
      # per endpoint per run.
      DEFAULT_LIMIT = 100

      # The banner's own opening shape: "Started <service> at <timestamp>." then a line
      # beginning "<service> version: ". Anchored at the very start of the text, so a
      # message that merely quotes or mentions "Started" is never matched.
      BANNER_PATTERN = /\AStarted \S.+ at .+\.\n\S.+ version: /

      # @param adapters [Hash] the runtime's [adapter_name, account] => adapter map
      # @param topology [#rooms] the live routing topology to sweep every endpoint of
      # @param logger [#info, #warn, nil]
      def initialize(adapters:, topology:, logger: nil, window: DEFAULT_WINDOW,
                     limit: DEFAULT_LIMIT, clock: -> { Time.now })
        @adapters = adapters
        @topology = topology
        @logger = logger
        @window = window
        @limit = limit
        @clock = clock
      end

      # @return [Integer] the number of straggler messages removed
      def sweep
        @topology.rooms.sum { |room| room.endpoints.sum { |endpoint| sweep_endpoint(endpoint) } }
      end

      private

      def sweep_endpoint(endpoint)
        adapter = @adapters[[endpoint.adapter_name, endpoint.account]]
        return 0 if adapter.nil?

        unless adapter.supports_backfill?
          @logger&.info { "history sweep: #{endpoint.id} (#{endpoint.adapter_name}) cannot read history, skipping" }
          return 0
        end
        unless adapter.capabilities_for(endpoint).deletes?
          @logger&.info { "history sweep: #{endpoint.id} (#{endpoint.adapter_name}) cannot delete messages, skipping" }
          return 0
        end

        strays = find_strays(adapter, endpoint)
        strays.each { |message| delete_stray(adapter, endpoint, message) }
        strays.size
      rescue StandardError => e
        @logger&.warn { "history sweep failed for #{endpoint.id}: #{e.class}: #{e.message}" }
        0
      end

      def find_strays(adapter, endpoint)
        own_ids = Array(adapter.own_account_ids).compact.map(&:to_s).reject(&:empty?)
        return [] if own_ids.empty?

        messages = adapter.backfill_messages(endpoint, since: @clock.call - @window, limit: @limit)
        messages.select { |message| stray?(message, own_ids) }
      end

      def stray?(message, own_ids)
        own_ids.include?(message.author&.native_id.to_s) && BANNER_PATTERN.match?(message.body&.text.to_s)
      end

      def delete_stray(adapter, endpoint, message)
        adapter.delete(endpoint, message.ref.native_id)
        @logger&.info { "history sweep: removed a straggler banner in #{endpoint.id} (native id #{message.ref.native_id})" }
      rescue StandardError => e
        @logger&.warn { "history sweep: could not delete #{message.ref.native_id} in #{endpoint.id}: #{e.message}" }
      end
    end
  end
end
