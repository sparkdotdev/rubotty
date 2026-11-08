# frozen_string_literal: true

module Rubotty
  module Adapters
    module Irc
      # Per-room short codes for hub mode: lets a user in the ONE physical channel a
      # hub mirrors several rooms into say which room a message is for.
      #
      #     !gs hello        -> delivered into the room coded "gs"
      #     !rooms           -> lists every room mapped into this channel, with its code
      #     !xx hello        -> "xx" matches no room: an ephemeral notice, nothing relayed
      # Only a channel with MORE THAN ONE endpoint gets codes at all; {Core::HubShortCodes}
      # only assigns TWO LETTER codes and every moderation action is three-plus, so a code can never equal a command word.
      class HubRouter
        SIGILS = %w[! . > :].freeze
        LISTING_WORD = "rooms"

        # @!attribute kind
        #   :addressed    a valid code, +text+ has the prefix stripped
        #   :listing      "!rooms" or equivalent, list every code
        #   :unknown_code looked like a code, matched no room
        Resolution = Struct.new(:kind, :text, :target_endpoint_id, :exclude_ids, :code, keyword_init: true)

        # The key one hub group is held under. A physical channel alone is not
        # one: two communities can map the same channel on the same account,
        # and their rooms are not addressable from each other.
        def self.key_for(community_id, channel) = [community_id, channel.to_s.downcase]

        # @param channel_groups [Hash{Array=>Array<Core::Endpoint>}] every
        #   endpoint sharing a physical channel WITHIN ONE COMMUNITY, keyed by
        #   {.key_for}. A bare channel name is refused rather than assumed.
        # @param reserved [Array<String>] codes that may never be assigned;
        #   defaults to every moderation action word
        def initialize(channel_groups:, reserved: Core::Moderation::ACTIONS.map(&:to_s))
          @codes = {}
          @code_by_endpoint = {}
          # Every endpoint on the physical channel whatever community owns it,
          # so the fan-out exclusion still covers the whole channel and a relay
          # cannot echo back into it through a neighbour's endpoint.
          @on_channel = Hash.new { |hash, key| hash[key] = [] }
          channel_groups.each { |key, group| index_group(key, group, reserved) }
          @on_channel.default = [].freeze
        end

        # Whether +community_id+ has more than one room mapped into +channel+,
        # i.e. whether short codes mean anything here for that tenant.
        def hub?(community_id, channel) = @codes.key?(self.class.key_for(community_id, channel))

        # This endpoint's own short code, for rendering on every inbound line.
        # nil outside a hub channel. Scoped by the endpoint's own community, so
        # a neighbour's identical channel cannot answer for it.
        def code_for(endpoint)
          @code_by_endpoint[[endpoint.community_id, endpoint.id]]
        end

        # Interpret one inbound line for +community_id+ on +channel+. Returns nil
        # for an ordinary message with nothing to reinterpret (no sigil, no code
        # shape, or a real command), which lets the real command handler have it.
        def resolve(community_id, channel, text)
          key = self.class.key_for(community_id, channel)
          codes = @codes[key]
          return nil if codes.nil?

          body, sigil = strip_sigil(text)
          return nil if sigil.nil?

          word, rest = body.split(/\s+/, 2)
          return nil if word.nil? || word.empty?

          return Resolution.new(kind: :listing) if word.casecmp?(LISTING_WORD)
          return nil unless word.length == 2
          return nil if Core::Moderation.known?(word.downcase.to_sym)

          target = codes[word.downcase]
          return Resolution.new(kind: :unknown_code, code: word.downcase) if target.nil?

          Resolution.new(
            kind: :addressed, text: rest.to_s, target_endpoint_id: target.id,
            exclude_ids: @on_channel[key.last]
          )
        end

        # Every room +community_id+ has mapped into +channel+, with its code.
        def listing_text(community_id, channel)
          codes = @codes[self.class.key_for(community_id, channel)]
          return "no rooms are mapped into this channel" if codes.nil? || codes.empty?

          codes.sort.map { |code, endpoint| "#{code}: #{room_label_of(endpoint)}" }.join(", ")
        end

        def unknown_code_text(code)
          "\"#{code}\" does not match a room here. Say \"!rooms\" to list them."
        end

        private

        # Refuses a bare channel name outright: a group keyed on one is the
        # cross-tenant group this keying exists to make unbuildable.
        def index_group(key, group, reserved)
          unless key.is_a?(Array) && key.size == 2
            raise ArgumentError, "a hub group is keyed by [community_id, channel], got #{key.inspect}"
          end

          key = self.class.key_for(key.first, key.last)
          @on_channel[key.last].concat(group.map(&:id))
          return unless group.size > 1

          @codes[key] = assign_codes(key, group, reserved)
        end

        def assign_codes(key, group, reserved)
          assigned = Core::HubShortCodes.assign(
            group.map { |endpoint| [endpoint.id, room_label_of(endpoint)] },
            overrides: overrides_for(group), reserved: reserved
          )
          assigned.each_with_object({}) do |(endpoint_id, code), out|
            out[code] = group.find { |endpoint| endpoint.id == endpoint_id }
            @code_by_endpoint[[key.first, endpoint_id]] = code
          end
        end

        def overrides_for(group)
          group.each_with_object({}) do |endpoint, out|
            code = endpoint.settings[:short_code].to_s.strip
            out[endpoint.id] = code unless code.empty?
          end
        end

        def room_label_of(endpoint)
          label = endpoint.settings[:room_label].to_s.strip
          label.empty? ? endpoint.label : label
        end

        def strip_sigil(text)
          text = text.to_s
          sigil = SIGILS.find { |candidate| text.start_with?(candidate) }
          return [nil, nil] if sigil.nil?

          [text[1..].to_s.strip, sigil]
        end
      end
    end
  end
end
