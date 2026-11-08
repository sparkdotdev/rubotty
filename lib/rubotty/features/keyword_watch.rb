# frozen_string_literal: true

require "securerandom"
require "set"

module Rubotty
  module Features
    # The chat-facing half of the keyword watcher: "summon me when X is said, for N hours."
    #
    #   /watch <keyword> [duration] [mention|dm]   subscribe (default 4h, mention)
    #   /watch list                                list your active watches
    #   /watch stop [keyword]                      end one early
    #
    # Every rule (cap, bounds, cooldown, expiry, delivery) lives in
    # {Core::KeywordWatches::Service}; this owns the command surface and matcher cache.
    class KeywordWatch < Base
      include AdapterLookup

      COMMAND = "watch"

      # The sender label a reply is posted under.
      NOTICE_NAME = "keyword_watch"

      HELP_TEXT = <<~TEXT.strip
        /watch <keyword> [duration] [mention|dm] - get pinged when a keyword is said, cross-platform, for a bounded time (default 4h, default a mention).
        /watch list - show your active watches.
        /watch stop [keyword] - end a watch early (the keyword may be omitted when you only have one).
      TEXT

      def self.feature_name = "keyword_watch"

      def self.description = "Lets a member subscribe to a keyword and get pinged wherever it's said (/watch)."

      # Off by default: a fresh community offers no /watch until an operator turns
      # it on.
      def self.default_enabled? = false

      def self.observes = %i[chat]

      # The per-scope config shape, for the dashboard and loader. The reply TTL and
      # command-pairing knobs are the shared {Core::CommandAck} fields.
      def self.config_schema
        Config::Schema.define do
          field Core::CommandAck::TTL_FIELD, :integer, default: Core::CommandAck::DEFAULT_TTL_SECONDS,
                                                        desc: "seconds a /watch reply lives before it " \
                                                              "self-deletes. 0 leaves it in place."
          field Core::CommandAck::DELETE_COMMAND_FIELD, :boolean,
                default: Core::CommandAck::DELETE_COMMAND_DEFAULT,
                desc: "whether the /watch invocation itself is removed together with its reply"
        end
      end

      # @param service [Core::KeywordWatches::Service] the shared coordinator:
      #   subscribe / list / stop, and the actual matching-triggered notify
      # @param ephemeral [Core::EphemeralMessage, nil] posts a command reply; a
      #   self-contained default keeps the feature standalone in a unit test
      # @param cleanup [Core::Scheduler, nil] fires a reply's self-delete on time
      def initialize(topology:, adapters:, logger:, service:, ephemeral: nil, cleanup: nil)
        super()
        @adapters = adapters
        @logger = logger
        @service = service
        @cleanup = cleanup
        @ephemeral = ephemeral || Core::EphemeralMessage.new(
          adapters: adapters, topology: topology, session_id: SecureRandom.uuid, logger: logger
        )
        # The compiled matcher cache, keyed by community slug; guarded by a mutex
        # because more than one adapter thread can deliver into the pipeline.
        @caches = {}
        @caches_mutex = Mutex.new
      end

      attr_reader :logger

      # Recognise /watch and handle it (always swallowed, never relayed), or scan
      # ordinary text for a match and continue so the bridge still relays it.
      def call(context)
        word, arguments = command_of(context)
        return handle_watch(context, arguments) if word == COMMAND

        scan_for_matches(context)
        Outcome.continue([])
      end

      private

      def command_of(context) = CommandWord.parse(context)

      def handle_watch(context, arguments)
        case arguments.first&.downcase
        when "list" then handle_list(context)
        when "stop" then handle_stop(context, arguments[1..] || [])
        when nil, "help" then acknowledge(context, HELP_TEXT)
        else handle_subscribe(context, arguments)
        end
        Outcome.halt([])
      end

      def handle_subscribe(context, arguments)
        keyword, duration, notify_via = arguments
        result = @service.subscribe(
          community: context.community, subscriber: context.message.author, origin: context.message.origin,
          keyword: keyword, duration: duration, notify_via: notify_via
        )
        acknowledge(context, subscribe_reply(result))
      end

      def subscribe_reply(result)
        return result.error if !result.ok? || result.watch.nil?

        watch = result.watch
        %(Watching "#{watch.keyword}" for #{human_duration(watch.expires_at - Time.now)} ) +
          "(you'll be notified by #{watch.notify_via})."
      end

      def handle_list(context)
        acknowledge(context, list_reply(active_watches(context)))
      end

      def list_reply(watches)
        return "You have no active watches." if watches.empty?

        lines = watches.map { |watch| %(- "#{watch.keyword}", #{human_duration(watch.expires_at - Time.now)} left) }
        (["Your active watches:"] + lines).join("\n")
      end

      def handle_stop(context, arguments)
        keyword = arguments.join(" ").strip
        if keyword.empty?
          watches = active_watches(context)
          return acknowledge(context, stop_no_keyword_reply(watches)) unless watches.size == 1

          keyword = watches.first.keyword
        end

        stopped = @service.stop(
          community: context.community, subscriber: context.message.author,
          adapter: context.message.origin.adapter_name, keyword: keyword
        )
        acknowledge(context, stopped ? %(Stopped watching "#{keyword}".) : %(You're not watching "#{keyword}".))
      end

      def stop_no_keyword_reply(watches)
        return "You have no active watches to stop." if watches.empty?

        "Which one? Usage: /watch stop <keyword>. You're watching: #{watches.map(&:keyword).join(", ")}."
      end

      def active_watches(context)
        @service.list(
          community: context.community, subscriber: context.message.author,
          adapter: context.message.origin.adapter_name
        )
      end

      # Scan ordinary text against this community's compiled watch set, notifying
      # at most one watch per distinct subscriber. A no-op without a resolved
      # community: there is nothing to compile a cache from.
      def scan_for_matches(context)
        return if context.community.nil?

        entries = cache_for(context.community)
        return if entries.empty?

        text = Matcher.bound_input(context.message.body.text)
        notified = Set.new
        entries.each do |watch, matcher|
          subscriber_key = [watch.subscriber_adapter, watch.subscriber_native_id]
          next if notified.include?(subscriber_key)
          next unless matcher.match?(text)

          sent = @service.notify(
            watch, message: context.message, origin: context.message.origin, community: context.community
          )
          notified << subscriber_key if sent
        end
      rescue StandardError => e
        logger.warn { "keyword_watch: matching failed: #{e.class}: #{e.message}" }
      end

      # This community's `[watch, Matcher]` cache, rebuilt only when the service's
      # version counter has moved since it was last built.
      def cache_for(community)
        slug = slug_of(community)
        version = @service.cache_version(community)
        @caches_mutex.synchronize do
          cached = @caches[slug]
          return cached[:entries] if cached && cached[:version] == version

          entries = compile_entries(community)
          @caches[slug] = { version: version, entries: entries }
          entries
        end
      end

      # Compile every active watch in +community+ into a `[watch, Matcher]` pair,
      # dropping any keyword the shared {Matcher} cannot compile safely: one
      # pathological row must not wedge matching for the whole community.
      def compile_entries(community)
        @service.active_for_community(community).filter_map do |watch|
          matcher = Matcher.build(pattern: watch.keyword, mode: "literal", whole_word: true, logger: logger)
          matcher && [watch, matcher]
        end
      end

      def slug_of(community)
        return nil if community.nil?

        community.respond_to?(:slug) ? community.slug : community.to_s
      end

      # Post +text+ to the issuer's endpoint as the bot, self-deleting after the
      # TTL this scope configures and taking the invocation with it when
      # configured to. Never raises: a lost reply must not derail the pipeline.
      def acknowledge(context, text)
        delay = Core::CommandAck.ttl_seconds(context.config)
        group = @ephemeral.post(
          endpoints: [context.message.origin], body: Core::RichText.plain(text),
          name: NOTICE_NAME, delete_after: delay,
          also_delete: Core::CommandAck.pair_with(context.message, context.config),
          reply_to: Core::CommandAck.reply_to(context.message)
        )
        @cleanup.after(delay) { group.delete_now } if delay.positive? && @cleanup && group.any?
        group
      rescue StandardError => e
        logger.warn { "keyword_watch: could not post a reply: #{e.message}" }
        nil
      end

      # "4h" / "30m" / "45s" / "2d", the same compact vocabulary
      # {Core::Warnings}'s own acknowledgements use. Never negative: a watch
      # already past its expiry reads as "0s" rather than "-3s".
      def human_duration(seconds)
        seconds = seconds.to_i
        seconds = 0 if seconds.negative?
        return "#{seconds}s" if seconds < 60
        return "#{seconds / 60}m" if seconds < 3600
        return "#{seconds / 3600}h" if seconds < 86_400

        "#{seconds / 86_400}d"
      end
    end
  end
end
