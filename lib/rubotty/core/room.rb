# frozen_string_literal: true

module Rubotty
  module Core
    # One concrete place on one platform: a Telegram forum topic, a Discord
    # text channel, a Matrix room, an IRC channel.
    #
    # An Endpoint holds only the operator's intent. Everything the platform needs
    # in order to address it lives in +settings+, whose shape is declared by the
    # owning adapter through `Adapter.endpoint_schema`; core never reads it.
    class Endpoint
      # NOTE: the readers are named `receives`/`sends` rather than
      # `receive`/`send`. A reader called `send` would shadow Object#send on
      # every Endpoint instance.
      attr_reader :id, :adapter_name, :account, :settings, :receives, :sends, :relay,
                  :display_name_template, :display_name_fallback, :label

      # The tenant that owns this endpoint, nil ONLY on the config-file path,
      # which has no other community to reach. Everything the control plane
      # builds carries the real id, and {Core::CommunityScope} is what refuses
      # to let a resolution or a delivery cross from one to another.
      attr_reader :community_id

      # @param id [String] operator chosen, unique across the whole config
      # @param adapter_name [Symbol] which adapter owns this endpoint
      # @param account [String] which credentialed connection to use
      # @param settings [Hash] adapter specific addressing, symbol keyed
      # @param receives [Boolean] accept inbound messages from this endpoint
      # @param display_name_template [String, nil] overrides the room and global
      #   templates for messages ORIGINATING here
      # @param label [String, nil] human facing name, logging only
      def initialize(id:, adapter_name:, account:, settings: {}, receives: true, sends: true,
                     relay: {}, display_name_template: nil, display_name_fallback: nil, label: nil,
                     community_id: nil)
        @id = id.to_s
        @adapter_name = adapter_name.to_sym
        @account = account.to_s
        @community_id = community_id
        @settings = symbolize(settings).freeze
        @receives = receives
        @sends = sends
        @relay = relay.freeze
        @display_name_template = display_name_template
        @display_name_fallback = display_name_fallback
        @label = label || @id
        freeze
      end

      # The control-plane constructor, where a community always exists and a
      # nil is therefore a build site that forgot rather than a config file
      # with no tenants. {.new} keeps the optional keyword for that config path.
      #
      # @raise [ArgumentError]
      def self.owned_by(community_id, **attrs)
        raise ArgumentError, "an endpoint the control plane builds needs its community" if community_id.nil?

        new(community_id: community_id, **attrs)
      end

      def receives? = @receives

      def sends? = @sends

      # Whether an event of this kind is allowed to leave this endpoint, since an
      # operator commonly wants join and leave noise in one direction only.
      def relay?(policy)
        value = @relay[policy.to_sym]
        value.nil? ? true : !!value
      end

      def to_s = "#{id} (#{adapter_name})"

      def inspect = "#<Endpoint #{self}>"

      private

      def symbolize(hash)
        return {} if hash.nil?

        hash.each_with_object({}) { |(key, value), out| out[key.to_sym] = value }
      end
    end

    # A set of endpoints that see each other's messages. Topology is N way by
    # construction: a message arriving at any member endpoint fans out to every
    # OTHER member endpoint, and pairwise bridging is simply a room with two.
    class Room
      attr_reader :id, :endpoints, :display_name_template, :display_name_fallback, :label

      # The tenant that owns this room, nil ONLY on the config-file path, which
      # has no other community to reach. A scoping check compares this rather
      # than parsing a prefix back off {#unique_id}, and {Core::CommunityScope}
      # narrows a pool of rooms through it exactly as it does endpoints.
      attr_reader :community_id

      # @param unique_id [String, nil] this room's identity across the WHOLE
      #   deployment. +id+ is the room_key, which is only unique within one
      #   community, so anything indexing rooms out of the merged Snapshot
      #   topology has to key on this. Derived from +community_id+ when there is
      #   one, and otherwise +id+, which is right for the config path.
      def initialize(id:, endpoints:, display_name_template: nil, display_name_fallback: nil,
                     label: nil, unique_id: nil, community_id: nil)
        @id = id.to_s
        @community_id = community_id
        @unique_id = (unique_id || derived_unique_id).to_s
        @endpoints = endpoints.freeze
        @display_name_template = display_name_template
        @display_name_fallback = display_name_fallback
        @label = label || @id
        freeze
      end

      attr_reader :unique_id

      # The control-plane constructor, the same bar {Endpoint.owned_by} holds:
      # a room built from rows always has a community, so a nil here is a
      # forgotten argument and not a deployment without tenants.
      #
      # @raise [ArgumentError]
      def self.owned_by(community_id, **attrs)
        raise ArgumentError, "a room the control plane builds needs its community" if community_id.nil?

        new(community_id: community_id, **attrs)
      end

      def endpoint(endpoint_id)
        endpoints.find { |e| e.id == endpoint_id.to_s }
      end

      def include?(endpoint_id) = !endpoint(endpoint_id).nil?

      # The endpoints a message arriving at +origin+ should be delivered to.
      # Excluding the origin here is the primary, structural loop prevention: a
      # message can never be delivered back to the endpoint it came from. A
      # single-platform room answers empty rather than raising: it is an
      # ordinary room with nowhere else to fan out to, not a special case. A
      # feature that needs every endpoint in the room, puppeting included,
      # reads +endpoints+ directly instead.
      def targets_for(origin)
        origin_id = origin.respond_to?(:id) ? origin.id : origin.to_s
        endpoints.reject { |e| e.id == origin_id }.select(&:sends?)
      end

      def to_s = "#{id} [#{endpoints.map(&:id).join(", ")}]"

      def inspect = "#<Room #{self}>"

      private

      def derived_unique_id = @community_id.nil? ? @id : "#{@community_id}:#{@id}"
    end

    # The full topology: every room, indexed for lookup by endpoint.
    #
    # An endpoint may belong to more than one room, which is how an operator
    # builds a hub. {Router} guards against the cycles that this makes possible.
    class Topology
      attr_reader :rooms

      def initialize(rooms)
        @rooms = rooms.freeze
        @by_endpoint = build_index(rooms).freeze
        @endpoints = rooms.flat_map(&:endpoints).uniq(&:id).freeze
        freeze
      end

      # Every room that contains +endpoint_id+ and accepts input from it.
      def rooms_for(endpoint_id)
        @by_endpoint.fetch(endpoint_id.to_s, [])
      end

      def endpoints = @endpoints

      def endpoint(endpoint_id)
        @endpoints.find { |e| e.id == endpoint_id.to_s }
      end

      # Every distinct account referenced, grouped by adapter. Used at boot to
      # decide which adapter instances to construct.
      def accounts_by_adapter
        @endpoints.group_by(&:adapter_name).transform_values { |list| list.map(&:account).uniq }
      end

      def empty? = rooms.empty?

      private

      def build_index(rooms)
        rooms.each_with_object(Hash.new { |h, k| h[k] = [] }) do |room, index|
          room.endpoints.each do |endpoint|
            index[endpoint.id] << room if endpoint.receives?
          end
        end
      end
    end
  end
end
