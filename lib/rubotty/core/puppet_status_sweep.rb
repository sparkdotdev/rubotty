# frozen_string_literal: true

module Rubotty
  module Core
    # Reads every live Discord or Fluxer adapter's own webhook cache and
    # writes what it found onto the channel row it names: active, degraded
    # (silently posting as the bot) or off. This is the only path any of that
    # ever reaches the database, since an adapter itself never touches
    # storage, so the dashboard's Connections page can say more than the
    # silence #1700 found: an operator reads why puppeting is not happening
    # instead of guessing between "no permission", "not configured" and
    # "working fine, just no avatar".
    class PuppetStatusSweep
      def initialize(models:, logger: nil, clock: -> { Time.now.utc })
        @models = models
        @logger = logger
        @clock = clock
      end

      # @param adapters [Hash] Runtime's own [adapter_name, account] => adapter
      def run(adapters)
        (adapters || {}).each_value { |adapter| sweep_adapter(adapter) }
      end

      private

      def sweep_adapter(adapter)
        return unless adapter.respond_to?(:puppet_snapshot)

        snapshot = adapter.puppet_snapshot
        return if snapshot.nil? || snapshot.empty?

        now = @clock.call
        snapshot.each { |endpoint_id, status| write(endpoint_id, status, now) }
      rescue StandardError => e
        @logger&.warn { "puppet status sweep failed: #{e.class}: #{e.message}" }
      end

      def write(endpoint_id, status, now)
        @models.channel.where(endpoint_key: endpoint_id.to_s)
                        .update(puppet_status: status.to_s, puppet_checked_at: now)
      rescue StandardError => e
        @logger&.warn { "could not record puppet status for #{endpoint_id}: #{e.class}: #{e.message}" }
      end
    end
  end
end
