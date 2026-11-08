# frozen_string_literal: true

require "uri"

module Rubotty
  module LinkAnnotation
    # The front ends a link can be handed to, and how to build one link out of
    # another.
    #
    # Anything in {Service#template} is substituted raw, because a template is
    # host and path; anything in {Service#query} is percent encoded as a query
    # value. Get either wrong and the link still looks right.
    module Services
      # @!attribute key
      #   the stable name an operator lists in the "services" config field
      # @!attribute carry_query
      #   copy the target's own query parameters across first, for a front end
      #   that rewrites the host and keeps the path
      # @!attribute needs_source_language
      #   true for a front end that cannot be trusted with "auto"
      Service = Struct.new(
        :key, :label, :kind, :template, :query, :carry_query, :needs_source_language,
        keyword_init: true
      ) do
        def translation? = kind == :translation
      end

      # The placeholders a template or a query value may use: {url}, {source}
      # (the detected language, or "auto"), {target}, {proxy_host} (the host
      # rewritten the way translate.goog wants it) and {path}.
      PLACEHOLDER = /\{(\w+)\}/

      TRANSLATION = [
        # 302s to the .translate.goog proxy below, carrying source and target
        # across.
        Service.new(
          key: "google", label: "Google Translate", kind: :translation,
          template: "https://translate.google.com/translate",
          query: { "sl" => "{source}", "tl" => "{target}", "u" => "{url}" }
        ),
        # Answers 200 with the translated page, so it survives when
        # translate.google.com hits a consent wall.
        Service.new(
          key: "google_proxy", label: "Google Translate (direct)", kind: :translation,
          template: "https://{proxy_host}.translate.goog{path}",
          query: { "_x_tr_sl" => "{source}", "_x_tr_tl" => "{target}", "_x_tr_hl" => "{target}" },
          carry_query: true
        ),
        # Asked for "auto-en" it answers with a proxy URL of "en-ru" and the
        # reader gets Russian, so needs_source_language keeps it to a real one.
        Service.new(
          key: "yandex", label: "Yandex Translate", kind: :translation,
          template: "https://translate.yandex.com/translate",
          query: { "url" => "{url}", "lang" => "{source}-{target}" },
          needs_source_language: true
        )
      ].freeze

      ALL = TRANSLATION.to_h { |service| [service.key, service] }.freeze

      # What a room gets when its config names none.
      DEFAULT_KEYS = %w[google].freeze

      module_function

      def find(key) = ALL[key.to_s]

      def keys = ALL.keys

      def translation_keys = TRANSLATION.map(&:key)

      # The services named by +keys+, in the order the operator listed them,
      # skipping any name this does not know.
      def resolve(keys)
        Array(keys).filter_map { |key| find(key) }.uniq
      end

      # Build one front end's link for +uri+, or nil when this service cannot
      # serve this URL.
      #
      # @param service [Service]
      # @param uri [URI::HTTPS] the cleaned target
      # @param source [String, nil] the detected language, nil when unknown
      # @param target [String] the language to translate into
      # @return [String, nil]
      def build(service, uri:, target:, source: nil)
        return nil if service.nil? || uri.nil?
        return nil if service.needs_source_language && blank?(source)

        values = placeholder_values(uri, source: source, target: target)
        return nil if service.template.include?("{proxy_host}") && values["proxy_host"].nil?

        append(substitute(service.template, values), query_for(service, uri, values))
      end

      # The host as translate.goog spells it: every dot becomes a hyphen, and an
      # existing hyphen is doubled first, so www.n-tv.de is served at
      # www-n--tv-de.translate.goog and the single-hyphen spelling 404s.
      #
      # nil for an internationalised host, whose "xn--" label already contains
      # this scheme's escape.
      def proxy_host(host)
        name = host.to_s.downcase
        return nil if name.empty? || !name.ascii_only? || name.include?("xn--")

        name.gsub("-", "--").tr(".", "-")
      end

      def placeholder_values(uri, source:, target:)
        {
          "url" => uri.to_s,
          # "auto" suits a front end that detects for itself; one that cannot was
          # refused above.
          "source" => blank?(source) ? "auto" : source.to_s,
          "target" => target.to_s,
          "proxy_host" => proxy_host(uri.host),
          "path" => uri.path.to_s.empty? ? "/" : uri.path.to_s
        }
      end
      private_class_method :placeholder_values

      def query_for(service, uri, values)
        params = []
        params.concat(URI.decode_www_form(uri.query)) if service.carry_query && !uri.query.to_s.empty?
        service.query.to_h.each { |name, value| params << [name, substitute(value, values)] }
        params
      end
      private_class_method :query_for

      def append(base, params)
        return base if params.empty?

        "#{base}#{base.include?("?") ? "&" : "?"}#{URI.encode_www_form(params)}"
      end
      private_class_method :append

      def substitute(text, values)
        text.to_s.gsub(PLACEHOLDER) { values[Regexp.last_match(1)].to_s }
      end
      private_class_method :substitute

      def blank?(value) = value.nil? || value.to_s.strip.empty?
      private_class_method :blank?
    end
  end
end
