# frozen_string_literal: true

module Rubotty
  module Events
    # The emoji vocabulary for reaction-based RSVP capture, read by both the card
    # that seeds them and the handler that reads them back. All three come from
    # Telegram's whitelist: an emoji outside it cannot be tapped there at all.
    module RsvpReactions
      GOING = Core::Reaction.new(emoji: "👍")
      MAYBE = Core::Reaction.new(emoji: "🤔")
      NO    = Core::Reaction.new(emoji: "👎")

      # The reactions to place on a freshly posted card, leftmost first, for one
      # rsvp_mode. Empty for "none" and for anything unrecognised.
      #
      # @param rsvp_mode [String]
      # @return [Array<Core::Reaction>]
      def self.for_mode(rsvp_mode)
        case rsvp_mode.to_s
        when Event::RSVP_AFFIRM then [GOING].freeze
        when Event::RSVP_FULL then [GOING, MAYBE, NO].freeze
        else [].freeze
        end
      end

      # The event_rsvps.response value an incoming reaction maps to under
      # +rsvp_mode+, or nil. Normalises the variation selector first, since the
      # same emoji arrives with and without U+FE0F depending on the platform.
      #
      # @param rsvp_mode [String]
      # @param reaction [Core::Reaction, nil]
      # @return [String, nil]
      def self.response_for(rsvp_mode, reaction)
        return nil if reaction.nil? || reaction.custom?

        key = reaction.without_variation_selector
        case rsvp_mode.to_s
        when Event::RSVP_AFFIRM
          key == GOING ? "in" : nil
        when Event::RSVP_FULL
          case key
          when GOING then "yes"
          when MAYBE then "maybe"
          when NO then "no"
          end
        end
      end
    end
  end
end
