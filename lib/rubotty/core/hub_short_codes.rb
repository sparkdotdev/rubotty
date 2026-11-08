# frozen_string_literal: true

require "set"

module Rubotty
  module Core
    # Assigns a two-letter short code to each room in a hub-mode group, so a
    # user in the one physical channel a hub mirrors several rooms into can
    # address a specific one (`!gs hello` reaches "Gaming & Scheduling"). A
    # code is a pure function of the room list (the first letters of a
    # label's significant words, or the first two of a single word), so it
    # is stable across a restart; collisions resolve in the order given,
    # whoever comes first keeps the natural code. A code can never equal a
    # moderation command word.
    module HubShortCodes
      module_function

      # @param entries [Array<Array(String, String)>] [id, label] pairs, in
      #   the stable order collisions are resolved by
      # @param overrides [Hash{String=>String}] id => operator-chosen code,
      #   taken as given, never recomputed or checked against +reserved+
      # @param reserved [Array<String>, Set<String>] codes that may never be
      #   assigned (case-insensitive)
      # @return [Hash{String=>String}] id => two-letter lowercase code
      def assign(entries, overrides: {}, reserved: [])
        taken = reserved.map { |code| code.to_s.downcase }.to_set
        overrides.each_value { |code| taken << code.to_s.downcase }

        result = {}
        entries.each do |id, label|
          id = id.to_s
          if overrides.key?(id)
            result[id] = overrides[id].to_s.downcase
            next
          end

          code = pick(label, taken)
          taken << code
          result[id] = code
        end
        result
      end

      # candidate code, then successive fallbacks, until one is free
      def pick(label, taken)
        candidates(label).each { |candidate| return candidate unless taken.include?(candidate) }

        # Every derived candidate was taken. Fall back to a numbered code off the
        # first significant letter, which is always eventually free.
        first = first_letter(label)
        counter = 2
        loop do
          candidate = "#{first}#{counter}"
          return candidate unless taken.include?(candidate)

          counter += 1
        end
      end

      # The natural code, then alternates, most specific first.
      def candidates(label)
        significant = words(label)
        out = []
        if significant.size >= 2
          out << (significant[0][0] + significant[1][0])
          # A third+ word gives another alternate before falling back to digits,
          # e.g. "General Chat Room" tries "gc" then "gr".
          significant[2..].to_a.each { |word| out << (significant[0][0] + word[0]) }
        elsif significant.size == 1
          word = significant.first
          out << word[0, 2]
          out << "#{word[0]}#{word[2]}" if word.length > 2
        end
        # A label with no alphanumeric words at all (emoji or punctuation only)
        # leaves +out+ empty here; {#pick}'s own numbered fallback covers it,
        # rather than a second, less stable fallback in this method.
        out.map(&:downcase).uniq
      end

      def first_letter(label)
        word = words(label).first
        (word ? word[0] : "r").downcase
      end

      def words(label)
        label.to_s.scan(/[[:alnum:]]+/).reject(&:empty?)
      end
      private_class_method :candidates, :pick, :first_letter, :words
    end
  end
end
