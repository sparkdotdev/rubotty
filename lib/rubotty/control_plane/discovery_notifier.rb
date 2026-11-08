# frozen_string_literal: true

module Rubotty
  module ControlPlane
    # Carries a channel-discovery prompt to a community's operators.
    # {NewChannelWatch} decides THAT they should be told; this decides HOW: it
    # posts to the community's designated operator room
    # (+operator_requests+/+notify_room+), since a bot cannot reliably DM a
    # user who has never messaged it. Best effort throughout: a lost prompt
    # must never disturb a receive loop, and a community with no operator room
    # just has the sighting logged. This only surfaces a suggestion; it never
    # changes routing.
    class DiscoveryNotifier
      # The feature whose config names the operator room, and the key within it.
      FEATURE = "operator_requests"
      CONFIG_KEY = "notify_room"

      # @param registry [Registry, nil] the live snapshot, read for the target
      #   community's operator room and its endpoints
      # @param ephemeral [#post, nil] the ephemeral-message poster; nil means the
      #   prompt is logged rather than posted
      # @param logger [#info, #warn, nil]
      # @param name [String] the sender name the prompt posts under
      def initialize(registry:, ephemeral: nil, logger: nil, name: "rubotty")
        @registry = registry
        @ephemeral = ephemeral
        @logger = logger
        @name = name
      end

      # Tell the community's operators about a discovered channel. Posts to the
      # operator room when one is configured and a poster is available, else logs.
      #
      # @param community [#id, #slug, #name] the owning community (a Sequel row)
      # @param descriptor [Hash] { adapter:, name:, route_key:, ... }
      def prompt(community:, descriptor:)
        return if community.nil?

        room = notify_room(community)
        if @ephemeral.nil? || room.nil? || room.endpoints.empty?
          @logger&.info do
            "channel discovery: new #{descriptor[:adapter]} channel #{descriptor[:name].inspect} " \
              "in #{community.slug}; no operator room configured, not pushed"
          end
          return
        end

        @ephemeral.post(endpoints: room.endpoints, body: Core::RichText.plain(body(community, descriptor)),
                        name: @name)
      rescue StandardError => e
        @logger&.warn { "channel discovery: could not notify operators in #{community&.slug}: #{e.message}" }
      end

      private

      def notify_room(community)
        snap = @registry&.current&.community_by_id(community.id)
        return nil if snap.nil?

        key = snap.feature_config(nil, FEATURE)[CONFIG_KEY]
        return nil if key.nil? || key.to_s.strip.empty?

        snap.rooms.find { |room| room.id == key.to_s }
      end

      def body(community, descriptor)
        "New #{descriptor[:adapter]} channel #{descriptor[:name].to_s.inspect} appeared in " \
          "#{community.name}. Reply `map` in the operator console to map it across platforms."
      end
    end
  end
end
