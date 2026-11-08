# frozen_string_literal: true

require "monitor"

module Rubotty
  module Features
    # Somebody posts an article nobody in the room can read; rubotty replies with a link
    # to a translated version. Language comes from the page's own +lang+ declaration,
    # falling back to a function-word pass over the body when the publisher declared
    # nothing, and nothing is posted when neither can tell. The fetch itself runs in
    # {LinkAnnotation::Annotator} on the durable scheduler, so a hanging news site can't
    # block the pipeline every room in the deployment shares.
    class LinkAnnotation < Base
      MODES = %w[always on_reaction].freeze
      DEFAULT_MODE = "on_reaction"

      # The globe: a flag names a country, and languages are not countries.
      DEFAULT_REACTION = "🌐"

      DEFAULT_LANGUAGES = %w[en].freeze

      # How many links in one message are looked at; each one is an outbound
      # request.
      DEFAULT_MAX_LINKS = 2

      # How many messages' links are remembered for a later reaction to point at.
      # In memory and bounded: losing it on a restart costs a reaction that finds
      # nothing rather than anything worse.
      REMEMBERED_MESSAGES = 500

      def self.failure_policy = :continue

      def self.feature_name = "link_annotation"

      def self.description = "Replies to a link to a foreign-language article with a link to a translation of it."

      def self.default_enabled? = false

      # Not edits: an annotation answers a message as it was posted, and
      # re-answering an edited one would mean two replies to the same link.
      def self.observes = %i[chat reaction_add]

      def self.config_schema
        Config::Schema.define do
          field :mode, :string, default: DEFAULT_MODE, one_of: MODES,
                desc: "always: reply to every foreign-language link. on_reaction: only when somebody " \
                      "reacts to the message with the reaction emoji below."
          field :reaction, :string, default: DEFAULT_REACTION,
                desc: "the emoji that asks for a translation, in on_reaction mode"
          field :room_languages, :array, of: :string, default: DEFAULT_LANGUAGES,
                desc: "the languages this room already reads, as two-letter codes. A page in one of " \
                      "them is never annotated, and the FIRST entry is what pages are translated into."
          field :services, :array, of: :string, default: Rubotty::LinkAnnotation::Services::DEFAULT_KEYS,
                desc: "which translation front ends to offer, one per line, in the order to show " \
                      "them. Known: #{Rubotty::LinkAnnotation::Services.translation_keys.join(", ")}."
          field :max_links, :integer, default: DEFAULT_MAX_LINKS,
                desc: "how many links in one message are looked at"
          field :skip_domains, :array, of: :string, default: [],
                desc: "domains never to annotate, subdomains included"
        end
      end

      # @param logger [#debug, #info, #warn]
      # @param annotator [LinkAnnotation::Annotator, nil] where a URL is handed
      #   off to be read. Nil (no durable scheduler behind it) makes the whole
      #   feature inert.
      def initialize(logger:, annotator: nil)
        super()
        @logger = logger
        @annotator = annotator
        @remembered = {}
        @monitor = Monitor.new
      end

      attr_reader :logger

      # Never halts: the annotation is a reply alongside the message, so the
      # bridge still relays the original.
      def call(context)
        return Outcome.continue([]) if @annotator.nil?

        case context.message.kind
        when :chat then on_chat(context)
        when :reaction_add then on_reaction(context)
        end
        Outcome.continue([])
      end

      private

      def on_chat(context)
        links = links_in(context)
        return if links.empty?

        # Remembered whichever mode this room is in, so an operator switching the
        # setting gets a feature that works on the messages already on screen.
        remember(context.message.ref, links)
        links.each { |uri| ask(context, uri) } if mode(context.config) == "always"
      end

      # Act only in on_reaction mode: in "always" the link was already answered
      # when it was posted, and acting on the reaction too would answer twice.
      def on_reaction(context)
        return unless mode(context.config) == "on_reaction"
        return unless asked_for?(context.message.reaction, context.config)

        recall(context.message.ref).each { |uri| ask(context, uri) }
      end

      # Whether this reaction is the one the room configured, compared without the
      # variation selector: Discord sends the emoji with it, Telegram sends
      # several of the same emoji without, and a pasted config value has either.
      def asked_for?(reaction, config)
        return false if reaction.nil? || !reaction.unicode?

        wanted = string_value(config, :reaction, DEFAULT_REACTION).strip
        return false if wanted.empty?

        reaction.without_variation_selector == Core::Reaction.new(emoji: wanted).without_variation_selector
      end

      def ask(context, uri)
        @annotator.enqueue(
          community: context.community&.slug, endpoint_id: context.message.origin.id,
          url: uri.to_s, known: languages(context.config), services: services(context.config)
        )
      rescue StandardError => e
        logger.warn { "link_annotation: could not queue a look at #{uri.host}: #{e.class}: #{e.message}" }
      end

      # Every link this message carries, cleaned, deduplicated and capped. The
      # scan reuses {LinkFilter::URL_REGEX} so the two cannot drift apart.
      def links_in(context)
        text = Matcher.bound_input(context.message.body.text)
        raw = text.scan(LinkFilter::URL_REGEX).map { |url| url.sub(/[.,;:!?)\]}'"]+\z/, "") }
        raw.concat(span_links(context.message.body))
        skip = Array(list_value(context.config, :skip_domains))
        raw.filter_map { |url| Rubotty::LinkAnnotation::Link.clean(url) }
           .reject { |uri| Rubotty::LinkAnnotation::Link.under?(uri.host, skip) }
           .uniq(&:to_s)
           .first(max_links(context.config))
      end

      def span_links(body)
        body.spans.filter_map do |span|
          next nil unless span.kind == :link

          (span.attributes[:url] || span.attributes["url"])&.to_s
        end
      end

      def remember(ref, links)
        key = ref_key(ref)
        return if key.nil?

        @monitor.synchronize do
          @remembered.delete(key)
          @remembered[key] = links.map(&:to_s)
          @remembered.shift while @remembered.size > REMEMBERED_MESSAGES
        end
      end

      def recall(ref)
        key = ref_key(ref)
        return [] if key.nil?

        stored = @monitor.synchronize { @remembered[key] }
        Array(stored).filter_map { |url| Rubotty::LinkAnnotation::Link.clean(url) }
      end

      def ref_key(ref)
        return nil if ref.nil? || ref.native_id.nil?

        "#{ref.endpoint_id}\x00#{ref.native_id}"
      end

      def mode(config)
        candidate = string_value(config, :mode, DEFAULT_MODE)
        MODES.include?(candidate) ? candidate : DEFAULT_MODE
      end

      def languages(config)
        codes = Array(list_value(config, :room_languages))
                .filter_map { |code| Rubotty::LinkAnnotation::Language.normalise(code) }
        codes.empty? ? DEFAULT_LANGUAGES : codes.uniq
      end

      def services(config)
        keys = Array(list_value(config, :services)).map { |key| key.to_s.strip }.reject(&:empty?)
        known = keys & Rubotty::LinkAnnotation::Services.translation_keys
        logger.warn { "link_annotation: ignoring unknown service(s) #{(keys - known).join(", ")}" } if known != keys
        known.empty? ? Rubotty::LinkAnnotation::Services::DEFAULT_KEYS : known
      end

      def max_links(config)
        value = config_value(config, :max_links).to_i
        value.positive? ? value : DEFAULT_MAX_LINKS
      end

      def string_value(config, key, fallback)
        value = config_value(config, key)
        value.nil? || value.to_s.empty? ? fallback : value.to_s
      end

      def list_value(config, key)
        value = config_value(config, key)
        value.nil? ? [] : value
      end

      # Feature config arrives with string keys from the database and symbol keys
      # from a code default, so both are tried.
      def config_value(config, key)
        return nil unless config.is_a?(Hash)

        config.key?(key) ? config[key] : config[key.to_s]
      end
    end
  end
end
