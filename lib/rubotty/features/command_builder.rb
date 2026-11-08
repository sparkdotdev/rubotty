# frozen_string_literal: true

require "securerandom"

module Rubotty
  module Features
    # A command typed bare, with no arguments at all, is answered by asking for
    # one field at a time instead of printing its usage. The fields, their
    # order and the wording of every prompt come from {Core::CommandRegistry}
    # through {Core::CommandForm}, so one engine drives every command from
    # metadata that already exists. The exchange stays on the platform it was
    # typed on, and is removed once the command runs, somebody cancels, or
    # three minutes pass with no answer. A platform that cannot delete a
    # message is never offered a form, so no transcript is ever left behind.
    class CommandBuilder < Base
      include AdapterLookup

      NOTICE_NAME = "rubotty"

      # One name for the pending-operation kind and the feature itself.
      KIND = "command_builder"

      # How long an unanswered form waits, refreshed by every answer. Well
      # under {Core::PendingOperations::DEFAULT_TTL}: a question nobody is
      # answering should take its prompts away while the room still remembers
      # what they were about.
      TTL_SECONDS = 3 * 60

      # The commands offered a builder. A per-command list rather than every
      # buildable spec, because a field a command reads as its own little
      # language (`/poll`'s question and options, `/watch`'s instruction) wants
      # its prompt read before it is asked for. `/schedule`, `/reschedule` and
      # `/rsvp` have nothing of that shape: every field is already its own
      # named argument, so the registry's own metadata is enough.
      BUILDABLE = %w[event schedule reschedule rsvp].freeze

      # One form in progress: which command, how far along, the answers so far,
      # and every message the exchange has produced, so all of it can be taken
      # away together.
      class Flow
        def initialize(spec:)
          @spec = spec
          @index = 0
          @values = {}
          @groups = []
          @prompt_ids = []
          @finished = false
        end

        attr_reader :spec, :index, :values

        # The field being asked for, or nil once every one is answered.
        def argument = @spec.arguments[@index]

        def asking? = @index < @spec.arguments.length

        # Whether the answers so far are already a command: nothing required
        # is still to come, so the rest of the fields are an offer.
        def finishable? = @spec.arguments[@index..].to_a.none?(&:required?)

        def answered(value)
          @values[argument.name] = value
          @index += 1
        end

        def skipped = (@index += 1)

        # Remember a prompt: its copies are what the invoker's replies point
        # at, and what a finished form removes.
        def asked(group)
          @groups << group
          @prompt_ids.concat(group.native_ids.map(&:to_s))
        end

        def prompt?(native_id) = @prompt_ids.include?(native_id.to_s)

        # Take the whole exchange away at once. Every message is also under its
        # own timed deletion, so an abandoned form still clears itself.
        def finish
          @finished = true
          @groups.each(&:delete_now)
        end

        # One prompt's own timer, which does nothing once the form has already
        # removed everything.
        def sweep(group)
          group.delete_now unless @finished
        end
      end

      def self.feature_name = KIND

      def self.description = "Asks for a command's fields one at a time when it is typed bare, instead of printing usage."

      def self.default_enabled? = true

      # A command, and an answer to one, can only ride a chat message.
      def self.observes = %i[chat]

      # @param pending [Core::PendingOperations, nil] the open-form store; its
      #   own three-minute TTL rather than the shared fifteen-minute one
      # @param ephemeral [Core::EphemeralMessage, nil] posts and removes prompts
      # @param cleanup [Core::Scheduler, nil] fires a prompt's self-delete on time
      # @param run [#call, nil] takes the assembled command back through the
      #   pipeline, exactly as a native slash command is fed into it
      def initialize(topology:, adapters:, logger:, pending: nil, ephemeral: nil, cleanup: nil, run: nil)
        super()
        @adapters = adapters
        @logger = logger
        @cleanup = cleanup
        @run = run
        @pending = pending || Core::PendingOperations.new(ttl: TTL_SECONDS, logger: logger)
        @ephemeral = ephemeral || Core::EphemeralMessage.new(
          adapters: adapters, topology: topology, session_id: SecureRandom.uuid, logger: logger
        )
      end

      attr_reader :logger, :pending

      def call(context)
        return Outcome.continue([]) if actor_of(context).nil?

        word, arguments = CommandWord.parse(context)
        return start(context, word) if bare_invocation?(context, word, arguments)

        operation = @pending.peek(**key(context))
        return Outcome.continue([]) if operation.nil?

        answer(context, operation.payload, word)
      end

      private

      # A command word this feature offers a form for, said with nothing after
      # it. Everything a form needs is checked here, so a refusal falls through
      # to the command's own usage rather than swallowing the invocation.
      def bare_invocation?(context, word, arguments)
        return false if word.nil? || !Array(arguments).empty?

        spec = Core::CommandRegistry.find(word)
        return false unless BUILDABLE.include?(spec&.name)
        return false unless Core::CommandForm.buildable?(spec)

        offered?(context, spec)
      end

      # Whether this room can hold a form at all: a resolved community, a real
      # typed invocation, the command's own feature switched on here, and a
      # platform that can take the exchange away again afterwards.
      def offered?(context, spec)
        return false if context.community.nil? || context.message.synthetic?
        return false if spec.feature && !context.community.feature_enabled?(context.channel, spec.feature)

        deletes?(context)
      end

      # The gate, asked of the adapter rather than of a list of platform names:
      # one that gains deletion later gets builders with no further change
      # here, and one that cannot delete keeps the usage line it prints today.
      def deletes?(context)
        capabilities_of(context)&.deletes? ? true : false
      end

      def start(context, word)
        replaced = @pending.peek(**key(context))
        replaced.payload.finish if replaced
        flow = Flow.new(spec: Core::CommandRegistry.find(word))
        @pending.open(kind: KIND, payload: flow, **key(context))
        group = ask(context, flow, pair: Core::CommandAck.pair_with(context.message, context.config))
        return give_up(context) if group.nil? || !group.any?

        Outcome.halt([])
      end

      # Nothing could be asked, so the form never happened and the command's
      # own feature still sees the invocation.
      def give_up(context)
        @pending.forget(**key(context))
        Outcome.continue([])
      end

      # One message read as an answer to the open form. A reply pointing
      # somewhere other than a prompt, another command word, and anything with
      # no text to read at all are ordinary chat, and are left alone.
      def answer(context, flow, word)
        return Outcome.continue([]) unless attributable?(context, flow)
        return Outcome.continue([]) if word && Core::CommandRegistry.known?(word)

        text = context.message.body.text.to_s.strip
        # A photo posted while a form is open is still a photo: every field a
        # command declares is typed, so nothing wordless can be answering one.
        return Outcome.continue([]) if text.empty?

        case Core::CommandForm.control(text, context.command_prefixes)
        when :cancel then cancel(context, flow)
        when :done then finish_early(context, flow)
        when :skip then skip(context, flow)
        else record(context, flow, text)
        end
      end

      # An answer belongs to the form when it is not a reply to somebody else:
      # a reply naming one of the prompts is unambiguous, and where a platform
      # has no replies at all the open form and the plain message are the rule.
      def attributable?(context, flow)
        ref = context.message.reply_to
        ref.nil? || ref.native_id.to_s.empty? || flow.prompt?(ref.native_id)
      end

      def skip(context, flow)
        return reask(context, flow, "That field is required.") if flow.argument.required?

        flow.skipped
        advance(context, flow)
      end

      # Run what has been answered and leave the remaining optional fields at
      # whatever the command itself defaults them to.
      def finish_early(context, flow)
        return reask(context, flow, "That field is required.") unless flow.finishable?

        complete(context, flow)
      end

      def record(context, flow, text)
        argument = flow.argument
        complaint = Core::CommandForm.complaint(argument, text)
        return reask(context, flow, complaint) if complaint

        flow.answered(Core::CommandForm.normalise(argument, text))
        advance(context, flow)
      end

      # Ask the same field again, keeping every answer already given: losing a
      # filled-in form to one refused value is worse than the usage line this
      # replaces.
      def reask(context, flow, complaint)
        ask_again(context, flow, note: complaint)
      end

      # On to the next field, or run what the answers add up to. Reopening the
      # pending operation is what makes the three minutes run from the last
      # answer rather than from the invocation.
      def advance(context, flow)
        return complete(context, flow) unless flow.asking?

        ask_again(context, flow)
      end

      # The next question, and the refreshed window to answer it in. A prompt
      # that could not be posted closes the form rather than leaving it open
      # and invisible, quietly reading the room's next line as an answer.
      def ask_again(context, flow, note: nil)
        @pending.open(kind: KIND, payload: flow, **key(context))
        return cancel(context, flow) if ask(context, flow, pair: [context.message.ref], note: note).nil?

        Outcome.halt([])
      end

      # The finished form: the exchange goes first so the room sees it clear,
      # then the command runs as though the whole line had been typed at once.
      def complete(context, flow)
        @pending.forget(**key(context))
        line = Core::CommandForm.command_line(flow.spec, flow.values, marker: marker(context))
        close(context, flow)
        run(context, line)
        Outcome.halt([])
      end

      def cancel(context, flow)
        @pending.forget(**key(context))
        close(context, flow)
        Outcome.halt([])
      end

      # Remove the prompts, the answers linked to them, and the message that
      # ended the form, which belongs to no prompt of its own.
      def close(context, flow)
        flow.finish
        native_id = context.message.ref&.native_id
        @ephemeral.delete_one(endpoint: context.message.origin, native_id: native_id) unless native_id.to_s.empty?
      rescue StandardError => e
        logger.warn { "command builder: could not clear the exchange: #{e.class}: #{e.message}" }
      end

      # Post one prompt, pairing the messages it answers so they are removed
      # together, on the platform the command was typed on and nowhere else.
      def ask(context, flow, pair: [], note: nil)
        group = @ephemeral.post(
          endpoints: [context.message.origin], body: Core::RichText.plain(text_of(context, flow, note)),
          name: NOTICE_NAME, delete_after: TTL_SECONDS, also_delete: Array(pair).compact,
          reply_to: reply_target(context)
        )
        flow.asked(group)
        @cleanup.after(TTL_SECONDS) { flow.sweep(group) } if @cleanup && group.any?
        group
      rescue StandardError => e
        logger.warn { "command builder: could not ask for #{flow.argument&.name}: #{e.message}" }
        nil
      end

      def text_of(context, flow, note)
        prompt = Core::CommandForm.prompt(
          flow.spec, flow.index, marker: marker(context), addressee: addressee(context),
          finishable: flow.finishable?
        )
        note ? "#{note} #{prompt}" : prompt
      end

      # Feed the assembled line back in as a message nobody posted, which is
      # exactly what a native slash command already is, so the bridge and the
      # background readers leave it alone and the command answers as usual.
      def run(context, line)
        return if @run.nil?

        @run.call(
          Core::Message.new(
            kind: :chat, ref: Core::MessageRef.new(context.message.origin.id, "builder-#{SecureRandom.hex(4)}"),
            origin: context.message.origin, author: context.message.author,
            body: Core::RichText.plain(line), timestamp: Time.now, synthetic: true
          )
        )
      rescue StandardError => e
        logger.error { "command builder: could not run #{line}: #{e.class}: #{e.message}" }
      end

      # The prompt hangs off the invoker's own message where the platform has
      # replies, so two people building at once in one room can tell whose
      # question is whose.
      def reply_target(context)
        return nil unless capabilities_of(context)&.replies?

        Core::CommandAck.reply_to(context.message)
      end

      # The name a prompt opens with where there are no replies to hang it off,
      # and nothing at all where there are.
      def addressee(context)
        return nil if capabilities_of(context)&.replies?

        author = context.message.author
        author&.username || author&.any_name
      end

      # The marker to print and to write the assembled line with: the room's
      # own, minus any the platform's client swallows before the bot sees it.
      def marker(context)
        context.command_prefixes.preferred(capabilities: capabilities_of(context))
      end

      def capabilities_of(context)
        adapter = adapter_for(context.message.origin)
        adapter&.capabilities_for(context.message.origin)
      rescue StandardError => e
        logger.warn { "command builder: could not read #{context.message.origin.id}'s capabilities: #{e.message}" }
        nil
      end

      def actor_of(context) = presence(context.message.author&.native_id)

      def key(context)
        {
          community_id: context.community&.id, endpoint_id: context.message.origin.id,
          actor_id: actor_of(context)
        }
      end

      def presence(value)
        text = value.to_s.strip
        text.empty? ? nil : text
      end
    end
  end
end
