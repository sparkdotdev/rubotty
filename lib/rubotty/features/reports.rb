# frozen_string_literal: true

module Rubotty
  module Features
    # Lets a member say something is wrong. Everything else that reaches an
    # operator is something rubotty noticed by itself; short of knowing an
    # operator personally, a member had no way in at all.
    #
    # Two routes live here: `/report` typed as a reply in a room, and the same
    # verb in the bot's own DM. The DM half also reads a pasted link, through
    # {Core::Permalink}. Delivery is {ControlPlane::AdminNotifier}, the same
    # fan-out every content policy alert already rides.
    class Reports < Base
      include AdapterLookup

      REPORT = :report
      COMMANDS = [REPORT].freeze

      def self.feature_name = "reports"

      def self.description = "Lets any member report a message to this community's operators."

      def self.default_enabled? = false

      def self.observes = %i[chat]

      def self.retention_notice
        "A reported message's text, its author and who reported it, for " \
          "#{ControlPlane::MemberReports::RETENTION_DAYS} days."
      end

      def self.config_schema
        Config::Schema.define do
          field :acknowledge, :boolean, default: true,
                desc: "DM the reporter that their report landed. The DM is the only acknowledgement there " \
                      "is: an in-room notice would tell the room who reported, which is the reprisal this " \
                      "exists to avoid, so a reporter the bot cannot DM is counted rather than told."
          field :require_deletable, :boolean, default: true,
                desc: "refuse the in-room route where the bot cannot delete the command. A /report it " \
                      "cannot hide leaves the reporter named in front of the person they reported, which is " \
                      "worse than having no feature at all; the DM route still works and the refusal says so."
        end
      end

      # @param reports [ControlPlane::MemberReports, nil] the store; nil (no
      #   control plane) leaves the verb refused rather than silently dropped
      # @param notifier [#notify_operators!, nil] where a report reaches the
      #   operators, the same fan-out content policy alerts already use
      def initialize(topology:, adapters:, logger:, reports: nil, notifier: nil, people: Core::Directory.new)
        super()
        @topology = topology
        @adapters = adapters
        @logger = logger
        @reports = reports
        @notifier = notifier
        @people = people
      end

      attr_reader :logger

      def call(context)
        return Outcome.continue([]) unless command?(context)

        # Halting either way from here: the command message is removed below
        # and must never be relayed onward, since relaying it is the very trace
        # this route exists to avoid.
        handle(context) unless context.community.nil?
        Outcome.halt([])
      rescue StandardError => e
        logger&.warn { "reports: could not take a report: #{e.class}: #{e.message}" }
        Outcome.halt([])
      end

      private

      def command?(context)
        message = context.message
        return false if message.nil? || message.author&.bot?

        word = context.command_prefixes.strip(message.body.text.to_s)
        !word.nil? && word.split(/\s+/).first.to_s.downcase.delete_prefix("/") == REPORT.to_s
      end

      # The order matters: the reply pointer naming the reported message dies
      # with the command that carried it, so the target is read before anything
      # is removed rather than after.
      def handle(context)
        message = context.message
        target = message.reply_preview
        origin = message.origin
        return answer(context, NOTHING_NAMED) if target&.ref.nil?

        return refuse_undeletable(context) unless deletable?(context, origin)

        filed = file(context, target)
        remove_command(origin, message.ref)
        acknowledge(context, filed)
      end

      NOTHING_NAMED = "Reply to the message you want to report, then type /report."

      # A room the bot cannot delete in leaves the reporter named in front of
      # the person they reported for as long as the message stands, which is
      # worse than having no feature at all here.
      def deletable?(context, origin)
        return true unless config_flag(context, :require_deletable, true)

        adapter = adapter_for(origin)
        !adapter.nil? && adapter.capabilities_for(origin).deletes?
      end

      def refuse_undeletable(context)
        answer(context, "I cannot remove a /report in this room, so typing one here would show everybody " \
                        "who reported it. Send it to me in a private chat instead.")
      end

      def file(context, target)
        return nil if @reports.nil?

        @reports.file(
          community_id: context.community.id, route: "reply",
          reporter: reporter_of(context.message),
          endpoint_id: target.ref.endpoint_id, native_id: target.ref.native_id,
          author: { native_id: target.author&.native_id, display: target.author&.any_name },
          body: target.body&.text
        )
      end

      def reporter_of(message)
        author = message.author
        { adapter: message.origin.adapter_name, native_id: author&.native_id,
          display: author&.any_name }
      end

      # Removed at once, and never through an ephemeral notice: a self-deleting
      # one still shows the room who reported for as long as it lives, however
      # short its own window is set.
      def remove_command(origin, ref)
        return if ref&.native_id.nil?

        adapter = adapter_for(origin)
        adapter&.delete(origin, ref.native_id)
      rescue StandardError => e
        logger&.warn { "reports: could not remove the command in #{origin.id}: #{e.message}" }
      end

      # The reporter hears by DM and nowhere else. Telegram will not let a bot
      # open a chat with somebody who has never written to it, so a reporter who
      # has not is counted rather than told; the verb's own description carries
      # the instruction to open one first. Silence reading as a broken bot is
      # the cost taken deliberately here, which is why the count is put in front
      # of operators rather than only in a log.
      def acknowledge(context, filed)
        return if filed.nil?
        return alert(context, filed) if filed.rate_limited?

        alert(context, filed)
        return unless config_flag(context, :acknowledge, true)

        reached = tell_reporter(context, filed)
        @reports&.acknowledged!(filed.row) if reached
      end

      def tell_reporter(context, filed)
        adapter = adapter_for(context.message.origin)
        return false unless adapter.respond_to?(:supports_admin_dm?) && adapter.supports_admin_dm?

        adapter.send_admin_dm(context.message.author&.native_id, acknowledgement(filed)) ? true : false
      rescue StandardError => e
        logger&.warn { "reports: could not acknowledge a report: #{e.message}" }
        false
      end

      def acknowledgement(filed)
        return "You have reported several messages recently, so this one was not passed on. Try again later." if
          filed.rate_limited?

        row = filed.row
        return "Thank you. The operators have been told." if row.nil?

        "Thank you. The operators have been told, and your report is #{row.code}."
      end

      # One alert per MESSAGE, not per reporter: a second report of the same
      # thing raises the count on the thread that already exists rather than
      # DMing everybody again, which is what keeps this a feature rather than
      # an amplifier.
      def alert(context, filed)
        return if @notifier.nil? || filed.rate_limited? || !filed.first? || filed.row.nil?

        @notifier.notify_operators!(community_id: context.community.id, text: alert_text(context, filed.row))
      rescue StandardError => e
        logger&.warn { "reports: could not tell the operators: #{e.message}" }
      end

      def alert_text(context, row)
        [
          "#{context.community.name}: #{row.reporter_display || "a member"} reported a message " \
            "from #{row.author_display || "somebody"} (#{row.code}).",
          quoted(row.body)
        ].compact.join(" ")
      end

      # As much of the reported message as the alert carries. The report holds
      # its own copy because a reported message is usually gone by the time
      # anybody looks at the alert.
      QUOTE_CHARS = 300

      def quoted(body)
        text = body.to_s.strip
        return nil if text.empty?

        text = "#{text[0, QUOTE_CHARS]}…" if text.length > QUOTE_CHARS
        "It said: \"#{text}\""
      end

      def answer(context, text)
        origin = context.message.origin
        adapter = adapter_for(origin)
        return if adapter.nil?

        remove_command(origin, context.message.ref)
        return unless adapter.respond_to?(:supports_admin_dm?) && adapter.supports_admin_dm?

        adapter.send_admin_dm(context.message.author&.native_id, text)
      rescue StandardError => e
        logger&.warn { "reports: could not answer a report: #{e.message}" }
      end

      def config_flag(context, field, fallback)
        config = context.config
        return fallback unless config.is_a?(Hash)

        raw = config.key?(field) ? config[field] : config[field.to_s]
        raw.nil? ? fallback : ![false, "false", "0", 0].include?(raw)
      end
    end
  end
end
