# frozen_string_literal: true

module Rubotty
  module Core
    # The one standard moderation removal flow, shared by the word filter,
    # the invite/link filter, and the mention-spam guard so their shape and
    # timing can't drift. A filter does the removal itself and hands the
    # message here to record it in the audit log and, on a delete, post a
    # self-deleting notice pinging the author (or the plain name where pings
    # aren't possible), through the shared {EphemeralMessage} primitive so
    # its lifetime is crash-safe. Never raises: a lost audit line or notice
    # must not derail the pipeline.
    class RemovalNotice
      # The standardised default TTL, used when a scope has not set its own value.
      DEFAULT_TTL_SECONDS = 60

      # The single config field name every filter exposes for its removal-notice
      # TTL, stored per scope in feature_settings.
      TTL_FIELD = :removal_notice_ttl_seconds

      # Whether a removal here also DMs the community's operators. One field
      # name across every filter that alerts, so an operator turning it off
      # types the same thing wherever they are.
      NOTIFY_FIELD = :notify_operators

      # How much of the removed message the alert quotes. The operator needs
      # enough to judge the call without the DM becoming the message.
      QUOTE_CHARS = 300

      # @param ephemeral [Core::EphemeralMessage, nil] posts and self-deletes the
      #   notice; a nil primitive makes the notice a silent no-op
      # @param cleanup [Core::Scheduler, nil] fires the self-delete on time;
      #   without one the durable row is swept on the next boot
      # @param source [String] the audit `source` key for this filter
      # @param admin_notifier [#notify_operators!, nil] where a removal is told
      #   to the operators; nil leaves the audit row as the only record
      # @param alerts [Boolean] whether this filter's removals earn that DM
      def initialize(ephemeral: nil, cleanup: nil, audit: nil, logger: nil,
                     source: "moderation", name: "moderation",
                     admin_notifier: nil, alerts: false, adapters: nil)
        @ephemeral = ephemeral
        @cleanup = cleanup
        @audit = audit || AuditLog::Null.new
        @logger = logger
        @source = source.to_s
        @name = name.to_s
        @admin_notifier = admin_notifier
        @alerts = alerts
        @adapters = adapters
      end

      # Run the standard flow for one removed (or flagged) message. The caller has
      # already carried out the removal, if any.
      #
      # @param requested [String, nil] the originally requested action, when it
      #   differed from +action+ (a warn / mute degraded to a stub), for the trail
      def apply(context:, action:, reason:, requested: nil, metadata: {})
        record_audit(context: context, action: action, reason: reason,
                     requested: requested, metadata: metadata)
        if action.to_s == "delete"
          post_notice(context: context, reason: reason)
          alert_operators(context: context, reason: reason)
        end
        nil
      end

      # Whether this scope wants a removal DM, defaulting to on. A removal
      # nobody hears about is the failure this exists to prevent, so an
      # operator has to say no rather than remember to say yes.
      #
      # @param config [Hash]
      # @return [Boolean]
      def self.notify_operators?(config)
        config = {} unless config.is_a?(Hash)
        raw = config.key?(NOTIFY_FIELD) ? config[NOTIFY_FIELD] : config[NOTIFY_FIELD.to_s]
        return true if raw.nil?

        ![false, "false", "0", 0].include?(raw)
      end

      # Resolve the notice TTL (seconds) from a per-scope feature config hash,
      # tolerating string or symbol keys. A missing or unparseable value falls back
      # to {DEFAULT_TTL_SECONDS}; a configured 0 means the notice persists.
      #
      # @param config [Hash]
      # @return [Integer] seconds
      def self.ttl_seconds(config)
        config = {} unless config.is_a?(Hash)
        raw = config[TTL_FIELD]
        raw = config[TTL_FIELD.to_s] if raw.nil?
        value = Integer(raw, exception: false)
        value.nil? || value.negative? ? DEFAULT_TTL_SECONDS : value
      end

      private

      # Record one action in the durable moderation audit log. For an automated
      # removal the actor is this filter's own source label and there is no actor
      # native id; the subject is the author whose message was acted on.
      def record_audit(context:, action:, reason:, requested:, metadata:)
        message = context.message
        author = message&.author
        @audit.record(
          community: context.community&.slug,
          source: @source,
          action: action.to_s,
          adapter: message&.origin&.adapter_name,
          channel: scope_key(context),
          actor: @source,
          subject: author&.any_name,
          subject_native_id: author&.native_id,
          target_ref: message&.ref&.to_s,
          reason: reason,
          outcome: action.to_s,
          metadata: audit_metadata(action, requested, metadata)
        )
      rescue StandardError => e
        @logger&.warn { "removal_notice: could not record the audit event: #{e.message}" }
      end

      # DM the community's operators that a message was removed. The in-room
      # notice self-deletes and the message itself is gone, so without this a
      # filter removes something and no human ever learns of it, which is
      # exactly how one deleting the wrong thing stays invisible.
      #
      # Only the filters judging what a message SAID set +alerts+. A rate guard
      # does not: a flood is self evidently spam, and one DM per dropped
      # message would bury the alerts worth reading.
      def alert_operators(context:, reason:)
        return unless @alerts && @admin_notifier
        return unless self.class.notify_operators?(context.config)

        community = context.community
        return if community.nil?

        delivery = @admin_notifier.notify_operators!(community_id: community.id, text: alert_text(context, reason))
        return unless delivery.none?

        @logger&.warn { "#{@source}: a removal in #{community.slug} reached no operator by DM" }
      rescue StandardError => e
        @logger&.warn { "#{@source}: could not DM the operators about a removal: #{e.message}" }
      end

      def alert_text(context, reason)
        message = context.message
        where = permalink_for(message) || scope_key(context).to_s
        where = "no link available" if where.empty?
        "#{context.community&.name}: #{@source} removed a message from #{display_name(message&.author)} "           "(#{where}). Reason: #{terminate(reason)} Message: \"#{quoted(message)}\""
      end

      def quoted(message)
        text = message&.body&.text.to_s.strip
        return "(no text)" if text.empty?

        text.length > QUOTE_CHARS ? "#{text[0, QUOTE_CHARS]}…" : text
      end

      def permalink_for(message)
        origin = message&.origin
        return nil if origin.nil?

        adapter = @adapters && @adapters[[origin.adapter_name, origin.account]]
        adapter&.message_permalink(origin, message.ref&.native_id)
      rescue StandardError
        nil
      end

      # Post the self-deleting @mention notice to the origin endpoint through the
      # shared ephemeral primitive. A nil primitive means a silent no-op.
      def post_notice(context:, reason:)
        return if @ephemeral.nil?

        message = context.message
        body = notice_body(reason, message.author, message.origin)
        ttl = self.class.ttl_seconds(context.config)
        group = @ephemeral.post(
          endpoints: [message.origin],
          body: body,
          name: @name,
          delete_after: ttl
        )
        @cleanup.after(ttl) { group.delete_now } if ttl.positive? && @cleanup && group.any?
      rescue StandardError => e
        @logger&.warn { "removal_notice: could not post the notice: #{e.message}" }
      end

      # Build the notice as a {RichText}: the author's display name carrying a
      # mention span, followed by the fixed sentence and the reason.
      def notice_body(reason, author, origin)
        name = display_name(author)
        text = "#{name} Your last message was automatically removed: #{terminate(reason)}"
        span = mention_span(author, origin, name)
        RichText.new(text, span ? [span] : [])
      end

      # A mention span over the leading display name, carrying the origin
      # platform's id-for-target attribute, or nil when the author has no native
      # id there.
      def mention_span(author, origin, name)
        native_id = author&.native_id
        return nil if native_id.nil? || origin.nil?

        key = :"#{origin.adapter_name}_id_for_target"
        Span.new(kind: :mention, begin_index: 0, end_index: name.length, attributes: { key => native_id })
      end

      def display_name(author)
        name = author&.any_name
        name.nil? || name.to_s.strip.empty? ? "someone" : name.to_s
      end

      # End the reason with exactly one sentence terminator.
      def terminate(reason)
        text = reason.to_s.strip
        text.end_with?(".", "!", "?") ? text : "#{text}."
      end

      # Merge the requested action, when it differed from the effective one, into
      # the caller's metadata, dropping an empty hash so the audit column stays
      # NULL rather than "{}".
      def audit_metadata(action, requested, metadata)
        merged = {}
        merged.merge!(metadata) if metadata.is_a?(Hash)
        merged[:requested] = requested.to_s if requested && requested.to_s != action.to_s
        merged.empty? ? nil : merged
      end

      def scope_key(context)
        if context.channel.respond_to?(:endpoint_key)
          context.channel.endpoint_key
        else
          context.message&.origin&.id
        end
      end
    end
  end
end
