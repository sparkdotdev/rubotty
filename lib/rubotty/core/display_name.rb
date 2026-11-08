# frozen_string_literal: true

module Rubotty
  module Core
    # Renders the sender label prepended to a relayed message. Templates are
    # plain `{field}` strings configured in YAML (endpoint, room, or global;
    # most specific wins) over {Author::FIELDS}. A template whose fields are
    # not all present falls back rather than render, to avoid emitting
    # "FirstName ()"; with no template configured, the router builds the
    # structured {SenderLabel} instead, which {#configured?} reports.
    class DisplayName
      PLACEHOLDER = /\{([a-z_]+)\}/

      # The fallback used for an override template that sets no fallback of its
      # own, so a template referencing a field the sender lacks still degrades.
      DEFAULT_FALLBACK = "{display_name}"

      attr_reader :template, :fallback

      # @param template [String, nil] preferred rendering. nil means no override
      #   is configured and the structured {SenderLabel} default applies.
      # @param fallback [String, nil] used when +template+ references a field
      #   the author does not have
      def initialize(template: nil, fallback: nil)
        @template = presence(template)
        # With no template at all there is nothing to fall back FROM.
        @fallback = presence(fallback) || (@template ? DEFAULT_FALLBACK : nil)
        freeze
      end

      # Whether an override template is configured. When false the router builds
      # the structured {SenderLabel} instead of calling {#render}.
      def configured? = !@template.nil?

      # Fields referenced by a template, in order of appearance.
      def self.fields_in(template)
        template.to_s.scan(PLACEHOLDER).flatten.map(&:to_sym)
      end

      # Every placeholder in +template+ that is not a known Author field. Used by
      # config validation so a typo is caught at boot.
      def self.unknown_fields_in(template)
        fields_in(template) - Author::FIELDS
      end

      # @param author [Author]
      # @return [String] never empty
      def render(author)
        return author.any_name if @template.nil?

        expand(template, author) ||
          (fallback && expand(fallback, author)) ||
          author.any_name
      end

      # Build from an endpoint, falling back through room and then global
      # configuration. Most specific setting wins.
      def self.resolve(endpoint:, room:, default:)
        template = endpoint&.display_name_template || room&.display_name_template || default.template
        fallback = endpoint&.display_name_fallback || room&.display_name_fallback || default.fallback
        new(template: template, fallback: fallback)
      end

      private

      # nil, "" and whitespace only all mean "no template set here", so an empty
      # YAML value reads as "use the structured default".
      def presence(value)
        return nil if value.nil?

        string = value.to_s.strip
        string.empty? ? nil : string
      end

      # Returns nil (rather than a half filled string) when any referenced field
      # is absent. That is the whole defence against "FirstName ()".
      def expand(template, author)
        missing = false
        rendered = template.gsub(PLACEHOLDER) do
          value = author[Regexp.last_match(1)]
          missing = true if value.nil?
          value.to_s
        end
        return nil if missing

        rendered = rendered.strip
        rendered.empty? ? nil : rendered
      end
    end
  end
end
