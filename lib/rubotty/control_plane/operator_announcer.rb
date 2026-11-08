# frozen_string_literal: true

module Rubotty
  module ControlPlane
    # Tells a community's operators what their colleagues just did. Wraps the
    # audit sink rather than calling out from each feature, because every
    # operator action already records one event with the same shape: who acted,
    # on whom, why and to what effect. One seam catches every verb, and a verb
    # added later is announced without anybody remembering to wire it.
    #
    # Reads like an {Core::AuditLog}, so it drops in wherever one is expected.
    class OperatorAnnouncer
      # Which audit sources are an operator's own doing. The automated halves of
      # content policy announce themselves already, so only the reversal a human
      # types is taken from here; word filter and link filter are absent for the
      # same reason.
      ANNOUNCED = { "moderation" => :all, "warnings" => :all,
                    "content_policy" => %w[vindicate].freeze }.freeze

      # The switch, on the moderation feature at community scope: one setting
      # for "tell my operators what we do to this place", rather than one per
      # verb in three different features.
      FIELD = :announce_operator_actions
      FEATURE = "moderation"

      # How much of an acted-on message the announcement quotes. Enough to know
      # what a colleague removed, without the DM becoming the message. The same
      # cap the automated removal alert uses, since it answers the same question.
      QUOTE_CHARS = Core::RemovalNotice::QUOTE_CHARS

      def initialize(audit:, notifier: nil, registry: nil, logger: nil)
        @audit = audit
        @notifier = notifier
        @registry = registry
        @logger = logger
      end

      def durable? = @audit.durable?

      def query(**args) = @audit.query(**args)

      def count(**args) = @audit.count(**args)

      # Record first, announce second, and never let the announcement cost the
      # record: the audit row is the durable trail and a DM is a courtesy. An
      # excerpt passes straight through to a sink that drops it, so what an
      # operator is quoted here is not thereby written down.
      def record(**event)
        written = @audit.record(**event)
        announce(event)
        written
      end

      private

      def announce(event)
        return unless @notifier && announced?(event)

        community = community_for(event[:community])
        return if community.nil? || !enabled?(community)

        @notifier.notify_operators!(community_id: community.id, text: text_for(community, event))
      rescue StandardError => e
        @logger&.warn { "operator announcer: could not announce #{event[:action]}: #{e.class}: #{e.message}" }
      end

      def announced?(event)
        actions = ANNOUNCED[event[:source].to_s]
        return false if actions.nil?

        actions == :all || actions.include?(event[:action].to_s)
      end

      def community_for(slug)
        return nil if slug.to_s.empty?

        @registry&.current&.communities&.find { |community| community.slug.to_s == slug.to_s }
      end

      # On unless a community says otherwise: an operator surprised by what a
      # colleague did is the problem this exists to prevent, so somebody has to
      # turn it off rather than remember to turn it on.
      def enabled?(community)
        config = community.feature_config(nil, FEATURE)
        return true unless config.is_a?(Hash)

        raw = config.key?(FIELD) ? config[FIELD] : config[FIELD.to_s]
        raw.nil? || ![false, "false", "0", 0].include?(raw)
      end

      def text_for(community, event)
        parts = ["#{community.name}: #{actor_of(event)} ran #{verb_of(event)}#{subject_of(event)}."]
        parts << "Reason: #{event[:reason]}." unless event[:reason].to_s.strip.empty?
        parts << "Result: #{event[:outcome]}." unless event[:outcome].to_s.strip.empty?
        quote = quoted(event)
        parts << "Message: \"#{quote}\"" if quote
        parts.join(" ")
      end

      # What the message said, for the verbs that act on one. A colleague reading
      # that somebody ran /delete on a member learns nothing about the call unless
      # the message travels with it, and by then the message is the one thing they
      # cannot go and look at.
      def quoted(event)
        text = event[:excerpt].to_s.strip
        return nil if text.empty?

        text.length > QUOTE_CHARS ? "#{text[0, QUOTE_CHARS]}…" : text
      end

      def actor_of(event)
        actor = event[:actor].to_s.strip
        actor.empty? ? "somebody" : actor
      end

      def verb_of(event) = "/#{event[:action]}"

      # Names the target where there is one, and where there is not says which
      # room instead, so a room verb like /lock still reads as an action
      # somewhere rather than one on nobody.
      def subject_of(event)
        subject = event[:subject].to_s.strip
        return " on #{subject}" unless subject.empty?

        channel = event[:channel].to_s.strip
        channel.empty? ? "" : " in #{channel}"
      end
    end
  end
end
