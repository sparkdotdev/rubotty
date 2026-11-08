# frozen_string_literal: true

module Rubotty
  module Events
    # The words an event's RSVP tally is written under, shared by the card,
    # the reminder and /events so the three surfaces cannot drift into calling
    # the same number different things.
    module RsvpLabels
      # The affirmative count sits directly under the card's relative
      # timestamp, so it is spelled out: a bare "In: 5" there was read as five
      # minutes rather than five people.
      ATTENDING = "Attending"

      # What an answer nobody has given yet is written as, rather than a zero
      # that reads as a quantity of something.
      NOBODY = "nobody yet"

      # The full-mode responses in the order they are shown, each with the word
      # it appears under.
      FULL = [%w[yes Going], %w[maybe Maybe], %w[no No]].freeze

      module_function

      # The affirm-mode summary line, for a card, a reminder or /events alike.
      #
      # @param answer [String, nil] the rendered roster: handles, or a bare
      #   count where the surface truncates, and nil for nobody at all
      # @return [String]
      def attending_line(answer)
        text = answer.to_s.strip
        "#{ATTENDING}: #{text.empty? ? NOBODY : text}"
      end
    end
  end
end
