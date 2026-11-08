# frozen_string_literal: true

require "securerandom"
require "shellwords"

module Rubotty
  module Features
    # The voting mechanism /poll and /schedule share. A keycap reaction is how a
    # vote is cast where the platform allows one, a button press where it does
    # not (Telegram's reaction whitelist has no keycap digits), and a reply
    # anywhere the room has switched that on.
    module PollSurface
      include AdapterLookup
      include CardCancellation

      NOTICE_NAME = "rubotty"

      OBSERVES = %i[chat reaction_add reaction_remove reaction_sync button_press].freeze

      # @param topology [Core::Topology] only for the default ephemeral
      # @param adapters [Hash{[Symbol,String]=>Adapters::Base}] the shared map
      # @param polls [ControlPlane::Polls, nil] nil makes the feature a no-op
      # @param ballot [Polls::Ballot, nil]
      # @param lifecycle [Polls::Lifecycle, nil]
      # @param activity [Polls::RoomActivity, nil]
      # @param ephemeral [Core::EphemeralMessage, nil] posts the reply
      # @param cleanup [Core::Scheduler, nil] fires the reply's self-delete
      def initialize(topology:, adapters:, logger:, polls: nil, board: nil, ballot: nil,
                     lifecycle: nil, activity: nil, ephemeral: nil, cleanup: nil)
        super()
        @adapters = adapters
        @logger = logger
        @polls = polls
        @board = board
        @ballot = ballot
        @lifecycle = lifecycle
        @activity = activity
        @cleanup = cleanup
        @ephemeral = ephemeral || Core::EphemeralMessage.new(
          adapters: adapters, topology: topology, session_id: SecureRandom.uuid, logger: logger
        )
      end

      attr_reader :logger

      def call(context)
        case context.message.kind
        when :reaction_add, :reaction_remove, :reaction_sync
          # A reaction carries no command word to recognise, so an unconfigured
          # deployment has nothing to refuse; it just cannot see the tap.
          return Outcome.continue([]) if @polls.nil? || @board.nil? || @ballot.nil?

          handle_reaction(context)
        when :button_press
          return Outcome.continue([]) if @polls.nil? || @board.nil? || @ballot.nil?

          handle_press(context)
        when :chat then handle_chat(context)
        else Outcome.continue([])
        end
      end

      def command_word
        raise NotImplementedError, "#{self.class} must define #command_word"
      end

      # So a reaction on one kind's card is never read by the other's handler.
      def poll_kind
        raise NotImplementedError, "#{self.class} must define #poll_kind"
      end

      private

      # Called with the text after the command word.
      def handle_open(_context, _raw)
        raise NotImplementedError, "#{self.class} must define #handle_open"
      end

      # @return [Hash, nil] {label:, starts_at:}, or nil to leave the reply alone
      def option_attributes(_context, _poll, text) = { label: text }

      # --- reactions ---

      def handle_reaction(context)
        message = context.message
        poll = poll_for(message.ref)
        return Outcome.continue([]) if poll.nil?

        if message.reaction_sync?
          # An anonymous-reactions Telegram chat (a channel, or a large
          # supergroup) reports its whole state with no author, so nothing
          # here can say who tapped it. Swallowed rather than falling through
          # to Bridge's aggregate mirror; the reply fallback is the only way to answer in a room like this.
          logger.debug { "#{command_word}: an anonymous reaction synced on poll #{poll.id}, nobody to attribute it to" }
          return Outcome.halt([])
        end
        return Outcome.continue([]) if message.reaction.nil?

        apply_reaction(poll, message)
        # Swallowed either way, so it never reaches the bridge's aggregate mirror.
        Outcome.halt([])
      end

      def apply_reaction(poll, message)
        return unless poll.open?

        position = Polls::OptionEmoji.position_for(message.reaction)
        return if position.nil?

        option = @polls.option_at(poll, position)
        return if option.nil?

        identity = identity_for(message.author)
        return if identity.nil?

        changed =
          if message.kind == :reaction_add
            @ballot.record(
              poll: poll, option: option, identity: identity,
              platform: message.origin.adapter_name.to_s, handle: handle_for(message.author)
            )
          else
            @ballot.clear(poll: poll, option: option, identity: identity)
          end
        @board.refresh(poll) if changed
      end

      # --- buttons ---

      def handle_press(context)
        poll = poll_for(context.message.ref)
        return Outcome.continue([]) if poll.nil?

        apply_press(poll, context.message)
        # Swallowed the way a reaction on a card is, so a press never reaches
        # the bridge and never crosses to another platform.
        Outcome.halt([])
      end

      # One inline keyboard serves everybody who can see the card, so a press
      # cannot say whether it means "count me in" or "take it back", and the
      # ballot decides: pressing an option you already back withdraws it.
      def apply_press(poll, message)
        return unless poll.open?

        position = Polls::VoteButtons.position_for(message.button)
        return if position.nil?

        option = @polls.option_at(poll, position)
        return if option.nil?

        identity = identity_for(message.author)
        return if identity.nil?

        @board.refresh(poll) if toggle_vote(poll, option, identity, message)
      end

      def toggle_vote(poll, option, identity, message)
        held = @ballot.holds?(poll: poll, option: option, identity: identity)
        return @ballot.clear(poll: poll, option: option, identity: identity) if held

        @ballot.record(
          poll: poll, option: option, identity: identity,
          platform: message.origin.adapter_name.to_s, handle: handle_for(message.author)
        )
      end

      # --- chat ---

      def handle_chat(context)
        remember_activity(context)

        outcome = handle_reply(context)
        return outcome unless outcome.nil?

        # The word is read BEFORE the service/community check, so an unconfigured
        # deployment refuses a real invocation instead of relaying it.
        raw = command_text(context)
        return Outcome.continue([]) if raw.nil?

        return refuse_unconfigured(context) if @polls.nil? || @board.nil? || @ballot.nil? || context.community.nil?

        handle_open(context, raw)
        Outcome.halt([])
      end

      # Recognised as this surface's own command but nothing here can act on it:
      # no operations service wired, or no community resolved for this channel.
      def refuse_unconfigured(context)
        acknowledge(context, "Sorry, /#{command_word} is not available on this bridge.")
        Outcome.halt([])
      end

      # Every message pushes a card further up the scrollback, which is the
      # whole input the six-hourly repost decision runs on.
      def remember_activity(context)
        return if @activity.nil? || context.community.nil?

        room_key = context.community.room_key_of(context.channel)
        return if room_key.nil?

        @activity.record(
          Polls::RoomActivity.key(context.community.id, room_key),
          at: context.message.timestamp, ref: context.message.ref
        )
      rescue StandardError => e
        logger.debug { "#{command_word}: could not note room activity: #{e.message}" }
      end

      # nil hands the message on to the command parser. Without a board there is
      # nothing to look a reply's card up against, so this reads as "not a reply
      # to us" rather than raising; the command parser answers instead.
      def handle_reply(context)
        return nil if @board.nil?

        message = context.message
        return nil if message.reply_to.nil?

        poll = poll_for(message.reply_to)
        return nil if poll.nil?

        text = message.body&.text.to_s.strip
        return nil if text.empty?

        return handle_cancel(context, poll) if cancel_reply?(context, text)
        return nil unless poll.open?

        acted = apply_reply(context, poll, text)
        # An ordinary comment on the card still belongs in the other rooms.
        acted ? Outcome.halt([]) : Outcome.continue([])
      end

      # A reply of "cancel" (with or without the room's own command prefix)
      # on our own card. Checked ahead of #poll.open? so a duplicate cancel
      # on an already closed poll still gets a clear answer instead of
      # silently falling through to the command parser.
      def handle_cancel(context, poll)
        label = poll.schedule? ? "Scheduling poll" : "Poll"
        unless may_cancel?(context, poll)
          acknowledge(context, "Only #{label.downcase} ##{poll.id}'s creator or a room operator can cancel it.")
          return Outcome.halt([])
        end

        if poll.open?
          @lifecycle&.close(poll.id)
          acknowledge(context, "#{label} ##{poll.id} canceled by #{cancel_actor_label(context)}.")
        else
          acknowledge(context, "#{label} ##{poll.id} is already closed.")
        end
        Outcome.halt([])
      end

      # @return [Boolean] whether the reply was read as a vote or an option
      def apply_reply(context, poll, text)
        return true if poll.reply_votes? && vote_by_reply(context, poll, text)
        return true if poll.reply_options? && add_option_by_reply(context, poll, text)

        false
      end

      def vote_by_reply(context, poll, text)
        option = option_named(poll, text)
        return false if option.nil?

        identity = identity_for(context.message.author)
        return false if identity.nil?

        changed = @ballot.record(
          poll: poll, option: option, identity: identity,
          platform: context.message.origin.adapter_name.to_s, handle: handle_for(context.message.author)
        )
        @board.refresh(poll) if changed
        acknowledge(context, "Recorded your vote for #{option.label}.")
        true
      end

      def option_named(poll, text)
        position = Integer(text, exception: false)
        return @polls.option_at(poll, position) if position&.between?(1, Polls::Poll::MAX_OPTIONS)

        @polls.options(poll).find { |option| option.label.to_s.strip.casecmp(text).zero? }
      end

      def add_option_by_reply(context, poll, text)
        attributes = option_attributes(context, poll, text)
        return false if attributes.nil?

        option = @polls.add_option(
          poll: poll, label: attributes[:label], starts_at: attributes[:starts_at],
          suggested_by: issuer_label(context)
        )
        @board.refresh(poll)
        logger.info { "#{command_word}: added option #{option.position} to poll #{poll.id}" }
        acknowledge(context, "Added option ##{option.position}: #{option.label}.")
        true
      rescue ControlPlane::Polls::Invalid => e
        acknowledge(context, e.message)
        true
      end

      # --- inline command parsing ---

      # A trailing pipe segment shaped like key=value, no spaces anywhere in
      # it, is a directive rather than a positional argument (a question, an
      # option, a scheduling time). The first one found ends the positional
      # list; everything from there to the end is read the same way, so
      # several can be stacked, e.g. "... | reply_options=yes | duration=24h".
      DIRECTIVE_SHAPE = /\A(\w+)=(\S+)\z/

      # @return [Array<String>] pipe separated when the text contains a pipe,
      #   else read the way Shellwords quotes it; either way each part comes
      #   back trimmed, with its own wrapping quotes peeled off, and empties
      #   dropped
      def split_command_parts(text)
        raw = text.to_s.strip
        return [] if raw.empty?

        parts = raw.include?("|") ? raw.split("|") : shell_split(raw)
        parts = parts.map { |part| strip_wrapping_quotes(part.to_s.strip) }.reject(&:empty?)
        parts.flat_map { |part| peel_trailing_directives(part) }
      end

      # A keyed argument off a native Discord slash command lands glued onto
      # the end of the last part with a space, not its own pipe segment
      # (Interactions#body_text has no pipe to insert between a free-text
      # argument and a keyed one). Peeling any directive shaped trailing
      # word off here means a bracket-free key=value reads the same way
      # whether it was typed by hand or came back from the picker.
      def peel_trailing_directives(part)
        words = part.split(/\s+/)
        return [part] if words.size <= 1

        trailing = []
        trailing.unshift(words.pop) while words.size > 1 && DIRECTIVE_SHAPE.match?(words.last)
        return [part] if trailing.empty?

        [words.join(" "), *trailing]
      end

      def shell_split(text)
        Shellwords.split(text)
      rescue ArgumentError
        text.split(/\s+/)
      end

      def strip_wrapping_quotes(text)
        return text if text.size < 2

        quote = text[0]
        return text unless %w[" '].include?(quote) && text[-1] == quote

        text[1..-2]
      end

      # @param parts [Array<String>]
      # @return [Array(Array<String>, Hash<Symbol,String>)] the positional
      #   parts ahead of the first directive, and every directive from there
      #   on, keyed by the lowercased name it was given under
      def split_directives(parts)
        index = parts.index { |part| DIRECTIVE_SHAPE.match?(part) }
        return [parts, {}] if index.nil?

        directives = {}
        parts[index..].each do |part|
          match = DIRECTIVE_SHAPE.match(part)
          raise ControlPlane::Polls::Invalid, "#{part.inspect} is not a key=value option." if match.nil?

          directives[match[1].downcase.to_sym] = match[2]
        end
        [parts[0...index], directives]
      end

      # @raise [ControlPlane::Polls::Invalid] naming the first directive this
      #   command does not take
      def validate_directives!(directives, allowed)
        unknown = directives.keys - allowed
        return if unknown.empty?

        raise ControlPlane::Polls::Invalid, "#{unknown.first}= is not an option I take here."
      end

      # @return [Integer] the hours a duration=TOKEN directive names
      # @raise [ControlPlane::Polls::Invalid] when it names none of them
      def parse_duration_directive!(text)
        hours = Polls::Poll.duration_hours(text)
        return hours if hours

        raise ControlPlane::Polls::Invalid,
              "#{text.inspect} is not a duration I take (try one of #{Polls::Poll::DURATION_TOKENS.join(", ")})."
      end

      # --- shared helpers ---

      # nil when this message is not this command.
      def command_text(context)
        word, arguments = CommandWord.parse(context)
        return nil unless word == command_word

        arguments.join(" ")
      end

      def poll_for(ref)
        poll = @board.poll_for_card(ref)
        return nil if poll.nil? || poll.kind != poll_kind

        poll
      end

      # @return [Array(Models::Community, Models::Room), nil]
      def scope_for(context)
        community = @polls.community_by_id(context.community.id)
        room = community && @polls.room_for_endpoint_key(
          community: community, endpoint_key: context.channel&.endpoint_key
        )
        return [community, room] unless community.nil? || room.nil?

        logger.warn { "#{command_word}: could not resolve a room for #{context.message.origin.id}" }
        acknowledge(context, "This room isn't linked to a community yet, so /#{command_word} can't run here.")
        nil
      end

      def identity_for(author)
        return nil if author.nil?

        author.native_id || author.username
      end

      def handle_for(author)
        return nil if author.nil?

        author.username || author.nickname || author.display_name
      end

      def issuer_label(context)
        author = context.message.author
        return context.message.origin.adapter_name.to_s if author.nil?

        handle = handle_for(author) || author.native_id.to_s
        "#{context.message.origin.adapter_name}:#{handle}"
      end

      def config_value(config, key)
        return nil unless config.is_a?(Hash)

        config.key?(key) ? config[key] : config[key.to_s]
      end

      # The truthy spellings a room's YAML config or a per-poll override
      # (see PollCommand's reply_options= modifier) might use.
      TRUE_VALUES = [true, "true", "yes", "on", 1, "1"].freeze

      def truthy?(value)
        TRUE_VALUES.include?(value.is_a?(String) ? value.downcase : value)
      end

      def boolean_config(config, key, default:)
        value = config_value(config, key)
        return default if value.nil?

        truthy?(value)
      end

      # Never raises: a lost reply must not derail the pipeline.
      def acknowledge(context, text)
        delay = Core::CommandAck.ttl_seconds(context.config)
        group = @ephemeral.post(
          endpoints: [context.message.origin], body: Core::RichText.plain(text),
          name: NOTICE_NAME, delete_after: delay,
          also_delete: Core::CommandAck.pair_with(context.message, context.config),
          reply_to: Core::CommandAck.reply_to(context.message)
        )
        @cleanup.after(delay) { group.delete_now } if delay.positive? && @cleanup && group.any?
        group
      rescue StandardError => e
        logger.warn { "#{command_word}: could not post a reply: #{e.message}" }
        nil
      end
    end
  end
end
