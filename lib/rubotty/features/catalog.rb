# frozen_string_literal: true

module Rubotty
  module Features
    # The catalog of known features, keyed by the stable +feature_name+ each
    # class declares. Register a new feature by adding its class to {classes}.
    # The CLI and dashboard validate typed feature names against this.
    module Catalog
      module_function

      # The order features actually run in, by feature_name: a Lua processor runs
      # after the word filter, so text it rewrites is never screened again;
      # asserted against the pipeline the router builds, so the two cannot drift.
      #
      # A name may cover several classes, e.g. EventCommand and EventRsvp both
      # answer "events" so one feature_settings row gates both.
      PIPELINE_ORDER = %w[
        moderation moderated_room warnings reports identity_history word_filter content_policy mention_spam link_filter anti_spam multipost
        command_builder faq semantic_analysis topic_routing link_annotation operator_requests greetings utility_commands keyword_watch nickname redirection
        identify_topic guest_portal file_rehosting events poll anti_raid
        room_summaries scripts translation disabled_command_notice bridge
      ].freeze

      # Every feature class, in a stable order; see PIPELINE_ORDER for the run order.
      def classes
        [
          Features::Scripts,
          Features::Bridge,
          Features::Moderation,
          Features::WordFilter,
          Features::ModeratedRoom,
          Features::ContentPolicy,
          Features::MentionSpam,
          Features::LinkFilter,
          Features::AntiSpam,
          Features::Multipost,
          Features::Warnings,
          Features::Reports,
          Features::IdentityHistory,
          # The guided form behind every bare command invocation, catalogued so
          # an operator can switch it off for a room that would rather have the
          # usage line.
          Features::CommandBuilder,
          Features::Faq,
          Features::SemanticAnalysis,
          Features::TopicRouting,
          # The move half of topic routing, deliberately its own switch so a
          # room can classify for as long as somebody wants without acting.
          Features::TopicRoutingMoves,
          Features::LinkAnnotation,
          Features::Greetings,
          Features::ScheduledAnnouncements,
          Features::OperatorRequests,
          Features::UtilityCommands,
          Features::KeywordWatch,
          Features::Nickname,
          Features::Redirection,
          Features::IdentifyTopic,
          Features::AntiRaid,
          Features::DisabledCommandNotice,
          Features::Translation,
          Features::RoomSummaries,
          Features::Backfill,
          # Declaration only, like Backfill above: posted at boot by the runtime.
          Features::StartupBanner,
          # Also declaration only, and orthogonal to StartupBanner rather than
          # a variant of it: the operator DM.
          Features::OperatorStartupDm,
          Features::GuestPortal,
          # A flag the bridge and the /upload command read, not a pipeline step.
          Features::FileRehosting,
          # The same shape: a flag the Telegram adapter reads for itself.
          Features::TelegramAvatars,
          # The same shape again: the shared command markers every
          # command-bearing feature reads, in place of a per-feature copy.
          Features::CommandMarkers,
          Features::Events,
          Features::Poll,
          Features::ChannelManagement
        ].freeze
      end

      # The stable feature_name of every known feature.
      def names
        classes.map(&:feature_name).freeze
      end

      # The order a dashboard uses for configurable features. Message pipeline
      # steps stay in the sequence the router runs them, then configuration-only
      # features follow in their declared order.
      def dashboard_names
        pipeline_names = PIPELINE_ORDER & names
        (pipeline_names + (names - pipeline_names)).freeze
      end

      # True when +name+ is a real feature key.
      def known?(name)
        names.include?(name.to_s)
      end

      # The feature class behind a name, or nil for an unknown name.
      def class_for(name)
        classes.find { |klass| klass.feature_name == name.to_s }
      end

      # The per-scope config schema a feature declares, or nil when it declares none.
      def config_schema(name)
        class_for(name)&.config_schema
      end

      # A one-sentence description of what a feature does.
      def description(name)
        class_for(name)&.description || "No description yet."
      end

      # What turning a feature on makes rubotty keep, or nil when it keeps nothing.
      def retention_notice(name)
        class_for(name)&.retention_notice
      end
    end
  end
end
