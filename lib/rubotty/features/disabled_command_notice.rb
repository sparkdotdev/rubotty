# frozen_string_literal: true

require "securerandom"

module Rubotty
  module Features
    # The last word on a recognised command nothing else answered. A client's own
    # command menu offers the word, so a member picks it and waits for a reply;
    # silence reads as a broken bot, and the raw text carrying on to {Bridge}
    # puts the invocation on every other platform as chat. Runs immediately
    # before {Bridge} and unconditionally ({always_enabled?}), says what stopped
    # the command, and halts. The reply is an ordinary command acknowledgement
    # on the stopped feature's own TTL, so a room does not silt up with refusals.
    class DisabledCommandNotice < Base
      NOTICE_NAME = "rubotty"

      # The one place a command word maps to the feature_name that backs it,
      # built from {Core::CommandRegistry} and from what a feature declares in
      # {Base.command_words} rather than enumerated by hand, so a command added
      # without declaring its feature is caught by a spec instead of going quiet.
      def self.command_features
        @command_features ||= registered_command_features.merge(declared_command_features).freeze
      end

      # Moderation's verbs were held out of the map above so a non-operator
      # could not learn which verbs exist. The clients publish that list in
      # their own command menu, so the silence hid nothing and only made the
      # bot look dead to its operators.
      #
      # Only a feature an operator can switch off belongs here: one outside the
      # catalog cannot be toggled, and an always_enabled? one is never the
      # disabled feature behind its own command.
      def self.registered_command_features
        Core::CommandRegistry.all.each_with_object({}) do |spec, map|
          name = spec.feature
          next if name.nil? || !togglable?(name)
          # A console verb is never typed in a room, so claiming its feature is
          # off would answer a question nobody asked here. Read as room?, not
          # as direct?: a :both verb is answered in a room as well as in a DM,
          # and direct? is true for it, so /report was silently left out.
          next unless spec.room?

          map[spec.name.to_s] = name
        end
      end

      # The words a feature answers that the registry does not carry, taken from
      # the classes themselves so a new one cannot be forgotten here.
      def self.declared_command_features
        Catalog.classes.each_with_object({}) do |klass, map|
          next unless togglable?(klass.feature_name)

          klass.command_words.each { |word| map[word.to_s] ||= klass.feature_name }
        end
      end

      def self.togglable?(name)
        Catalog.names.include?(name) && !Catalog.class_for(name)&.always_enabled?
      end

      def self.feature_name = "disabled_command_notice"

      def self.description = "Tells a member why a recognised command did nothing, rather than letting it relay."

      def self.default_enabled? = true

      def self.always_enabled? = true

      # A command can only ride a chat message, the same as every command
      # feature this one speaks up on behalf of.
      def self.observes = %i[chat]

      # @param ephemeral [Core::EphemeralMessage, nil] posts the reply; a
      #   self-contained default keeps the feature standalone in a unit test
      # @param cleanup [Core::Scheduler, nil] fires the reply's self-delete on time
      def initialize(topology:, adapters:, logger:, ephemeral: nil, cleanup: nil)
        super()
        @adapters = adapters
        @logger = logger
        @cleanup = cleanup
        @ephemeral = ephemeral || Core::EphemeralMessage.new(
          adapters: adapters, topology: topology, session_id: SecureRandom.uuid, logger: logger
        )
      end

      attr_reader :logger

      def call(context)
        word = command_word(context)
        return Outcome.continue([]) if word.nil? || !recognised?(word)

        feature_name = self.class.command_features[word]
        acknowledge(context, feature_name, reason_for(context, word, feature_name))
        Outcome.halt([])
      end

      private

      # A word the bot publishes as a command, whether or not the registry is
      # where it is published from. Reaching this feature at all means no other
      # step in the chain answered it.
      def recognised?(word)
        Core::CommandRegistry.known?(word) || self.class.command_features.key?(word)
      end

      # Why the command stopped: a feature an operator switched off is named as
      # such, and anything else is a service this deployment never wired up,
      # which no dashboard toggle would fix.
      def reason_for(context, word, feature_name)
        switched_off?(context, feature_name) ? notice_for(word, feature_name) : unavailable_for(word)
      end

      # Only a resolved community has a switch to read; without one there is no
      # dashboard to send anybody to either.
      def switched_off?(context, feature_name)
        return false if feature_name.nil? || context.community.nil?

        !context.community.feature_enabled?(context.channel, feature_name)
      end

      # The command word (lowercased, with any Telegram "@botname" suffix
      # removed), or nil when the message is not a command at all.
      def command_word(context) = CommandWord.parse(context).first

      # Names the feature by its real, human description rather than its
      # internal feature_name key, reusing {Catalog.description} so this
      # reads the exact same wording the dashboard's Features page shows,
      # rather than a second copy of it drifting here.
      def notice_for(word, feature_name)
        "Sorry, /#{word} isn't turned on in this room (\"#{Catalog.description(feature_name)}\"). " \
          "An operator can enable it from the dashboard's Features page."
      end

      # Said when the command's own feature is on but nothing served the word,
      # which is what a room sees when the service behind a feature was never
      # wired up in this deployment.
      def unavailable_for(word)
        "Sorry, /#{word} is not available in this room. An operator can check it on the " \
          "dashboard's Features page."
      end

      # The stopped feature's OWN acknowledgement settings, so a refusal lives
      # exactly as long as that feature's accepted commands do and is paired
      # with the invocation on the same terms.
      def ack_config(context, feature_name)
        return context.config if feature_name.nil? || context.community.nil?

        context.community.feature_config(context.channel, feature_name) || {}
      end

      # Post +text+ to the issuer's endpoint as the bot, self-deleting after
      # the standardised TTL, taking the invocation with it, exactly the
      # shared pattern every other command surface uses (see
      # {UtilityCommands#acknowledge}). The TTL and the pairing come from the
      # stopped feature's own config, falling back to this class's own
      # (unconfigurable) one, which is always {} and so reads
      # {Core::CommandAck}'s defaults.
      def acknowledge(context, feature_name, text)
        config = ack_config(context, feature_name)
        delay = Core::CommandAck.ttl_seconds(config)
        group = @ephemeral.post(
          endpoints: [context.message.origin], body: Core::RichText.plain(text),
          name: NOTICE_NAME, delete_after: delay,
          also_delete: Core::CommandAck.pair_with(context.message, config),
          reply_to: Core::CommandAck.reply_to(context.message)
        )
        @cleanup.after(delay) { group.delete_now } if delay.positive? && @cleanup && group.any?
        group
      rescue StandardError => e
        logger.warn { "disabled_command_notice: could not post a reply: #{e.message}" }
        nil
      end
    end
  end
end
