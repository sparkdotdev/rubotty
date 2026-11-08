# frozen_string_literal: true

module Rubotty
  module Features
    # Configurable, model-backed content policy filtering. An operator writes
    # any number of named policies in plain language; a background check
    # against ::Rubotty::ContentPolicy::Service decides whether a message
    # matches any of them and, on a match, deletes it, warns and deletes it,
    # or flags it and DMs the community's operators, per that policy's own
    # configured action. Off by default: this is real moderation power
    # exercised on a classifier's decision, so a community adopts it deliberately
    # rather than inheriting it silently.
    class ContentPolicy < Base
      include AdapterLookup

      def self.feature_name = ::Rubotty::ContentPolicy::Service::FEATURE

      def self.description = "Checks messages against operator-written content policies and deletes, " \
                              "warns and deletes, flags and notifies operators, or just notifies " \
                              "operators, per policy."

      def self.retention_notice = "Message text, the author's name, and a short run of the room's " \
                                   "preceding messages are kept in the pending policy-check job until " \
                                   "it runs. A message this feature acts on is then kept for the " \
                                   "restore window below, so an operator who disagrees can undo it. " \
                                   "Reversing an action keeps that text longer still, without the " \
                                   "author, as a sample the policy's own wording gets rewritten " \
                                   "against; the misfire window below is how long."

      # Where the misfire window is stored, named here rather than on the store
      # so the schema and the reader agree on one string.
      # A symbol for the same reason WINDOW_FIELD is: a string never matched the
      # symbolized config, so the misfire log kept its default ninety days
      # whatever a community asked for.
      MISFIRE_WINDOW_FIELD = :misfire_retention_days

      def self.default_enabled? = false

      # Runs on a fresh chat and on an edit, the same as the word filter: an
      # edit can smuggle in what the original message did not carry.
      def self.observes = %i[chat edit]

      def self.config_schema
        Config::Schema.define do
          field :entries, :array, default: [],
                desc: "the content policies checked against each message here, empty until an operator " \
                      "adds one by hand or picks from the built-in preset bank in the dashboard",
                of: Config::Schema.define {
                  field :name, :string, required: true,
                        desc: "short label shown in logs and operator alerts"
                  field :description, :string, required: true, multiline: true,
                        desc: "free text describing what to flag; sent to the model as the " \
                              "classification criterion"
                  field :mode, :string, one_of: ::Rubotty::ContentPolicy::Service::MODES,
                        default: ::Rubotty::ContentPolicy::Service::MODE_FORBIDS,
                        desc: "forbids (the default: flag a message that does what the description " \
                              "covers) or requires (flag a message the description applies to that does " \
                              "NOT do it). Told to the check rather than read out of the wording, since a " \
                              "description saying plainly that the omission is the match still had every " \
                              "message on the topic flagged instead"
                  field :action, :string, required: true, one_of: ::Rubotty::ContentPolicy::Service::ACTIONS,
                        desc: "notify (DM operators only, no reaction and the message left alone), " \
                              "flag_notify (react, post a temporary room notice and DM operators), " \
                              "warn_and_delete (post a self-deleting warning naming the policy, then " \
                              "remove), or delete (remove with no trace)"
                }
          field :exempt_operators, :boolean, default: true,
                desc: "never check this community's operators' own messages, the same carve-out every " \
                      "other moderation feature makes; false subjects them like anyone else"
          field :minimum_confidence, :float, range: 0.0..1.0, step: 0.05,
                default: ::Rubotty::ContentPolicy::Service::DEFAULT_MINIMUM_CONFIDENCE,
                desc: "how sure the check has to be, from 0 to 1, before a match is acted on here. " \
                      "Raise it in a room getting flags an operator disagrees with; a match returned " \
                      "with no number of its own is acted on whatever this says."
          field Core::RemovalNotice::TTL_FIELD, :integer, default: Core::RemovalNotice::DEFAULT_TTL_SECONDS,
                desc: "seconds a warn_and_delete warning lives before it self-deletes"
          field ::Rubotty::ContentPolicy::Service::WINDOW_FIELD, :integer,
                default: ControlPlane::ContentPolicyActions::DEFAULT_WINDOW_DAYS,
                desc: "days an operator has to reverse an action here with /vindicate, and so how long " \
                      "the text of a removed message is kept in order to restore it. Capped at " \
                      "#{ControlPlane::ContentPolicyActions::MAX_WINDOW_DAYS} days; a larger number is " \
                      "read as the cap." do |value|
                  "must be a positive number of days" unless value.to_i.positive?
                end
          field MISFIRE_WINDOW_FIELD, :integer,
                default: ControlPlane::ContentPolicyMisfires::DEFAULT_WINDOW_DAYS,
                desc: "days a reversed action is kept in the misfire log, where the text a policy " \
                      "wrongly matched sits with the reasoning behind it so the wording can be " \
                      "improved. Capped at " \
                      "#{ControlPlane::ContentPolicyMisfires::MAX_WINDOW_DAYS} days; a larger number " \
                      "is read as the cap." do |value|
                  "must be a positive number of days" unless value.to_i.positive?
                end
        end
      end

      # The verb an operator names a miss with, in reply to the message the
      # policies should have caught. The correlate of /vindicate, which answers
      # a code in a DM; a miss has no code, because nothing fired.
      CONDEMN = :condemn
      COMMANDS = [CONDEMN].freeze

      # The sender label the acknowledgement is posted under.
      NOTICE_NAME = "content_policy"

      # A trailing "warn=<bool>" token, matched only against the LAST argument
      # so a stated reason merely containing the phrase stays text. True unless
      # it says otherwise: an operator condemning a message is telling the bot
      # it broke a policy, and a strike is what that means on the ladder.
      WARN_FLAG = /\Awarn=(true|false|1|0|yes|no)\z/i
      FALSEY_WARN_VALUES = %w[false 0 no].freeze

      def self.command_words = COMMANDS.map(&:to_s)

      # @param adapters [Hash, nil] how the condemn invocation is removed; the
      #   verb still works without them, it just cannot take the command away.
      def initialize(logger:, service: nil, ephemeral: nil, cleanup: nil, adapters: {})
        @logger = logger
        @service = service
        @ephemeral = ephemeral
        @cleanup = cleanup
        @adapters = adapters || {}
      end

      attr_reader :logger

      def call(context)
        if condemn?(context)
          # Gone at once rather than on the acknowledgement window, and ahead
          # of the operator gate: it names the operator condemning a member's
          # message, and a refused attempt names one as plainly (#1912).
          remove_command(context.message.origin, context.message.ref)
          return condemn(context)
        end

        @service&.enqueue(context)
        Outcome.continue([])
      rescue StandardError => e
        logger.warn { "content policy: could not queue a check: #{e.class}: #{e.message}" }
        Outcome.continue([])
      end

      private

      def remove_command(origin, ref)
        return if ref&.native_id.nil?

        adapter = adapter_for(origin)
        adapter&.delete(origin, ref.native_id)
      rescue StandardError => e
        logger.warn { "content policy: could not remove the invocation in #{origin.id}: #{e.message}" }
      end

      def condemn?(context)
        message = context.message
        return false if message.nil? || message.author&.bot?

        word = context.command_prefixes.strip(message.body.text.to_s)
        !word.nil? && word.split(/\s+/).first.to_s.downcase.delete_prefix("/") == CONDEMN.to_s
      end

      # Operator gated and reply targeted, the same shape /warn takes. Halts
      # either way: the invocation is a command and is never relayed onward.
      def condemn(context)
        message = context.message
        target = message.reply_preview
        if target&.ref.nil?
          return answer(context, "/condemn only works as a reply to the message you mean.")
        end
        return answer(context, "That command needs operator standing.") unless operator?(context)

        run_condemn(context, target)
      end

      def run_condemn(context, target)
        return answer(context, "Content policy is not available here.") if @service.nil?

        _word, *rest = context.command_prefixes.strip(context.message.body.text.to_s).to_s.split(/\s+/)
        warn_author, rest = extract_warn_flag(rest)
        policy, statement = split_policy(rest.join(" "), context)
        outcome = @service.condemn(
          community: context.community, endpoint: context.message.origin,
          message: condemned_message(context, target), operator: operator_label(context),
          policy: policy, statement: statement, warn: warn_author
        )
        answer(context, condemn_reply(outcome))
      end

      # The flag comes off the argument list before anything else reads it, so
      # the words left over are the reason and nothing else. Only the last one
      # is tested, and the match strips it, so a reason ending in the phrase as
      # ordinary words is left where it is.
      def extract_warn_flag(arguments)
        match = arguments.last&.match(WARN_FLAG)
        return [true, arguments] if match.nil?

        [!FALSEY_WARN_VALUES.include?(match[1].downcase), arguments[0..-2]]
      end

      # A policy name in quotes, so a name with spaces in it is not read as the
      # first word plus a reason. Without quotes the whole of it is the reason
      # and the community's first policy stands in, which is what a community
      # running one policy wants to type.
      def split_policy(rest, _context)
        quoted = rest.match(/\A"([^"]+)"\s*(.*)\z/m)
        return [quoted[1], quoted[2]] if quoted

        [nil, rest]
      end

      # The replied-to message, as the service reads one: it only ever wants the
      # ref, the body and the author, all of which the reply preview carries.
      CondemnedMessage = Struct.new(:ref, :body, :author, keyword_init: true)

      def condemned_message(context, target)
        CondemnedMessage.new(ref: target.ref, body: target.body, author: target.author)
      end

      # This community's own directory and nothing else, the same rule every
      # other operator verb here follows: a room key is unique only within one.
      def operator?(context) = !resolve_operator(context).nil?

      def resolve_operator(context)
        directory = context.operators
        return nil if directory.nil?

        author = context.message.author
        return nil if author.nil? || author.native_id.nil?

        directory.resolve(context.message.origin.adapter_name, author.native_id, username: author.username)
      end

      def operator_label(context) = resolve_operator(context)&.to_s || "an operator"

      def condemn_reply(outcome)
        case outcome.status
        when :done then condemned_line(outcome)
        when :unknown_policy then "No policy called #{outcome.detail.to_s.inspect} is configured here."
        when :nothing_named then "That message has no id I can act on."
        when :unavailable then "Content policy is not configured here."
        else "Something went wrong condemning that."
        end
      end

      def condemned_line(outcome)
        code = outcome.code.to_s
        base = "Condemned under #{outcome.policy}, and kept as a sample for that policy."
        code.empty? ? base : "#{base} Reverse it with /vindicate #{code}."
      end

      # The invocation goes with the answer, the same as every other command
      # here: a condemned message is dealt with, and the command that said so
      # does not stay in the room afterwards.
      # Posted loose rather than as a reply, since remove_command has already
      # taken the invocation and a platform asked to reply to a message that is
      # gone can refuse the send outright.
      def answer(context, text)
        return Outcome.halt([]) if @ephemeral.nil?

        delay = Core::CommandAck.ttl_seconds(context.config)
        group = @ephemeral.post(
          endpoints: [context.message.origin], body: Core::RichText.plain(text),
          name: NOTICE_NAME, delete_after: delay
        )
        @cleanup.after(delay) { group.delete_now } if delay.positive? && @cleanup && group.any?
        Outcome.halt([])
      rescue StandardError => e
        logger.warn { "content policy: could not answer a condemn: #{e.message}" }
        Outcome.halt([])
      end
    end
  end
end
