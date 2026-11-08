# frozen_string_literal: true

module Rubotty
  module ControlPlane
    # Fills in the space id the YAML never carried, for whichever adapter left
    # a seed sentinel unresolved. platform_connections.external_id for a
    # guild/server scoped adapter IS the guild or server id, so the seed
    # writes a per-community sentinel, "unresolved:<slug>", until the real id
    # is learned and this resolves it. Only an adapter whose class answers
    # #guild_id_for_channel is covered. Idempotent and best effort: a space
    # not yet visible just waits for a later boot rather than failing
    # startup.
    module GuildResolver
      module_function

      SENTINEL_PREFIX = "unresolved:"

      # @param models [ControlPlane::Models]
      # @param adapters [Hash{[Symbol,String]=>Adapters::Base}] the live adapters,
      #   keyed [adapter_name, account] exactly as the runtime holds them
      # @param logger [#info, nil]
      # @return [Integer] how many connections were resolved this pass
      def resolve(models:, adapters:, logger: nil)
        pending(models).sum do |connection|
          guild_id = guild_for(connection, models: models, adapters: adapters)
          next 0 if guild_id.nil? || guild_id.to_s.empty?

          connection.update(external_id: guild_id.to_s, updated_at: Time.now)
          logger&.info do
            "resolved #{connection.adapter} space #{guild_id} for connection #{connection.id} " \
              "(account #{connection.account})"
          end
          1
        end
      end

      # Every connection, of any adapter, still carrying the sentinel.
      def pending(models)
        models.platform_connection
              .all
              .select { |connection| connection.external_id.to_s.start_with?(SENTINEL_PREFIX) }
      end

      # Resolve a guild's identity straight off a GUILD_CREATE, the live join
      # path: if the guild contains one of a seeded connection's channels, it
      # IS that community's guild, whatever its external_id currently reads.
      # This is the never-leave-a-core-guild guarantee for auto-leave, since a
      # GUILD_CREATE can arrive BEFORE the boot-time {resolve} pass.
      #
      # @return [Models::PlatformConnection, nil] nil means no seeded connection
      #   owns any of these channels, a candidate for auto-leave
      def resolve_from_guild(models:, account:, guild_id:, channel_ids:, logger: nil)
        guild_id = guild_id.to_s
        return nil if guild_id.empty?

        connection = connection_owning(models, account, channel_ids)
        return nil if connection.nil?

        current = connection.external_id.to_s
        if current != guild_id && current.start_with?(SENTINEL_PREFIX)
          connection.update(external_id: guild_id, updated_at: Time.now)
          logger&.info do
            "resolved Discord guild #{guild_id} for connection #{connection.id} on join (account #{account})"
          end
        end
        connection
      end

      # The Discord connection on this account that owns one of these channels, by
      # route_key (which for Discord IS the channel_id). A Discord channel id is
      # globally unique, so a match is unambiguous.
      def connection_owning(models, account, channel_ids)
        keys = Array(channel_ids).map(&:to_s).reject(&:empty?)
        return nil if keys.empty?

        channel = models.channel
                        .where(adapter: "discord", account: account.to_s, route_key: keys)
                        .order(:id).first
        return nil if channel.nil?

        models.platform_connection[channel.platform_connection_id]
      end

      # Ask the connection's own live adapter for the guild/server id of one of
      # its channels. Every adapter that scopes by guild or server keys a
      # channel by its channel_id, which is exactly the channel row's
      # route_key, so no endpoint needs rebuilding here.
      def guild_for(connection, models:, adapters:)
        adapter = adapters[[connection.adapter.to_sym, connection.account]]
        return nil unless adapter.respond_to?(:guild_id_for_channel)

        channel = models.channel.where(platform_connection_id: connection.id).order(:id).first
        return nil if channel.nil?

        adapter.guild_id_for_channel(channel.route_key)
      end
    end
  end
end
