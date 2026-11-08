# frozen_string_literal: true

module Rubotty
  module Translation
    # Where the LibreTranslate connection lives: one connection for the whole
    # deployment, administrator only, never per room or community. +store+
    # is the seam the dashboard's Integrations page drives; anything
    # answering #url, #api_key and #allowed_pairs wins over the environment,
    # and nil (a deployment with no control plane) leaves the environment as
    # the sole source.
    class Settings
      URL_VAR = "RUBOTTY_LIBRETRANSLATE_URL"
      API_KEY_VAR = "RUBOTTY_LIBRETRANSLATE_API_KEY"
      # Comma separated "source:target" pairs, e.g. "en:pt,pt:en,en:es". Unset
      # or empty means every pair is allowed, which is the ordinary case for a
      # single self-hosted instance.
      ALLOWED_PAIRS_VAR = "RUBOTTY_LIBRETRANSLATE_ALLOWED_PAIRS"

      # @param env [Hash] injected in specs
      # @param store [#url, #api_key, #allowed_pairs, nil] the future
      #   Integrations page's own settings object
      def initialize(env: ENV, store: nil)
        @env = env
        @store = store
      end

      # @return [String, nil]
      def url
        from_store(:url) || presence(@env[URL_VAR])
      end

      # @return [String, nil]
      def api_key
        presence(@env[API_KEY_VAR]) || from_store(:api_key)
      end

      # @return [Boolean] whether there is anything to connect to at all
      def configured? = !url.nil?

      # @return [Boolean] whether +source+ -> +target+ may be asked for. True
      #   with no allow list configured at all, which is the default: a
      #   deployment's own instance is trusted for whatever it can translate
      #   until an administrator narrows it.
      def allowed?(source, target)
        pairs = from_store(:allowed_pairs) || pairs_from_env
        return true if pairs.nil? || pairs.empty?

        pairs.include?([source.to_s, target.to_s])
      end

      # Comma separated "source:target" pairs, e.g. "en:pt,pt:en", the format
      # both ALLOWED_PAIRS_VAR and the Integrations page's own textarea are
      # written in. A malformed entry is skipped rather than raised on, so
      # one typo does not take down every pair around it. Public and a class
      # method, so a store built over a DB row can reuse the same parser.
      #
      # @return [Array<Array(String, String)>, nil] nil for blank input,
      #   meaning "no restriction"
      def self.parse_pairs(text)
        raw = text.to_s.strip
        return nil if raw.empty?

        raw.split(",").filter_map { |entry| pair_from(entry) }
      end

      def self.pair_from(entry)
        source, target = entry.to_s.split(":", 2).map { |part| part.to_s.strip }
        return nil if source.to_s.empty? || target.to_s.empty?

        [source, target]
      end

      private

      def from_store(method_name)
        return nil if @store.nil? || !@store.respond_to?(method_name)

        value = @store.public_send(method_name)
        return nil if value.nil?
        return nil if value.respond_to?(:empty?) && value.empty?

        value
      end

      def pairs_from_env = self.class.parse_pairs(@env[ALLOWED_PAIRS_VAR])

      def presence(value)
        return nil if value.nil?

        text = value.to_s.strip
        text.empty? ? nil : text
      end
    end
  end
end
