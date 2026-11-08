# frozen_string_literal: true

module Rubotty
  module ControlPlane
    # An immutable projection of the whole control plane at one instant.
    #
    # The control plane is mutable rows; the running system never reads those rows
    # on the hot path. A Registry builds a frozen Snapshot and swaps the reference
    # on a change, so in-flight work keeps the Snapshot it started with.
    class Snapshot
      # accounts are credentials, resolved from the control plane's own table
      # once SnapshotBuilder finds it seeded, so a reader has the whole
      # routing picture in one object.
      attr_reader :communities, :accounts

      # @param feature_settings [Array<Snapshot::FeatureSetting>] the
      #   deployment-wide rows: no community and no room at all, one per
      #   feature at most
      def initialize(communities:, accounts: {}, feature_settings: [])
        @communities = communities.freeze
        @accounts = accounts.freeze
        @by_slug = communities.each_with_object({}) { |c, h| h[c.slug] = c }.freeze
        @by_id   = communities.each_with_object({}) { |c, h| h[c.id] = c }.freeze
        @channel_route_index = build_route_index(communities).freeze
        @endpoint_index = build_endpoint_index(communities).freeze
        # The aggregate views the running router and dispatcher read instead of
        # the config-derived Core::Topology. Built here, once, so a reader holds a
        # consistent, frozen picture for the whole of one message.
        @topology = build_topology(communities)
        @operators = build_operators(communities)
        @people = build_people(communities)
        @global_feature_settings = index_feature_settings(feature_settings).freeze
        freeze
      end

      # The deployment-wide default config for one feature: the feature_settings
      # row scoped to no community and no room at all. {} when the deployment
      # has never set one. Every community's own settings, and every room's,
      # still take priority over this; it is the last live value checked
      # before a class's own hardcoded default.
      def feature_config_default(feature)
        @global_feature_settings[feature.to_s]&.config || {}
      end

      def community(slug) = @by_slug[slug.to_s]

      def community_by_id(id) = @by_id[id]

      # The whole routing topology the router and dispatcher consume, as one
      # Core::Topology over every community's rooms. Endpoint ids are globally
      # unique and no room spans two communities, so fan-out stays in one community.
      attr_reader :topology

      # The deployment-wide operator directory, as one merged Directory. NOT an
      # authorisation surface: room_key is only unique within a community, so
      # resolving an issuer here could leak access across communities; use the
      # community's own +operators+ for authorisation instead.
      attr_reader :operators

      # Every community's mentionable people, as a {Core::CommunityPeople} keyed
      # by community id. NOT an identity-resolution surface, for the same reason
      # as {#operators}: resolving a mention or moderation target goes through
      # +people.for_community+ with the message's own community instead.
      attr_reader :people

      # { [adapter, account, route_key] => Channel }  inbound resolution.
      attr_reader :channel_route_index

      # { endpoint_key => Channel }  delivery and message-map linkage.
      attr_reader :endpoint_index

      # Resolve an inbound platform address to a Channel, mirroring the adapters'
      # own keying: try the exact route_key, then, for Telegram, the
      # General-topic fallback of the bare chat_id; nil on a miss. A route_key
      # that misses the index fails closed, since substituting the channel
      # mapped under a shorter key would hand back a DIFFERENT topic's
      # endpoint, breaking the echo-exclusion in Room#targets_for and
      # bouncing a message back.
      def resolve(adapter, account, route_key)
        @channel_route_index[[adapter.to_sym, account.to_s, route_key.to_s]]
      end

      def channel_by_endpoint_key(endpoint_key) = @endpoint_index[endpoint_key.to_s]

      # Every (route_key, Channel) pair indexed for this adapter and account,
      # for a caller that has to consider a whole space rather than one address.
      #
      # @return [Array<Array(String, Channel)>]
      def channels_for(adapter, account)
        wanted = [adapter.to_sym, account.to_s]
        @channel_route_index.filter_map do |(index_adapter, index_account, route_key), channel|
          next nil unless [index_adapter, index_account] == wanted

          [route_key, channel]
        end
      end

      private

      # Only a started (active) community's channels are indexed for inbound
      # resolution; a stopped community keeps its rows but no longer resolves
      # an inbound event. A hub group writes several rows under the
      # identical key, so the receives: true row wins (mirroring IRC's own
      # Adapter#receiving_endpoint), or the first one loaded when none does.
      def build_route_index(communities)
        communities.each_with_object({}) do |community, index|
          next unless community.active?

          community.channels.each do |channel|
            key = [channel.adapter, channel.account, channel.route_key]
            current = index[key]
            index[key] = channel if current.nil? || (channel.endpoint.receives? && !current.endpoint.receives?)
          end
        end
      end

      def build_endpoint_index(communities)
        communities.each_with_object({}) do |community, index|
          community.channels.each { |channel| index[channel.endpoint_key] = channel }
          # A guest endpoint and an API endpoint each front a real channel. Index
          # the key to that underlying channel, so a send through either resolves
          # to the SAME (community, channel) scope the real channel has.
          community.topology.endpoints.each do |endpoint|
            fronted = endpoint.settings[:channel_endpoint_key]
            next if fronted.nil?

            underlying = index[fronted.to_s]
            index[endpoint.id] = underlying if underlying
          end
        end
      end

      # The union of every community's rooms as one Core::Topology, reusing the
      # same frozen Core::Endpoint objects, so nothing is copied or re-frozen.
      def build_topology(communities)
        Core::Topology.new(communities.flat_map { |community| community.topology.rooms })
      end

      # The union of every community's operators as one Core::Moderation::
      # Directory. Reuses the per-community Operator value objects verbatim.
      def build_operators(communities)
        Core::Moderation::Directory.new(
          communities.flat_map { |community| community.operators.operators }
        )
      end

      # Every community's mentionable people, kept community by community rather
      # than flattened into one directory. Reuses the per-community Directory
      # objects verbatim.
      def build_people(communities)
        Core::CommunityPeople.new(
          communities.to_h { |community| [community.id, community.people] }
        )
      end

      def index_feature_settings(rows)
        Array(rows).to_h { |row| [row.feature, row] }
      end

      # One community's frozen view: its topology, its two directories, its
      # channels, and the resolved feature settings.
      class Community
        attr_reader :id, :slug, :name, :status, :settings, :topology,
                    :channels, :operators, :people

        # @param operators [Core::Moderation::Directory]
        # @param people [Core::Directory]
        # @param topology [Core::Topology]
        # @param channels [Array<Snapshot::Channel>]
        # @param feature_settings [Array<Snapshot::FeatureSetting>]
        def initialize(id:, slug:, name:, status:, settings:, topology:, channels:,
                       operators:, people:, feature_settings: [])
          @id = id
          @slug = slug.to_s
          @name = name.to_s
          @status = status.to_s
          @settings = deep_freeze(settings || {})
          @topology = topology
          @channels = channels.freeze
          @operators = operators
          @people = people
          @endpoint_to_room_key = build_endpoint_room_index(topology)
          index_features(feature_settings)
          freeze
        end

        def rooms = topology.rooms

        def active? = status == "active"

        # Enablement resolves room row over community default over code default.
        # The code default is whatever the feature class itself declares; an
        # unknown feature name has no class to ask and reads as off.
        def feature_enabled?(channel_or_key, feature)
          key = room_key_of(channel_or_key)
          feature = feature.to_s
          row = @feature_by_room[[key, feature]] || @feature_by_community[feature]
          return row.enabled if row

          Features::Catalog.class_for(feature)&.default_enabled? || false
        end

        # Config resolves as deep-merge(code defaults, community config, room
        # config). Code defaults are empty here.
        def feature_config(channel_or_key, feature)
          key = room_key_of(channel_or_key)
          feature = feature.to_s
          community_config = @feature_by_community[feature]&.config || {}
          room_config = @feature_by_room[[key, feature]]&.config || {}
          deep_merge(community_config, room_config)
        end

        # The room a channel is bridged into, or nil for one in no room. Public
        # because a feature that tells a script which room it is in has to mean the
        # SAME room the two methods above resolve settings against.
        def room_key_of(channel_or_key)
          return nil if channel_or_key.nil?

          key = channel_or_key.respond_to?(:endpoint_key) ? channel_or_key.endpoint_key : channel_or_key.to_s
          @endpoint_to_room_key[key]
        end

        private

        def index_features(rows)
          @feature_by_community = {}
          @feature_by_room = {}
          Array(rows).each do |row|
            if row.room_key.nil?
              @feature_by_community[row.feature] = row
            else
              @feature_by_room[[row.room_key, row.feature]] = row
            end
          end
          @feature_by_community.freeze
          @feature_by_room.freeze
        end

        # { endpoint_key => room_key }, built from the topology every community
        # already carries: each room's endpoints, real and synthetic, map to that
        # room's id, which IS its room_key.
        def build_endpoint_room_index(topology)
          index = {}
          topology.rooms.each do |room|
            room.endpoints.each { |endpoint| index[endpoint.id] = room.id }
          end
          index.freeze
        end

        def deep_merge(base, overlay)
          base.merge(overlay) do |_key, a, b|
            a.is_a?(Hash) && b.is_a?(Hash) ? deep_merge(a, b) : b
          end
        end

        def deep_freeze(value)
          case value
          when Hash then value.each_value { |v| deep_freeze(v) }.freeze
          when Array then value.each { |v| deep_freeze(v) }.freeze
          else value
          end
        end
      end

      # A channel: a thin, frozen wrapper around a Core::Endpoint, tagged with the
      # routing keys and its owning community.
      class Channel
        attr_reader :endpoint, :community_id, :route_key, :mapped_at

        # @param mapped_at [Time, nil] when this channel was first joined to a
        #   room, which is when it began bridging. Backfill will not reach behind
        #   it, so mapping a channel never replays what was said before it.
        def initialize(endpoint:, community_id:, route_key:, mapped_at: nil)
          @endpoint = endpoint
          @community_id = community_id
          @route_key = route_key.to_s
          @mapped_at = mapped_at
          freeze
        end

        def endpoint_key = endpoint.id

        def adapter = endpoint.adapter_name

        def account = endpoint.account
      end

      # A resolved feature setting for one (community, room-or-default,
      # feature). room_key nil marks the community-wide default row.
      FeatureSetting = Struct.new(:room_key, :feature, :enabled, :config, keyword_init: true) do
        def initialize(room_key: nil, feature:, enabled: false, config: {})
          super(room_key: room_key&.to_s, feature: feature.to_s,
                enabled: enabled, config: config || {})
          freeze
        end
      end
    end
  end
end
