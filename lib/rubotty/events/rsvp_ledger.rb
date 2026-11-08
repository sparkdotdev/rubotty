# frozen_string_literal: true

module Rubotty
  module Events
    # Records one identity's response to an event: the write side of
    # event_rsvps, shared by both capture surfaces (a reaction on the card and
    # the /rsvp command), so the rules live in one place.
    class RsvpLedger
      # Raised for a response the event's rsvp_mode does not accept. Carries a
      # human message the /rsvp reply prints as-is.
      class Invalid < Rubotty::Error; end

      # The response values a mode accepts. "none" is absent, so it gets none.
      RESPONSES_BY_MODE = {
        Event::RSVP_AFFIRM => %w[in].freeze,
        Event::RSVP_FULL => %w[yes maybe no].freeze
      }.freeze

      # @param models [ControlPlane::Models] bound to the control-plane database
      # @param logger [#debug, nil]
      # @param clock [#call] injectable time source, for deterministic tests
      def initialize(models:, logger: nil, clock: -> { Time.now })
        @models = models
        @logger = logger
        @clock = clock
      end

      # The response values +event+'s rsvp_mode currently accepts. Empty for
      # "none".
      #
      # @param event [Events::Event]
      # @return [Array<String>]
      def allowed_for(event)
        RESPONSES_BY_MODE.fetch(event.rsvp_mode, [].freeze)
      end

      # Record or move +identity+'s response to +event+, enforcing the event's
      # rsvp_mode.
      #
      # @param platform [String] where this response came from; informational
      # @param response [String] the value to record, validated
      #   case-insensitively against the event's own mode
      # @return [String] the response actually recorded, lower-cased
      # @raise [Invalid] for a response the event's mode does not accept
      def record(event:, identity:, platform:, response:)
        allowed = allowed_for(event)
        raise Invalid, "RSVP is not enabled for this event." if allowed.empty?

        value = response.to_s.strip.downcase
        raise Invalid, "response must be #{allowed.join(" or ")}." unless allowed.include?(value)

        clean_identity = identity.to_s
        row = find_row(event, clean_identity)
        now = @clock.call
        if row
          row.update(response: value, platform: platform.to_s, responded_at: now)
        else
          @models.event_rsvp.create(
            event_id: event.id, identity: clean_identity, platform: platform.to_s,
            response: value, responded_at: now
          )
        end
        value
      end

      # Clear +identity+'s response to +event+, only when a row is present and,
      # if +expected_response+ is given, its current value matches.
      #
      # @param event [Events::Event]
      # @param identity [String]
      # @param expected_response [String, nil] when given, only clear a row
      #   still holding exactly this value
      # @return [Boolean] whether a row was actually removed
      def clear(event:, identity:, expected_response: nil)
        row = find_row(event, identity.to_s)
        return false if row.nil?
        return false if expected_response && row.response != expected_response.to_s

        row.destroy
        true
      end

      # +identity+'s current response to +event+, or nil.
      #
      # @return [String, nil]
      def response_for(event:, identity:)
        find_row(event, identity.to_s)&.response
      end

      private

      def find_row(event, identity)
        @models.event_rsvp.where(event_id: event.id, identity: identity).first
      end
    end
  end
end
