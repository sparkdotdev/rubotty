# frozen_string_literal: true

module Rubotty
  module ControlPlane
    # Deployment-wide connection settings for an outside service rubotty
    # plugs into: one row per integration, administrator only, with the
    # credential stored in the database rather than an env var name. Every
    # opted-in community shares the single connection here, so turning an
    # integration off removes it for all of them at once. KNOWN names the
    # whole surface; add a name here and a view for it to add one.
    class Integrations
      # Raised for a request that cannot be carried out. Carries a human
      # message a dashboard flash prints as-is.
      class Invalid < Rubotty::Error; end

      KNOWN = %w[libretranslate openarc].freeze

      def initialize(models:, logger: nil, clock: -> { Time.now }, env: ENV)
        @env = env
        @models = models
        @logger = logger
        @clock = clock
      end

      # Environment credentials take precedence during migration from legacy
      # database values. Set these through the deployment's secret manager.
      def api_key_for(name)
        variable = { "libretranslate" => "RUBOTTY_LIBRETRANSLATE_API_KEY",
                     "openarc" => "RUBOTTY_OPENARC_API_KEY" }.fetch(name)
        presence(@env[variable]) || find(name)&.api_key
      end

      # The stored row for +name+, or nil when it has never been saved.
      def find(name)
        @models.integration.where(name: name.to_s).first
      end

      # Every known integration, each either its stored row or an unsaved one
      # standing in for "never configured", so a view can render one card per
      # name regardless of what has been set up yet.
      def list
        KNOWN.map { |name| find(name) || @models.integration.new(name: name) }
      end

      # Create or update the row for +name+. A nil or blank +api_key+ leaves
      # whatever is already stored untouched, like a blank password field;
      # there is no way to clear the key through this method, only replace it.
      #
      # @param config [Hash] integration-specific settings, e.g. libretranslate's
      #   allowed_pairs text
      # @return [Models::Integration]
      def save(name:, url: nil, api_key: nil, config: {})
        raise Invalid, "#{name.inspect} is not a known integration" unless KNOWN.include?(name.to_s)

        now = @clock.call
        attributes = { url: clean_url(url), config: Models.dump_json(config || {}), updated_at: now }
        clean_key = presence(api_key)
        attributes[:api_key] = clean_key if clean_key

        row = find(name)
        if row
          row.update(**attributes)
          row.refresh
        else
          @models.integration.create(name: name.to_s, created_at: now, **attributes)
        end
      end

      # Whether +name+ has enough set to be usable: a URL is stored. Whether
      # it also NEEDS an api_key is up to the integration's own client, not
      # this generic check.
      def configured?(name)
        !presence(find(name)&.url).nil?
      end

      # Adapts the stored "libretranslate" row into the #url / #api_key /
      # #allowed_pairs shape Translation::Settings expects, parsing
      # +config+'s allowed_pairs text with the same parser it uses for its
      # own env var.
      class LibreTranslateSettings
        def initialize(integrations)
          @integrations = integrations
        end

        def url = row&.url

        def api_key = @integrations.api_key_for("libretranslate")

        def allowed_pairs
          Translation::Settings.parse_pairs(row&.json_value(:config)&.[]("allowed_pairs"))
        end

        private

        def row
          @integrations.find("libretranslate")
        end
      end

      # The shared local text endpoint. The chosen model rides in +config+
      # beside the url and the key, so an administrator rotates it live from
      # the Integrations page; OpenArc::Settings falls back to its own default
      # when a deployment has never picked one. The recipe for putting that
      # model back rides there too, under +reload+, so a server that drops it
      # is something the bridge can answer rather than only report.
      class OpenArcSettings
        def initialize(integrations)
          @integrations = integrations
        end

        def url = row&.url

        def api_key = @integrations.api_key_for("openarc")

        def model = row&.json_value(:config)&.[]("model")

        # The load form's own fields, kept from a load that actually worked.
        # OpenArc::Settings decides whether what is here is usable; this only
        # says what was stored.
        def reload_spec = row&.json_value(:config)&.[]("reload")

        private

        def row
          @integrations.find("openarc")
        end
      end

      private

      # Blank is a valid, "not yet configured" URL; a present one has to be an
      # actual http(s) address, the same rule ScriptEndpoints and FluxerInstances
      # hold their own URL fields to.
      def clean_url(url)
        text = presence(url)
        return nil if text.nil?

        parsed = begin
          URI.parse(text)
        rescue URI::InvalidURIError
          nil
        end
        raise Invalid, "the URL has to be an http or https address" unless
          parsed.is_a?(URI::HTTP) && !parsed.host.to_s.empty?

        text
      end

      def presence(value)
        return nil if value.nil?

        text = value.to_s.strip
        text.empty? ? nil : text
      end
    end
  end
end
