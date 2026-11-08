# frozen_string_literal: true

module Rubotty
  module Polls
    # How a scheduling session reads a candidate time, whether given at
    # creation or suggested later by a reply, both through
    # {ControlPlane::RelativeTime} so /event and /schedule read "tuesday 7pm"
    # the same way.
    module ScheduleSlots
      module_function

      # @param text [String] what somebody replied with, "tuesday 7pm"
      # @param timezone [String, nil] the zone the session was opened in, so
      #   everybody's suggestion is read against the same clock
      # @param now [Time]
      # @return [Time, nil] a UTC instant strictly after +now+, or nil
      def suggested(text, timezone: nil, now: Time.now)
        slot = ControlPlane::RelativeTime.parse(text, timezone: timezone, now: now)
        slot if slot && slot > now
      end

      # The card re-renders the instant per platform; this is the fallback.
      def label(time, timezone) = Util::EventTimestamps.full(time, timezone.to_s.empty? ? "UTC" : timezone)
    end
  end
end
