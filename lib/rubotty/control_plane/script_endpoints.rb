# frozen_string_literal: true

module Rubotty
  module ControlPlane
    # The named outbound endpoints a script may call: an administrator writes down
    # what a name means, and a script only ever knows the name. The administrator
    # decides which hosts are reachable and the credentials live in the row.
    class ScriptEndpoints
      class Invalid < Rubotty::Error; end

      METHODS = %w[GET POST].freeze
      NAME_PATTERN = /\A[a-z0-9][a-z0-9_-]{0,63}\z/i

      # Bounds on what an administrator may set, so a mistake in the form cannot
      # hold a message up or hammer somebody's API on every line of chat.
      MAX_TIMEOUT = 30
      MAX_CACHE = 24 * 60 * 60

      def initialize(models:, logger: nil, clock: -> { Time.now })
        @models = models
        @logger = logger
        @clock = clock
      end

      def list(community)
        @models.script_endpoint.where(community_id: community.id).order(:name).all
      end

      def find(community, id)
        @models.script_endpoint.where(community_id: community.id, id: id).first
      end

      def find_by_name(community, name)
        @models.script_endpoint.where(community_id: community.id, name: name.to_s).first
      end

      # Create or update. Unlike a script, an endpoint is refused when it is
      # wrong: there is no half finished state worth keeping.
      def save(community:, name:, url:, http_method: "GET", description: nil, headers: nil,
               allow_sync: false, timeout_seconds: 2, cache_seconds: 30, enabled: true,
               query_params: nil, created_by: nil, id: nil)
        attributes = validate(name: name, url: url, http_method: http_method, description: description,
                              headers: headers, allow_sync: allow_sync,
                              timeout_seconds: timeout_seconds, cache_seconds: cache_seconds,
                              enabled: enabled, query_params: query_params)
        now = @clock.call
        existing = id ? find(community, id) : nil
        raise Invalid, "no endpoint with that id in this community" if id && existing.nil?

        clash = find_by_name(community, attributes[:name])
        raise Invalid, "an endpoint called #{attributes[:name].inspect} already exists" if
          clash && clash.id != existing&.id

        return insert(community, attributes, created_by, now) if existing.nil?

        existing.update(**attributes, updated_at: now)
        existing.refresh
      end

      def delete(community, id)
        row = find(community, id)
        raise Invalid, "no endpoint with that id in this community" if row.nil?

        row.destroy
        row
      end

      def set_enabled(community, id, enabled)
        row = find(community, id)
        raise Invalid, "no endpoint with that id in this community" if row.nil?

        row.update(enabled: !!enabled, updated_at: @clock.call)
        row.refresh
      end

      # Query parameters as typed, one "name: value" per line, the same shape as
      # the headers block.
      def self.parse_pairs(text) = parse_headers(text)

      # Back to the textarea form.
      def self.pairs_to_lines(stored) = headers_to_lines(stored)

      # The header block as an administrator typed it, one "Name: value" per line.
      # A blank line or stray whitespace is not an error worth stopping for.
      def self.parse_headers(text)
        text.to_s.lines.filter_map do |line|
          stripped = line.strip
          next nil if stripped.empty?

          name, _, value = stripped.partition(":")
          next nil if name.strip.empty?

          [name.strip, value.strip]
        end.to_h
      end

      # What a stored column holds, as a Hash. The column is JSON, and save takes
      # either a Hash or the textarea's "Name: value" lines, so handing the raw
      # column straight back to save reads a JSON document as one header line.
      def self.stored_hash(stored)
        return stored if stored.is_a?(Hash)

        decoded = JSON.parse(stored.to_s)
        decoded.is_a?(Hash) ? decoded : {}
      rescue StandardError
        {}
      end

      def self.headers_to_lines(stored)
        decoded = stored.is_a?(Hash) ? stored : JSON.parse(stored.to_s)
        (decoded || {}).map { |name, value| "#{name}: #{value}" }.join("\n")
      rescue StandardError
        ""
      end

      private

      def insert(community, attributes, created_by, now)
        @models.script_endpoint.create(
          community_id: community.id, created_by: created_by.to_s,
          created_at: now, updated_at: now, **attributes
        )
      end

      # allow_sync and cache_seconds are deprecated and inert. Still taken,
      # bounded and stored so the REST contract and an existing client keep
      # working; nothing reads them back.
      def validate(name:, url:, http_method:, description:, headers:, allow_sync:,
                   timeout_seconds:, cache_seconds:, enabled:, query_params: nil)
        clean_name = name.to_s.strip
        raise Invalid, "An endpoint needs a name a script can call it by." unless clean_name.match?(NAME_PATTERN)

        verb = http_method.to_s.upcase
        raise Invalid, "An endpoint is a GET or a POST." unless METHODS.include?(verb)

        {
          name: clean_name.downcase, url: clean_url(url), http_method: verb,
          description: description.to_s.strip, headers: Models.dump_json(header_hash(headers)),
          allow_sync: !!allow_sync, enabled: !!enabled,
          timeout_seconds: bounded(timeout_seconds, 1, MAX_TIMEOUT, 2),
          cache_seconds: bounded(cache_seconds, 0, MAX_CACHE, 30),
          query_params: Models.dump_json(query_hash(query_params))
        }
      end

      # http and https only, and a host that is actually there. Anything else is
      # worth refusing at the form rather than inside somebody's rule.
      def clean_url(url)
        text = url.to_s.strip
        raise Invalid, "An endpoint needs a URL." if text.empty?

        parsed = begin
          URI.parse(text)
        rescue URI::InvalidURIError
          nil
        end
        unless parsed.is_a?(URI::HTTP) && !parsed.host.to_s.empty?
          raise Invalid, "An endpoint's URL has to be an http or https address."
        end

        text
      end

      def query_hash(query)
        return query if query.is_a?(Hash)

        self.class.parse_pairs(query)
      end

      def header_hash(headers)
        return headers if headers.is_a?(Hash)

        self.class.parse_headers(headers)
      end

      def bounded(value, low, high, fallback)
        number = Integer(value, exception: false) || fallback
        number.clamp(low, high)
      end
    end
  end
end
