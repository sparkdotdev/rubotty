# frozen_string_literal: true

module Rubotty
  module ControlPlane
    # A community's live membership, summed across whichever of its platform
    # connections can answer. Built for RehostedFiles#store_file's per-file
    # serve ceiling; nothing else needs a number this soft. A member on two
    # platforms is counted on both, which only inflates the sum, so nothing
    # here deduplicates people.
    module CommunityMembers
      module_function

      # The community's membership summed across every connected platform, or
      # nil the instant any ONE of them cannot answer: a partial sum reads
      # smaller than the community really is, so the caller must treat nil
      # as "unknown," never fold it in as though that platform had zero
      # members. +adapters+ is the live map the runtime holds, keyed
      # [adapter_name, account]; a process with none wired answers nil.
      # @return [Integer, nil]
      def aggregate(community_id:, models:, adapters:, logger: nil)
        connections = models.platform_connection.where(community_id: community_id).all
        return nil if connections.empty?

        total = 0
        connections.each do |connection|
          count = count_for(connection, adapters: adapters, logger: logger)
          return nil if count.nil?

          total += count
        end
        total
      end

      # One connection's live count, or nil when its adapter is not running,
      # does not expose a count at all, or could not answer this time.
      def count_for(connection, adapters:, logger:)
        adapter = adapters[[connection.adapter.to_sym, connection.account]]
        return nil unless adapter.respond_to?(:community_member_count)

        count = adapter.community_member_count(connection.external_id)
        count.is_a?(Integer) && count >= 0 ? count : nil
      rescue StandardError => e
        logger&.warn do
          "could not read #{connection.adapter} membership for connection #{connection.id}: " \
            "#{e.class}: #{e.message}"
        end
        nil
      end
    end
  end
end
