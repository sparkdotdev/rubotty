# frozen_string_literal: true

module Rubotty
  module Core
    # The guided form a command's {CommandRegistry::Spec} already describes:
    # which fields a builder asks for, how each prompt is worded, whether an
    # answer will do, and how the answers become the command line the ordinary
    # parsers read. Nothing here knows a single command by name, so a command
    # added to the registry gets its form from the same metadata.
    module CommandForm
      # The words that steer a form rather than answer it, said with the
      # room's own command marker so they cannot be mistaken for a value.
      SKIP = "skip"
      DONE = "done"
      CANCEL = "cancel"

      # What a boolean answer may be said as, and what it becomes.
      TRUTHS = %w[yes y true on 1].freeze
      FALSEHOODS = %w[no n false off 0].freeze

      module_function

      # Whether a command can be built by asking one field at a time. It needs
      # fields to ask for, and it may not need a reply target, which is a
      # gesture rather than something a person can type.
      def buildable?(spec)
        return false if spec.nil?

        spec.target == :none && !spec.arguments.empty?
      end

      # The prompt for one field: which command is being built, how far along
      # this is, the field's own name and the description the registry already
      # writes as an explanation of it, then what may be said back.
      #
      # @param addressee [String, nil] the invoker's name, printed where the
      #   platform cannot hang the prompt off their message as a reply
      # @param finishable [Boolean] whether nothing required is still unanswered
      def prompt(spec, index, marker:, addressee: nil, finishable: false)
        argument = spec.arguments[index]
        opening = "#{addressee}: " if addressee
        "#{opening}/#{spec.name} (#{index + 1} of #{spec.arguments.length}#{", optional" unless argument.required?})" \
          ": #{argument.name}. #{sentence(argument.description)} #{closing(argument, marker, finishable)}"
      end

      # What may be said back to one prompt. A command with nine optional
      # fields is not nine more questions: once nothing required is left, the
      # form can be run from where it stands.
      def closing(argument, marker, finishable = false)
        words = ["Reply with a value"]
        words << "#{marker}#{SKIP} to leave it out" unless argument.required?
        words << "#{marker}#{DONE} to run it now" if finishable
        "#{words.join(", ")}, or #{marker}#{CANCEL} to stop."
      end

      # Why +value+ will not do as an answer to +argument+, or nil when it
      # will. Judged against the declared type alone: whatever only the
      # command itself can decide is still the command's own to refuse.
      def complaint(argument, value)
        text = value.to_s.strip
        return "That field needs a value." if text.empty?

        case argument.type
        when :integer
          "That field needs a whole number." unless Integer(text, exception: false)
        when :boolean
          "That field needs yes or no." unless (TRUTHS + FALSEHOODS).include?(text.downcase)
        end
      end

      # The answer as the command line should carry it: a boolean normalised
      # to true or false, anything else exactly as it was said.
      def normalise(argument, value)
        text = value.to_s.strip
        return text unless argument.type == :boolean

        TRUTHS.include?(text.downcase).to_s
      end

      # The answers as the line a person would have typed, which is the one
      # portable form every command parser already reads: a keyed argument
      # written by {KeyedArguments.field}, the module that reads it back, and
      # a plain one its bare value in the order the registry declares it.
      def command_line(spec, values, marker:)
        words = ["#{marker}#{spec.name}"]
        spec.arguments.each do |argument|
          value = values[argument.name].to_s
          next if value.strip.empty?

          words << (argument.keyed? ? KeyedArguments.field(argument.name, value) : value)
        end
        words.join(" ")
      end

      # Which form word +text+ says, or nil when it says neither. Read through
      # the room's own markers, so a value of "skip" is still a value.
      def control(text, prefixes)
        body = prefixes.strip(text.to_s)
        return nil if body.nil?

        word = body.split(/\s+/).first.to_s.downcase
        return :skip if word == SKIP
        return :done if word == DONE
        return :cancel if word == CANCEL

        nil
      end

      # One description as one sentence, whether or not the registry's own
      # entry already ends in a full stop.
      def sentence(description)
        text = description.to_s.strip
        text.end_with?(".", "?", "!") ? text : "#{text}."
      end
    end
  end
end
