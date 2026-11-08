# frozen_string_literal: true

module Rubotty
  module Dashboard
    # Plain-language names and category grouping for the Features page, over
    # Features::Catalog's own feature_name keys. Display-only: feature_name
    # itself stays exactly as it is in feature_settings.feature, the REST API
    # and config, everywhere outside this file.
    module FeatureDisplay
      # Every category the Features page groups rows into, alphabetised by
      # title (the order this hash is written in is the order both routes
      # render it in, see app.rb's features.erb loop and screens.civet's
      # renderFeatures, neither re-sorts it).
      CATEGORIES = {
        bridging_and_delivery: "Bridging and Delivery",
        community_tools: "Community Tools",
        identity_and_access: "Identity and Access",
        llm_message_redirection: "Semantic Message Redirection",
        llm_semantic_analysis: "Semantic Analysis",
        llm_summaries: "Room Summaries",
        moderation_and_safety: "Moderation and Safety",
        platform_and_system: "Platform and System",
        translation: "Translation"
      }.freeze

      # feature_name => { display:, category: }: the display rename table
      # plus every feature's category assignment. file_rehosting carries no
      # category of its own, since the Features page never draws it
      # directly, only FILE_REHOSTING_SPLIT's two rows, which carry theirs.
      FEATURES = {
        "anti_raid" => { display: "Anti-Raid Lockdown", category: :moderation_and_safety },
        "anti_spam" => { display: "Anti-Spam Detection", category: :moderation_and_safety },
        "backfill" => { display: "Message Backfill", category: :bridging_and_delivery },
        "bridge" => { display: "Message Bridge", category: :bridging_and_delivery },
        "channel_management" => { display: "Channel Management", category: :bridging_and_delivery },
        "command_builder" => { display: "Guided Command Builder", category: :platform_and_system },
        "commands" => { display: "Command Prefixes", category: :platform_and_system },
        "content_policy" => { display: "Content Policy Filter", category: :llm_semantic_analysis },
        "disabled_command_notice" => { display: "Disabled Command Notice", category: :platform_and_system },
        "events" => { display: "Events & Scheduling", category: :community_tools },
        "faq" => { display: "FAQ Responses", category: :community_tools },
        # The one name for a context that wants a single label for the whole
        # feature_name, such as the escape hatch's feature picker; the
        # Features page itself renders FILE_REHOSTING_SPLIT instead.
        "file_rehosting" => { display: "File Rehosting / Uploads" },
        "greetings" => { display: "Greetings", category: :platform_and_system },
        "guest_portal" => { display: "Guest Portal", category: :identity_and_access },
        "identify_topic" => { display: "Room Topic Identification", category: :identity_and_access },
        "identity_history" => { display: "Identity History", category: :identity_and_access },
        "keyword_watch" => { display: "Keyword Watches", category: :community_tools },
        "link_annotation" => { display: "Foreign Link Translation", category: :translation },
        "link_filter" => { display: "Link Filter", category: :moderation_and_safety },
        "mention_spam" => { display: "Mass Mention Protection", category: :moderation_and_safety },
        "moderated_room" => { display: "Restricted Room Access", category: :identity_and_access },
        "moderation" => { display: "Moderation Commands", category: :moderation_and_safety },
        "multipost" => { display: "Multi-Post Prevention", category: :moderation_and_safety },
        "nickname" => { display: "Nicknames", category: :identity_and_access },
        "operator_requests" => { display: "Operator Requests", category: :identity_and_access },
        "operator_startup_dm" => { display: "Operator Startup DM", category: :identity_and_access },
        "poll" => { display: "Polls", category: :community_tools },
        "redirection" => { display: "Message Redirection", category: :bridging_and_delivery },
        "reports" => { display: "Member Reports", category: :moderation_and_safety },
        "room_summaries" => { display: "Room Summaries", category: :llm_summaries },
        "scheduled_announcements" => { display: "Scheduled Announcements", category: :community_tools },
        "scripts" => { display: "Lua Scripting", category: :platform_and_system },
        "semantic_analysis" => { display: "Semantic FAQ Matching", category: :llm_semantic_analysis },
        "startup_banner" => { display: "Startup Banner", category: :platform_and_system },
        "telegram_avatars" => { display: "Telegram Avatar Sync", category: :identity_and_access },
        "topic_routing" => { display: "Topic Detection", category: :llm_message_redirection },
        "topic_routing_moves" => { display: "Topic Auto-Correction", category: :llm_message_redirection },
        "translation" => { display: "LibreTranslate Message Translation", category: :translation },
        "utility_commands" => { display: "Utility Commands", category: :platform_and_system },
        "warnings" => { display: "Warnings", category: :moderation_and_safety },
        "word_filter" => { display: "Word Blacklist", category: :moderation_and_safety }
      }.freeze

      # file_rehosting's two independently toggleable dashboard halves: one
      # feature_name, one feature_config, two config booleans (see
      # Features::FileRehosting#config_schema). Rendered as two rows in place
      # of file_rehosting's own entry, each reading and writing one key, both
      # under Bridging and Delivery alongside file_rehosting's pipeline
      # neighbours.
      FILE_REHOSTING_SPLIT = [
        { key: "rehost_inbound", display: "File Rehosting", category: :bridging_and_delivery,
          description: "Mirror an oversized inbound file into rubotty's store automatically and post a link instead." },
        { key: "enable_upload_command", display: "File Uploads", category: :bridging_and_delivery,
          description: "Let a member post a file too big for the room with their own /upload command." }
      ].freeze

      # Features whose config lives on its own richer dashboard page instead
      # of the generic per-schema-field form: feature_name => the path
      # segment under a community's own slug. Shared by app.rb's ERB routes
      # and view_data.rb's client payload, so the Config link both surfaces
      # draw next to a row's toggle names the same set of features.
      BESPOKE_CONFIG_PAGE = {
        "word_filter" => "word-filter", "faq" => "faq", "events" => "events", "guest_portal" => "guests",
        "nickname" => "people", "poll" => "polls"
      }.freeze

      # Named presets a mapping-list config field's own row editor offers
      # besides the blank "type everything by hand" row, keyed by feature_name
      # then field name. Content policy's own catalog lives on
      # ContentPolicy::Service, since the four entries are that feature's own
      # content; this map is only the address book both the plain dashboard's
      # ERB partials and view_data.rb's client payload read to find them. A
      # field absent here (word_filter's own entries, everything else) draws
      # only the blank Add entry row it always has.
      FIELD_PRESETS = {
        "content_policy" => { "entries" => ::Rubotty::ContentPolicy::Service::PRESETS }
      }.freeze

      module_function

      # The plain-language name a person reads for feature_name, falling back
      # to the raw name for anything FEATURES has not caught up with yet.
      def name_for(feature_name)
        FEATURES.dig(feature_name.to_s, :display) || feature_name.to_s
      end

      # The category feature_name belongs to, or nil for one FEATURES has not
      # assigned (file_rehosting itself, or a future feature added but not
      # yet categorised).
      def category_for(feature_name)
        FEATURES.dig(feature_name.to_s, :category)
      end

      # Whether +key+ is one of file_rehosting's own two split config keys,
      # the only keys the dashboard's enable_flag/disable_flag op may touch.
      def file_rehosting_split_key?(key)
        FILE_REHOSTING_SPLIT.any? { |split| split[:key] == key.to_s }
      end

      # The bespoke page's own path segment for feature_name, or nil when its
      # config belongs in the generic per-schema-field form instead.
      def bespoke_config_page(feature_name)
        BESPOKE_CONFIG_PAGE[feature_name.to_s]
      end

      # The presets feature_name's field_name offers, or an empty array for a
      # field with no bank of its own.
      def field_presets(feature_name, field_name)
        FIELD_PRESETS.dig(feature_name.to_s, field_name.to_s) || []
      end
    end
  end
end
