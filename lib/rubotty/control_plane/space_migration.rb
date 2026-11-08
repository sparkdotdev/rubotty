# frozen_string_literal: true

module Rubotty
  module ControlPlane
    # Moves a community onto the new id a platform gives a space it replaced,
    # as Telegram does when a basic group becomes a supergroup. Only the
    # community owning the old id is touched, and a new id another community
    # already holds is refused.
    class SpaceMigration
      # +status+ is :migrated, :unknown (no community holds the old id) or
      # :refused (another community holds the new one). +renamed+ and +retired+
      # map each old endpoint key to the one now carrying its rooms.
      Result = Struct.new(:status, :community, :renamed, :retired, keyword_init: true) do
        def migrated? = status == :migrated
      end

      # Stamped on a pending row for the new id, which this settles.
      DECIDED_BY = "space migration"

      def initialize(models:, registry: nil, audit: nil, logger: nil, clock: -> { Time.now })
        @models = models
        @registry = registry
        @audit = audit
        @logger = logger
        @clock = clock
      end

      # Follow the space +from+ to +to+ on one adapter account. A channel
      # addressing the old id is readdressed under a fresh endpoint key, so a
      # message id remembered from the old chat can never reach the new one. When
      # the new id already has a channel, the old one is retired into it instead.
      #
      # @return [Result]
      def call(adapter:, account:, from:, to:)
        adapter, account, from, to = [adapter, account, from, to].map(&:to_s)
        return Result.new(status: :unknown) if from.empty? || to.empty? || from == to

        result = @models.db.transaction { migrate(adapter, account, from, to) }
        report(result, adapter, from, to)
        reload if result.migrated?
        result
      end

      private

      def migrate(adapter, account, from, to)
        old_space = connection(adapter, account, from)
        return Result.new(status: :unknown) if old_space.nil?

        community = @models.community[old_space.community_id]
        new_space = connection(adapter, account, to)
        return Result.new(status: :refused, community: community) if new_space && new_space.community_id != community.id

        space = new_space || old_space.tap { |row| row.update(external_id: to, updated_at: now) }
        renamed = {}
        retired = {}
        channels_at(community, adapter, account, from).each do |stale|
          survivor = channels_at(community, adapter, account, to).first
          if survivor
            retire(stale, survivor)
            retired[stale.endpoint_key] = survivor.endpoint_key
          else
            renamed[stale.endpoint_key] = readdress(stale, space, to)
          end
        end
        old_space.destroy if new_space && @models.channel.where(platform_connection_id: old_space.id).empty?
        settle_pending(adapter, account, to, community)
        Result.new(status: :migrated, community: community, renamed: renamed, retired: retired)
      end

      def connection(adapter, account, external_id)
        @models.platform_connection.where(adapter: adapter, account: account, external_id: external_id).first
      end

      # The community's channels at +route_key+, the receiving row first.
      def channels_at(community, adapter, account, route_key)
        @models.channel.where(community_id: community.id, adapter: adapter, account: account, route_key: route_key)
                       .all.sort_by { |row| [truthy(row.receives) ? 0 : 1, row.id] }
      end

      # Same row, so its rooms and settings stay; only the address and key move.
      def readdress(channel, space, to)
        key = ChannelDiscovery.endpoint_key_for(channel.adapter, channel.account, to)
        addressing = Adapters::Registry.fetch(channel.adapter).addressing(to, external_id: to)
        channel.update(
          platform_connection_id: space.id, route_key: to, endpoint_key: key,
          settings: Models.dump_json(channel.json_value(:settings).merge(addressing)), updated_at: now
        )
        key
      end

      # The survivor joins every room +stale+ was in, and the guest rows naming
      # +stale+ move onto it so deleting +stale+ cannot cascade into them.
      def retire(stale, survivor)
        @models.room_channel.where(channel_id: stale.id).select_map(:room_id).each do |room_id|
          next unless @models.room_channel.where(room_id: room_id, channel_id: survivor.id).empty?

          @models.room_channel.create(room_id: room_id, channel_id: survivor.id, created_at: now)
        end
        [@models.guest_invite, @models.guest_message, @models.guest_upload].each do |model|
          model.where(channel_id: stale.id).update(channel_id: survivor.id)
        end
        stale.destroy
      end

      # A pending review of the new id would otherwise leave the community's
      # own chat when its timer runs out.
      def settle_pending(adapter, account, to, community)
        row = @models.pending_space.where(adapter: adapter, account: account, external_id: to,
                                          state: PendingSpaces::PENDING).first
        row&.update(state: PendingSpaces::APPROVED, community_id: community.id, decided_by: DECIDED_BY,
                    decided_at: now, updated_at: now)
      end

      def report(result, adapter, from, to)
        case result.status
        when :migrated then report_migrated(result, adapter, from, to)
        when :refused then report_refused(result, adapter, from, to)
        else @logger&.debug { "space migration: no community holds #{adapter} space #{from}, nothing moves to #{to}" }
        end
      end

      def report_migrated(result, adapter, from, to)
        moves = result.renamed.map { |old, key| "readdressed #{old} as #{key}" } +
                result.retired.map { |old, key| "retired #{old} into #{key}" }
        @logger&.info do
          "space migration: #{adapter} space #{from} became #{to} in #{result.community.slug}" \
            "#{moves.empty? ? "" : ", #{moves.join(", ")}"}"
        end
        audit(result.community, "space_migrated", adapter, to,
              { from: from, to: to, renamed: result.renamed, retired: result.retired })
      end

      def report_refused(result, adapter, from, to)
        @logger&.warn do
          "space migration: REFUSED to move #{adapter} space #{from} of #{result.community.slug} to #{to}, " \
            "which another community already holds"
        end
        audit(result.community, "space_migration_refused", adapter, to, { from: from, to: to })
      end

      def audit(community, action, adapter, target, metadata)
        @audit&.record(community: community.slug, source: "space_migration", action: action, adapter: adapter,
                       target_ref: target, metadata: metadata, now: now)
      rescue StandardError => e
        @logger&.warn { "space migration: could not write the audit line: #{e.message}" }
      end

      def reload
        @registry&.reload
      rescue StandardError => e
        @logger&.warn { "space migration: snapshot reload after a move failed: #{e.message}" }
      end

      def now = @clock.call

      def truthy(value) = [true, 1, "1", "t", "true"].include?(value)
    end
  end
end
