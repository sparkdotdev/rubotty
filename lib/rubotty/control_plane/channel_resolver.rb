# frozen_string_literal: true

module Rubotty
  module ControlPlane
    # Maps an inbound platform address to the channel that owns it, reading
    # the live Snapshot on every call. Keeps the adapter's existing injected-
    # callable seam rather than adding a new interface method, so the Telegram
    # General-topic fallback and every other matching rule live once, in
    # {Snapshot#resolve}, and a control-plane change is picked up on the next
    # inbound event. The route index is keyed on (adapter, account, route_key)
    # across all communities, so a shared-token event lands on whichever
    # community owns that space; the adapter never hears the word "community".
    class ChannelResolver
      # @param registry [ControlPlane::Registry] holds the current Snapshot
      def initialize(registry)
        @registry = registry
      end

      # The Snapshot::Channel owning this inbound address, or nil on a miss (an
      # unclaimed space, which the caller drops per the fail-closed default).
      #
      # @param adapter [Symbol, String] :telegram, :discord, ...
      # @param account [String] the credential (shared token) the event arrived on
      # @param route_key [String] the adapter's normalized address
      # @return [Snapshot::Channel, nil]
      def resolve(adapter, account, route_key)
        @registry.current.resolve(adapter, account, route_key)
      end

      # The Core::Endpoint the adapter's inbound path expects: what the adapter's
      # endpoint_for closure returns once wired to the resolver.
      #
      # @return [Core::Endpoint, nil]
      def endpoint_for(adapter, account, route_key)
        resolve(adapter, account, route_key)&.endpoint
      end

      # Every (route_key, Core::Endpoint) pair this adapter and account can
      # resolve, for a lookup whose inbound address is COARSER than a route key;
      # narrowing is left to the adapter, a route key's shape being its own. A
      # Telegram reaction names its chat but never its topic, so the adapter has
      # to weigh every endpoint bridged in that chat.
      #
      # @return [Array<Array(String, Core::Endpoint)>]
      def endpoints_for(adapter, account)
        @registry.current.channels_for(adapter, account)
                 .map { |route_key, channel| [route_key, channel.endpoint] }
      end

      # Every channel sharing one (adapter, account) connection, grouped by
      # community AND route_key: what a hub group is, structurally. The
      # community belongs in the key because two of them can map the same
      # channel on one shared account, and neither may address or list the
      # other's rooms. Read live, so a room {ChannelMapper#add_hub_room} maps
      # into an existing hub channel shows up on the next call.
      #
      # @return [Hash{Array=>Array<Core::Endpoint>}] {Irc::HubRouter.key_for}
      def hub_groups_for(adapter, account)
        wanted = [adapter.to_sym, account.to_s]
        @registry.current.communities.select(&:active?).flat_map(&:channels)
                 .select { |channel| [channel.adapter, channel.account] == wanted }
                 .group_by { |channel| [channel.community_id, channel.route_key] }
                 .transform_values { |group| group.map(&:endpoint) }
      end

      # The owning (community, channel) pair for an inbound address. Reads the
      # snapshot ONCE, so both come from the same view even if a reload swaps the
      # reference between calls.
      #
      # @return [Array(Snapshot::Community, Snapshot::Channel), nil]
      def route(adapter, account, route_key)
        snapshot = @registry.current
        channel = snapshot.resolve(adapter, account, route_key)
        return nil if channel.nil?

        community = snapshot.community_by_id(channel.community_id)
        return nil if community.nil?

        [community, channel]
      end
    end
  end
end
