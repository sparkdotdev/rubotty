# frozen_string_literal: true

module Rubotty
  module Core
    # Recognises moderation commands in ordinary messages and turns them into
    # {Moderation::Command} objects; a command message is never relayed, it is
    # swallowed at the router. Authorisation fails closed: an operator may issue
    # any action they're granted (router enforces per-room), anyone may
    # `/delete` their own message, and every other verb is operator only.
    # Recognition never depends on operator count, since an empty directory
    # must never fall back to relaying commands as plain chat; an unrecognised
    # verb comes back as a {Refusal} the caller answers.
    class Commands
      # Why a recognised command cannot run, carried out of the parser so the
      # caller can say it in the room the command was typed in.
      Refusal = Struct.new(:reason, :action, keyword_init: true) do
        def message
          case reason
          when :needs_reply
            "/#{action} has to be sent as a reply to the message it should act on."
          when :unavailable
            "Sorry, /#{action} is not available on this bridge."
          else
            "You need to be an operator to use this command."
          end
        end
      end

      # The default command markers, shared with every other command surface
      # through {CommandPrefix}.
      DEFAULT_PREFIXES = CommandPrefix::DEFAULT

      # Holds no operator directory of its own: who may act is settled per
      # message, by the directory {#parse} is handed, since a parser carrying
      # one would carry it for every tenant at once.
      #
      # @param prefixes [CommandPrefix, Array<String>, String] the markers a
      #   message may begin with; a bare String or Array is coerced
      # @param actions [Array<Symbol>] which actions are accepted at all
      # @param reposts [#deletable_by?, nil] see {#own_restoration?}
      def initialize(prefixes: DEFAULT_PREFIXES, enabled: true, actions: Moderation::TYPED_ACTIONS,
                     reposts: nil, logger: nil)
        @prefixes = CommandPrefix.from(prefixes)
        @enabled = enabled
        @actions = Array(actions).map(&:to_sym)
        @reposts = reposts
        @logger = logger
      end

      attr_reader :prefixes

      # Whether this parser reads commands at all. Deliberately independent of
      # how many operators are configured: who may act is settled per issuer,
      # and an unconfigured community still has to answer rather than relay.
      def enabled? = @enabled

      # @param directory [Moderation::Directory, nil] the operator directory to
      #   resolve the issuer in, always the message's own community's: a room key
      #   is unique only within one, so a grant read anywhere else carries into
      #   another tenant. Required, and nil is a real answer meaning no community
      #   resolved, which resolves nobody rather than widening.
      # @return [Moderation::Command, Refusal, nil] nil means "route normally";
      #   a {Refusal} means "this was a command and it cannot run here", which
      #   the caller consumes and answers.
      def parse(message, directory:)
        return nil unless @enabled
        return nil unless message.kind == :chat

        action, arguments = split(message.body.text)
        return nil if action.nil?
        # Recognised from here on, so every remaining exit refuses rather than relays.
        return Refusal.new(reason: :unavailable, action: action) unless @actions.include?(action)

        if message.reply_to.nil?
          # /delete alone among the verbs can name its target WITHOUT a reply:
          # by exact text, or bare, meaning the issuer's own last message. The
          # concrete target is resolved by the feature, which holds the buffer.
          return no_reply_delete(message, arguments, directory) if action == :delete
          # /unpin naming a room clears every pin in it, so there is nothing to
          # reply to. Bare it still means the message replied to, and so still
          # refuses below: only the named form has a target without one.
          return sweep_command(message, arguments, directory) if room_sweep?(action, arguments)

          if Moderation.message_action?(action) || Moderation.user_action?(action)
            # Every other message or user action identifies its target by reply.
            @logger&.debug { "#{action} issued without replying to a message" }
            return Refusal.new(reason: :needs_reply, action: action)
          end
        end

        # Identity is resolved here; the per room part of an operator's permission
        # is enforced by the router. The USERNAME is passed too, so the deployment-configured
        # owner floor matches on the stable handle, never the display name.
        operator = directory&.resolve(
          message.origin.adapter_name, message.author&.native_id, username: message.author&.username
        )
        operator = nil if operator && !operator.actions.is_a?(Symbol) &&
                          !operator.actions.include?(action)

        # An operator issues under their own authority; anyone else may only
        # delete their own message. A command with no operator issuer is therefore
        # always an authorised self delete, which the router grants unchecked.
        unless operator || self_delete?(action, message)
          @logger&.warn do
            "refused #{action} from #{message.author&.any_name} " \
              "(#{message.origin.adapter_name}:#{message.author&.native_id}) on #{message.origin.id}"
          end
          return Refusal.new(reason: :not_permitted, action: action)
        end

        Moderation::Command.new(
          action: action,
          issuer: operator,
          origin: message.origin,
          target_ref: message.reply_to,
          # The person to act on for a user action is the author of the message
          # being replied to, which adapters put on the reply preview.
          target_user: message.reply_preview&.author,
          # What that message said, taken from the excerpt the platform already
          # handed us, so an operator alert can quote what was acted on.
          target_text: message.reply_preview&.body&.text,
          arguments: arguments,
          source_ref: message.ref
        )
      end

      # Summarise what happened, for the acknowledgement in the immediate path.
      def summarise(command, results)
        return "#{command.action}: nothing to do" if results.empty?

        done = results.count(&:ok?)
        parts = results.reject(&:ok?).map(&:to_s)
        summary = "#{command.action}: #{done}/#{results.size} endpoints"
        parts.empty? ? summary : "#{summary} (#{parts.join("; ")})"
      end

      private

      # Whether this is /unpin naming a room rather than replying to a message.
      # The argument is what tells them apart: a verb that acts on a whole room
      # cannot also be the one that acts on the message you replied to.
      def room_sweep?(action, arguments)
        action == :unpin && !Array(arguments).join(" ").strip.empty?
      end

      # /unpin <room> is carried out as the separate action adapters actually
      # implement, unpinAllChatMessages on Telegram, rather than as a pin
      # removal with no message to remove. Operator only, like every sweep.
      def sweep_command(message, arguments, directory)
        operator = directory&.resolve(
          message.origin.adapter_name, message.author&.native_id, username: message.author&.username
        )
        granted = operator && (operator.actions.is_a?(Symbol) || operator.actions.include?(:unpinall))
        return Refusal.new(reason: :not_permitted, action: :unpin) unless granted

        Moderation::Command.new(
          action: :unpinall, issuer: operator, origin: message.origin,
          arguments: arguments, source_ref: message.ref
        )
      end

      # Build a reply-less /delete: with an argument, the target is a recent
      # message matching that text exactly; with none, the target is the
      # issuer's OWN last message. Authorisation is deferred to the feature,
      # since it depends on WHICH message the text matches; a non-operator is
      # carried through with their own id, and the feature still refuses a
      # text match on someone else's message.
      def no_reply_delete(message, arguments, directory)
        operator = directory&.resolve(
          message.origin.adapter_name, message.author&.native_id, username: message.author&.username
        )
        operator = nil if operator && !operator.actions.is_a?(Symbol) &&
                          !operator.actions.include?(:delete)
        text = arguments.join(" ").strip

        Moderation::Command.new(
          action: :delete,
          issuer: operator,
          origin: message.origin,
          target_ref: nil,
          arguments: arguments,
          source_ref: message.ref,
          targeting: text.empty? ? :own_last : :text,
          issuer_native_id: message.author&.native_id
        )
      end

      # The one gate letting somebody who is not an operator run a command, and
      # it opens for a single verb against a single message. Either the replied
      # message is their own, matched by platform id in the one id space both
      # sit in, or it is a restoration posted on their behalf. A relayed copy
      # is authored by the bot or a webhook and passes neither, which is the
      # fail-closed outcome replying to your own cross-posted copy has always
      # had.
      def self_delete?(action, message)
        return false unless action == :delete

        issuer = message.author&.native_id
        return false if issuer.nil?

        target = message.reply_preview&.author&.native_id
        return true if !target.nil? && issuer.to_s == target.to_s

        own_restoration?(message, issuer)
      end

      # A restored message is the bot's, so ownership is asked of the store that
      # recorded it rather than read off the message. Every part has to match:
      # the endpoint, since a native id means nothing outside one, the message
      # itself, and the member asking. No store means no.
      def own_restoration?(message, issuer)
        return false if @reposts.nil?

        ref = message.reply_to
        return false if ref.nil?

        @reposts.deletable_by?(
          endpoint_id: ref.endpoint_id, native_id: ref.native_id, author_native_id: issuer.to_s
        )
      rescue StandardError => e
        @logger&.warn { "commands: could not check a restoration: #{e.message}" }
        false
      end

      # @return [Array(Symbol, Array<String>), Array(nil, nil)]
      def split(text)
        # The prefix set is recognised in one shared place, so moderation honours
        # the same markers as every other command surface.
        body = @prefixes.strip(text)
        return [nil, nil] if body.nil?

        words = body.to_s.split(/\s+/)
        return [nil, nil] if words.empty?

        # Telegram appends the bot's own username to commands in groups, as in
        # "/delete@mybridgebot", so a command works either way it was typed.
        word = words.first.split("@").first.to_s.downcase
        return [nil, nil] if word.empty?

        action = word.to_sym
        return [nil, nil] unless Moderation.known?(action)

        [action, words[1..] || []]
      end
    end
  end
end
