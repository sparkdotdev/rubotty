# frozen_string_literal: true

require "securerandom"

module Rubotty
  module Features
    # Warnings and the escalation ladder, via three commands issued as a reply
    # to the subject's message: `/warn [reason] [delete=true]` records a
    # strike, DMs the subject and runs the ladder, `/warnings` lists active
    # strikes, `/unwarn [all]` clears the most recent strike or all of them.
    # Each is operator-gated and never relayed; an unrecognised sender is met
    # with silence, per the fail-closed rule.
    class Warnings < Base
      include AdapterLookup

      # The command words this feature owns.
      WARN = :warn
      LIST = :warnings
      UNWARN = :unwarn
      COMMANDS = [WARN, LIST, UNWARN].freeze

      # The sender label the acknowledgement is posted under.
      NOTICE_NAME = "warnings"

      # A trailing "delete=<bool>" token on /warn, matched only against the
      # LAST argument so a reason merely containing the phrase is untouched.
      DELETE_FLAG = /\Adelete=(true|false|1|0|yes|no)\z/i
      TRUTHY_DELETE_VALUES = %w[true 1 yes].freeze

      # A stand-in for the replied-to message: {Watchdog::Removal} only reads
      # `.origin` and `.ref`, and a reply carries no live `.origin` of its own.
      ReplyTarget = Struct.new(:origin, :ref)

      def self.feature_name = "warnings"

      def self.description = "Tracks warnings per member with an escalating ladder of consequences."

      def self.default_enabled? = false

      # A command can only ride a chat message, so this observes only :chat.
      def self.observes = %i[chat]

      # The per-scope config shape. Each ladder rung is a typed mapping, so a
      # misspelled entry is refused before the runtime has to ignore it.
      def self.config_schema
        Config::Schema.define do
          field :ladder, :array, of: Config::Schema.define {
            field :threshold, :integer, required: true,
                              desc: "warning count that applies this action" do |value, path|
              "#{path}: must be positive" unless value.positive?
            end
            field :action, :string, required: true, one_of: Core::Warnings::SANCTION_ACTIONS.map(&:to_s),
                            desc: "mute, ban, or kick"
            field :duration, :duration,
                             desc: "optional duration for a mute or ban; leave blank for permanent"
          }, default: []
          field :max, :integer, default: 0,
                desc: "the highest warning level, printed as \"N of max\" in the DM and the ack; " \
                      "0 leaves it unprinted"
          field :expires_after, :duration,
                desc: "how long before a warning lapses and the level drops by one, DMing the member " \
                      "about the decrease, e.g. \"30d\" (a bare number is seconds); unset means " \
                      "warnings never expire"
          field Core::CommandAck::TTL_FIELD, :integer, default: Core::CommandAck::DEFAULT_TTL_SECONDS,
                desc: "seconds a warnings reply lives before it self-deletes. 0 leaves it in place."
          field Core::CommandAck::DELETE_COMMAND_FIELD, :boolean,
                default: Core::CommandAck::DELETE_COMMAND_DEFAULT,
                desc: "whether the invocation itself is removed together with its reply"
        end
      end

      # @param service [Core::Warnings::Service] the shared warnings coordinator
      # @param storage the message map, so `delete=true` can remove the
      #   replied-to message everywhere it has already been relayed; nil skips
      #   deletion entirely
      # @param ephemeral [Core::EphemeralMessage, nil] posts the ack
      # @param cleanup [Core::Scheduler, nil] fires the ack's self-delete on time
      def initialize(topology:, adapters:, logger:, service:, storage: nil,
                     ephemeral: nil, cleanup: nil, announcements: nil)
        super()
        @adapters = adapters
        @announcements = announcements
        @logger = logger
        @service = service
        @cleanup = cleanup
        @ephemeral = ephemeral || Core::EphemeralMessage.new(
          adapters: adapters, topology: topology, session_id: SecureRandom.uuid, logger: logger
        )
        @removal = storage && Watchdog::Removal.new(
          topology: topology, adapters: adapters, storage: storage, logger: logger, source: "warnings"
        )
      end

      attr_reader :logger

      def call(context)
        message = context.message
        action, arguments = split_command(message.body.text, prefixes_for(context))
        # Not one of ours: leave it for the bridge and the rest of the chain.
        return Outcome.continue([]) if action.nil?

        # From here it is a warnings command, so it is never relayed, and the
        # invocation goes at once rather than on the acknowledgement window.
        # Before the operator gate too: a refused attempt names its operator
        # just as plainly as an accepted one.
        remove_command(message.origin, message.ref)

        subject = message.reply_preview&.author
        if subject.nil? || subject.native_id.nil?
          logger.debug { "warnings: #{action} needs a reply to the target user" }
          acknowledge(context, "/#{action} only works as a reply to the message of the person you mean.")
          return Outcome.halt([])
        end

        operator = resolve_operator(context)
        if operator.nil?
          logger.warn do
            "warnings: refused #{action} from #{message.author&.any_name} " \
              "(#{message.origin.adapter_name}:#{message.author&.native_id})"
          end
          acknowledge(context, "You don't have permission to use that command: it needs operator standing.")
          return Outcome.halt([])
        end

        dispatch(context, action, arguments, subject, operator)
        Outcome.halt([])
      end

      private

      def dispatch(context, action, arguments, subject, operator)
        case action
        when WARN then handle_warn(context, arguments, subject, operator)
        when LIST then handle_list(context, subject)
        when UNWARN then handle_unwarn(context, arguments, subject)
        end
      rescue StandardError => e
        logger.warn { "warnings: #{action} failed: #{e.class}: #{e.message}" }
      end

      def handle_warn(context, arguments, subject, operator)
        ladder = Core::Warnings::Ladder.parse(context.config, logger: logger)
        delete_message, arguments = extract_delete_flag(arguments)
        reason = arguments.join(" ").strip
        reason = nil if reason.empty?

        outcome = @service.warn(
          community: context.community, subject: subject, origin: context.message.origin,
          ladder: ladder, max: max_level(context.config), expire_after: expire_after(context.config),
          reason: reason, issued_by: operator.to_s
        )
        return acknowledge(context, "Warnings are unavailable here.") if outcome.nil?

        text = warn_ack(subject, outcome)
        text = "#{text} #{delete_target_message(context)}" if delete_message
        acknowledge(context, text)
        notify_publicly(context, subject, outcome) unless outcome.dm_sent
      end

      # A DM the subject cannot receive still has to reach them somehow, so
      # this pings them in the room instead, with a real per-platform mention
      # where their origin-platform id is known. Left up rather than
      # self-deleted like the operator's ack (see {#acknowledge}): the point
      # is for the subject to see it whenever they next read the room, not
      # for it to still be there only if they are watching right now.
      def notify_publicly(context, subject, outcome)
        group = @ephemeral.post(
          endpoints: [context.message.origin],
          body: mention_notice(subject, context.message.origin, outcome),
          name: NOTICE_NAME,
          delete_after: 0
        )
        pair_with_warned_message(context, outcome, group)
      rescue StandardError => e
        logger.warn { "warnings: could not post the public DM-failure notice: #{e.message}" }
      end

      # Remember which message this notice was about, so an operator removing
      # that message through the bot takes the notice with it rather than
      # leaving it standing over a blank space. Only a warning issued by reply
      # names a message at all, and one that names none is simply not paired.
      def pair_with_warned_message(context, outcome, group)
        return if @announcements.nil? || group.nil?

        target = context.message.reply_preview&.ref
        return if target.nil?

        community_id = context.community.respond_to?(:id) ? context.community.id : nil
        return if community_id.nil?

        group.copies.each do |copy|
          @announcements.record(
            community_id: community_id, adapter: context.message.origin.adapter_name,
            endpoint_id: target.endpoint_id, native_id: target.native_id,
            notice_endpoint_id: copy.endpoint.id, notice_native_id: copy.native_id,
            expires_at: notice_expiry(context, outcome)
          )
        end
      rescue StandardError => e
        logger.warn { "warnings: could not pair the notice with its message: #{e.message}" }
      end

      # A notice is worth retracting for exactly as long as the warning it is
      # about stands. Nil where nothing decays, which the store reads as its
      # own ceiling rather than as forever.
      def notice_expiry(context, outcome)
        issued = outcome.warning.respond_to?(:issued_at) ? outcome.warning.issued_at : nil
        after = expire_after(context.config)
        return nil if issued.nil? || !after.to_i.positive?

        issued + after
      end

      def mention_notice(subject, origin, outcome)
        name = subject&.any_name.to_s
        name = "someone" if name.strip.empty?
        # The DM's own words, so somebody with DMs closed is told why they were
        # warned and what the next one costs rather than only that something
        # happened. Composed once in Core::Warnings and carried here, so the two
        # routes cannot say different things about one warning.
        details = outcome.respond_to?(:text) ? outcome.text.to_s.strip : ""
        text = [
          "#{name}, you have been warned.",
          (details.empty? ? "You have a new warning (#{outcome.count}#{level_suffix(outcome.max)})." : details),
          (penalty_sentence(outcome.sanction) if details.empty?),
          "Could not reach you by DM, so this is here instead."
        ].compact.join(" ")
        native_id = subject&.native_id
        return Core::RichText.plain(text) if native_id.nil? || origin.nil?

        key = :"#{origin.adapter_name}_id_for_target"
        span = Core::Span.new(kind: :mention, begin_index: 0, end_index: name.length, attributes: { key => native_id })
        Core::RichText.new(text, [span])
      end

      # The listing names the operator behind every strike, so it is answered
      # to the operator who asked and nowhere else: posting it in the room told
      # the member which operator to hold each warning against, for as long as
      # the acknowledgement window ran (#1913).
      #
      # A refusal is not sensitive and stays in the room, so somebody who typed
      # it without standing still hears why.
      def answer_privately(context, text)
        acknowledge(context, UNREACHABLE) unless dm_operator(context, text)
      end

      def dm_operator(context, text)
        adapter = adapter_for(context.message.origin)
        return false unless adapter.respond_to?(:supports_admin_dm?) && adapter.supports_admin_dm?

        !!adapter.send_admin_dm(context.message.author&.native_id, text)
      rescue StandardError => e
        logger.warn { "warnings: could not DM the listing: #{e.message}" }
        false
      end

      # Says nothing about who or what, since the room is the one place this
      # answer must not appear. An operator the bot cannot open a chat with is
      # told to open one rather than left with silence.
      UNREACHABLE = "I could not message you privately. Open a chat with me and run that again."

      def handle_list(context, subject)
        warnings = @service.list(
          community: context.community, subject: subject,
          adapter: context.message.origin.adapter_name
        )
        answer_privately(context, list_ack(subject, warnings))
      end

      def handle_unwarn(context, arguments, subject)
        scope = arguments.map(&:downcase).include?("all") ? :all : :latest
        removed = @service.clear(
          community: context.community, subject: subject,
          adapter: context.message.origin.adapter_name, scope: scope
        )
        acknowledge(context, unwarn_ack(subject, removed, scope))
      end

      # Pulls a trailing `delete=<bool>` token off +arguments+, so
      # `!warn being rude delete=true` both warns and removes the message
      # being replied to. Only the LAST token is checked, and only an exact
      # match strips it, so a reason ending in "...delete=true" as a word in a
      # sentence, or carrying an "=" of its own, reads as plain text.
      def extract_delete_flag(arguments)
        match = arguments.last&.match(DELETE_FLAG)
        return [false, arguments] if match.nil?

        [TRUTHY_DELETE_VALUES.include?(match[1].downcase), arguments[0..-2]]
      end

      # Deletes the replied-to message everywhere it has already been relayed,
      # through the same cross-platform path `/delete` and the word filter
      # use, since by the time it is warned it may exist on several platforms
      # at once. The failure is reported back to the operator rather than
      # swallowed, the same rule a failed DM already follows.
      def delete_target_message(context)
        return "Could not delete their message (deletion is unavailable here)." if @removal.nil?

        target_ref = context.message.reply_preview&.ref
        return "Could not delete their message (it names no message to remove)." if target_ref.nil?

        removed = @removal.remove_everywhere(ReplyTarget.new(context.message.origin, target_ref))
        removed.empty? ? "Could not delete their message." : "Deleted their message."
      end

      def warn_ack(subject, outcome)
        head = "Warned #{name_of(subject)} (#{outcome.count}#{level_suffix(outcome.max)} active)."
        head = "#{head} Could not DM them." unless outcome.dm_sent
        return head unless outcome.escalated?

        sanction_ack(head, outcome.sanction)
      end

      def sanction_ack(head, sanction)
        return "#{head} #{sanction_verb(sanction.action)} from the community." if sanction.action == :kick
        unless sanction.applied?
          return "#{head} Ladder reached #{sanction.action} but no connected platform could carry it out."
        end

        penalty = sanction.duration ? "for #{Core::Warnings.human_duration(sanction.duration)}" : "permanently"
        plural = sanction.endpoints.size == 1 ? "endpoint" : "endpoints"
        "#{head} #{sanction_verb(sanction.action)} #{penalty} on #{sanction.endpoints.size} connected #{plural}."
      end

      def sanction_verb(action)
        case action
        when :ban then "Banned"
        when :kick then "Removed"
        else "Muted"
        end
      end

      # What the warning cost, for the room the notice lands in. Read off the
      # persisted row rather than the endpoints a platform accepted: Telegram
      # refuses to restrict an admin, but the mute is still recorded and
      # {Core::Warnings::Service#suppress?} enforces it by dropping what they
      # say, so a platform saying no is not the sanction failing to bite.
      def penalty_sentence(sanction)
        return nil if sanction.nil? || sanction.record.nil?

        "They have been #{Core::Warnings.penalty_phrase(sanction.action, sanction.duration)}."
      end

      def level_suffix(max)
        max&.positive? ? " of #{max}" : ""
      end

      def list_ack(subject, warnings)
        return "#{name_of(subject)} has no active warnings." if warnings.empty?

        lines = warnings.each_with_index.map do |warning, index|
          reason = warning.reason.nil? || warning.reason.to_s.strip.empty? ? "no reason given" : warning.reason
          "#{index + 1}. #{reason} (by #{warning.issued_by || "unknown"})"
        end
        "#{name_of(subject)} has #{warnings.size} active warning(s):\n#{lines.join("\n")}"
      end

      def unwarn_ack(subject, removed, scope)
        return "#{name_of(subject)} had no active warnings to clear." if removed.zero?

        if scope == :all
          "Cleared #{removed} warning(s) for #{name_of(subject)}."
        else
          "Removed the most recent warning for #{name_of(subject)}."
        end
      end

      # Posted loose rather than as a reply: remove_command has already taken
      # the invocation, and a platform asked to reply to a message that is gone
      # can refuse the send outright and lose the acknowledgement with it.
      #
      # Self-deleting acknowledgement posted to the issuer's endpoint as the bot,
      # taking the invocation with it on the shared terms every command uses.
      # Never raises: a lost ack must not derail command handling.
      def acknowledge(context, text)
        delay = Core::CommandAck.ttl_seconds(context.config)
        group = @ephemeral.post(
          endpoints: [context.message.origin],
          body: Core::RichText.plain(text),
          name: NOTICE_NAME,
          delete_after: delay
        )
        @cleanup.after(delay) { group.delete_now } if delay.positive? && @cleanup && group.any?
        group
      rescue StandardError => e
        logger.warn { "warnings: could not post the acknowledgement: #{e.message}" }
        nil
      end

      # A warning must not tell the room who issued it, and the invocation is
      # the one part of the exchange carrying the operator's own name. Removed
      # outright the moment the word is recognised rather than paired with the
      # acknowledgement: thirty seconds is long enough for the member being
      # warned to read who did it and hold it against them (#1912). Not gated
      # on CommandAck.delete_command? either, since no other invocation a room
      # may want left standing names an operator acting against a member.
      def remove_command(origin, ref)
        return if ref&.native_id.nil?

        adapter = adapter_for(origin)
        adapter&.delete(origin, ref.native_id)
      rescue StandardError => e
        logger.warn { "warnings: could not remove the invocation in #{origin.id}: #{e.message}" }
      end

      # Resolve the issuer to an operator, or nil to refuse. Fails closed: an
      # unknown sender resolves to nil.
      def resolve_operator(context)
        # This community's own directory and nothing else. A room key is unique
        # only within one, so an unresolved community denies rather than widening
        # to the merged deployment-wide view. Empty is still not short-circuited:
        # the deployment-configured owner floor is invisible to Directory#empty?.
        directory = context.operators
        return nil if directory.nil?

        author = context.message.author
        return nil if author.nil? || author.native_id.nil?

        # The username is passed so the deployment-configured owner floor is honoured here too,
        # matching on the stable handle instead of a DB row.
        directory.resolve(context.message.origin.adapter_name, author.native_id, username: author.username)
      end

      # Split a message into a warnings command and its arguments, or [nil, nil]
      # when it is not one of ours. Tolerates Telegram's "/warn@thebot" suffix.
      def split_command(text, prefixes)
        body = prefixes.strip(text)
        return [nil, nil] if body.nil?

        words = body.to_s.split(/\s+/)
        return [nil, nil] if words.empty?

        word = words.first.split("@").first.to_s.downcase
        return [nil, nil] if word.empty?

        action = word.to_sym
        return [nil, nil] unless COMMANDS.include?(action)

        [action, words[1..] || []]
      end

      def name_of(subject)
        subject.respond_to?(:any_name) ? subject.any_name : subject.to_s
      end

      def prefixes_for(context)
        context.command_prefixes
      end

      def max_level(config)
        value = config_value(config, :max)
        value.nil? ? nil : value.to_i
      end

      def expire_after(config)
        Core::Warnings.duration_seconds(config_value(config, :expires_after))
      end

      # Read one key from the resolved config, tolerating symbol or string keys.
      def config_value(config, key)
        return nil unless config.is_a?(Hash)

        config.key?(key) ? config[key] : config[key.to_s]
      end
    end
  end
end
