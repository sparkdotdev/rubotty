# frozen_string_literal: true

module Rubotty
  module ControlPlane
    # Detects a newly appeared channel/topic/thread in an authorized community
    # and decides whether to prompt an operator to map it, one sighting at a
    # time. A sighting becomes a prompt only for an authorized, active
    # community that has not opted out, a channel not already known, a name
    # matching no IGNORE pattern, and one not already prompted for. Settings
    # live in the community's settings JSON under +new_channel_alerts+ (e.g.
    # { "enabled": true, "ignore": ["temp-", "spoilers"] }), and "enabled"
    # defaults to true when the key is absent.
    class NewChannelWatch
      SETTINGS_KEY = "new_channel_alerts"
      MARKER_PREFIX = "new-channel-prompted"

      # How long an "already prompted" marker lives. Long, because the point is to
      # prompt once: a marker that lapsed after an hour would re-prompt for a topic
      # that simply stayed quiet for a while.
      DEFAULT_TTL = 7 * 24 * 3600

      # A sighting's outcome. +descriptor+ and +community+ let a caller build the
      # operator prompt; +reason+ explains an ignore, for logs and tests.
      Decision = Struct.new(:action, :community, :descriptor, :reason, keyword_init: true) do
        def prompt? = action == :prompt

        def ignore? = action == :ignore
      end

      # @param models [ControlPlane::Models] bound to the control-plane database
      # @param store [#get_state, #put_state] the message map key/value state, for
      #   the prompt-once dedup marker
      # @param ttl [Numeric] marker lifetime in seconds
      # @param logger [#info, nil]
      # @param clock [#call] injectable time source, for a deterministic test
      def initialize(models:, store:, ttl: DEFAULT_TTL, logger: nil, clock: -> { Time.now })
        @models = models
        @store = store
        @ttl = ttl
        @logger = logger
        @clock = clock
      end

      # Evaluate one channel sighting and decide whether to prompt.
      #
      # @param descriptor [Hash] { adapter:, account:, external_id:, route_key:,
      #   name: } where external_id is the coarse space id and route_key is the
      #   channel's normalized address (design 4.2)
      # @return [Decision]
      def observe(descriptor)
        descriptor = normalize(descriptor)
        community = active_community_for(descriptor)
        return ignore(descriptor, :unauthorized) if community.nil?

        settings = alert_settings(community)
        # An ALREADY-KNOWN channel is settled before the alert opt-out, and the
        # order matters: it is what lets ChannelDiscovery#backfill_name correct a
        # placeholder name even in a community that turned alerts off.
        return ignore(descriptor, :already_mapped, community) if channel_known?(community, descriptor)
        return ignore(descriptor, :disabled, community) if falsy(settings["enabled"])
        return ignore(descriptor, :ignored_name, community) if ignored?(descriptor[:name], settings)
        return ignore(descriptor, :already_prompted, community) if prompted?(descriptor)

        mark_prompted(descriptor)
        @logger&.info { "new channel prompt: #{descriptor[:name]} (#{descriptor[:route_key]}) in #{community.slug}" }
        Decision.new(action: :prompt, community: community, descriptor: descriptor)
      end

      private

      def normalize(descriptor)
        {
          adapter: descriptor[:adapter].to_s,
          account: descriptor[:account].to_s,
          external_id: descriptor[:external_id].to_s,
          route_key: descriptor[:route_key].to_s,
          name: descriptor[:name].to_s,
          # Carried through untouched: ChannelDiscovery#backfill_name reads it off
          # the descriptor this returns, so dropping it here would silently
          # disable placeholder replacement.
          supersedes: descriptor[:supersedes]
        }
      end

      def ignore(descriptor, reason, community = nil)
        Decision.new(action: :ignore, reason: reason, descriptor: descriptor, community: community)
      end

      # The active community owning this space, or nil. A stopped community is
      # treated as not-to-prompt.
      def active_community_for(descriptor)
        connection = @models.platform_connection.where(
          adapter: descriptor[:adapter], account: descriptor[:account], external_id: descriptor[:external_id]
        ).first
        return nil if connection.nil?

        community = @models.community[connection.community_id]
        community if community && community.status.to_s == "active"
      end

      def alert_settings(community)
        settings = community.json_value(:settings)
        raw = settings.is_a?(Hash) ? settings[SETTINGS_KEY] : nil
        raw.is_a?(Hash) ? raw : {}
      end

      # Scoped by account as well, because a route_key is only unique WITHIN one
      # account. Without it a sighting from a second Fluxer instance would misread
      # the first instance's row as its own "already mapped" and be ignored.
      def channel_known?(community, descriptor)
        @models.channel.where(
          community_id: community.id, adapter: descriptor[:adapter], account: descriptor[:account],
          route_key: descriptor[:route_key]
        ).first ? true : false
      end

      # Does the channel name match one of the community's ignore patterns? A
      # pattern is a case-insensitive substring, or a simple glob when it contains
      # a "*".
      def ignored?(name, settings)
        patterns = Array(settings["ignore"])
        return false if patterns.empty?

        subject = name.to_s.downcase
        patterns.any? { |pattern| matches?(subject, pattern.to_s.downcase) }
      end

      def matches?(subject, pattern)
        return false if pattern.empty?

        if pattern.include?("*")
          regex = Regexp.new("\\A#{pattern.split("*", -1).map { |part| Regexp.escape(part) }.join(".*")}\\z")
          regex.match?(subject)
        else
          subject.include?(pattern)
        end
      end

      def prompted?(descriptor)
        @store.get_state(marker_key(descriptor)) == "1"
      end

      def mark_prompted(descriptor)
        @store.put_state(marker_key(descriptor), "1", expires_at: @clock.call + @ttl)
      end

      def marker_key(descriptor)
        "#{MARKER_PREFIX}:#{descriptor[:adapter]}:#{descriptor[:account]}:#{descriptor[:route_key]}"
      end

      # "enabled" defaults to true, so only an EXPLICIT false/off opts a community
      # out; an absent key, or any other value, leaves it on.
      def falsy(value)
        value == false || value == "false" || value == 0 || value == "0"
      end
    end
  end
end
