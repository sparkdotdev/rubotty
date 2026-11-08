# frozen_string_literal: true

require "net/http"
require "yamlcamel"
require "uri"
require "timeout"

module Rubotty
  module Scripting
    # Outbound HTTP for scripts, by name: a script calls
    # rubotty.async_http{endpoint = "weather"} and never learns the URL or the
    # key. A script can only name what an administrator listed; parameters
    # are encoded, the resolved host re-checked, and any host resolving to a
    # private address refused. Every call is fire and forget, since a
    # processor runs before the bridge and a blocking call would be time
    # nobody sees the message.
    class Endpoints
      class Refused < Scripting::Error; end

      # Enough for an answer from a real API, small enough that a hostile
      # endpoint cannot use the pipe as a memory amplifier.
      MAX_BYTES = 1024 * 1024
      DEFAULT_WORKERS = 4
      DEFAULT_QUEUE_SIZE = 32
      MAX_WORKERS = 16
      MAX_QUEUE_SIZE = 128

      METHODS = %w[GET POST].freeze

      # YAML only, the same as every other wire in this project. application/yaml
      # is the registered media type (RFC 9512); the legacy ones are accepted on
      # READ, but rubotty always sends the registered one.
      YAML_TYPE = "application/yaml"
      LEGACY_YAML_TYPES = %w[text/yaml application/x-yaml text/x-yaml].freeze
      YAML_TYPES = ([YAML_TYPE] + LEGACY_YAML_TYPES).freeze

      # What one response amounted to once it had been read under the cap. Held
      # apart from Net::HTTPResponse so nothing downstream can reach for a body
      # that was deliberately not buffered.
      Captured = Struct.new(:status, :content_type, :body, keyword_init: true)

      Response = Struct.new(:status, :ok, :body, :data, :format, keyword_init: true) do
        # What Lua actually receives. `data` is the decoded document when the
        # endpoint sent YAML, and absent when it sent anything else.
        def to_lua
          { "status" => status, "ok" => ok, "body" => body, "data" => data, "format" => format }.compact
        end
      end

      def initialize(models:, logger: nil, http: nil, resolver: nil, executor: nil,
                     workers: DEFAULT_WORKERS, queue_size: DEFAULT_QUEUE_SIZE, clock: nil)
        @models = models
        @logger = logger
        @http = http
        @resolver = resolver
        @executor = executor
        @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        @worker_limit = Integer(workers).clamp(1, MAX_WORKERS)
        @queue_limit = Integer(queue_size).clamp(1, MAX_QUEUE_SIZE)
        @pending = []
        @workers = []
        @work_lock = Mutex.new
        @work_ready = ConditionVariable.new
        @closed = false
      end

      def find(community, name)
        @models.script_endpoint
               .where(community_id: community.id, name: name.to_s, enabled: true)
               .first
      end

      def names(community)
        @models.script_endpoint.where(community_id: community.id, enabled: true).select_map(:name)
      end

      # Fire and forget, so a slow endpoint cannot eat a script's budget. +body+
      # is what a POST sends, separate from +params+, which fills the URL and
      # the query. A closed or full queue refuses admission; only an accepted
      # call runs its runner and any then_call callback.
      def enqueue(community, name, params = {}, body: nil, &runner)
        row = find(community, name)
        raise Refused, "no endpoint called #{name.to_s.inspect}" if row.nil?

        deadline = @clock.call + request_timeout(row)
        job = -> { perform(row, params, body: body, deadline: deadline) }
        work = -> { runner ? runner.call(job) : job.call }
        if @executor
          @work_lock.synchronize { raise Refused, "endpoint workers are closed" if @closed }
          @executor.call(work)
        else
          submit(work)
        end
        true
      end

      # Pending fire-and-forget calls are abandoned at shutdown, like the room's
      # other transient work. Active calls get a short grace before cancellation;
      # no callback may keep running against adapters after runtime shutdown.
      def close(timeout: 1)
        workers = @work_lock.synchronize do
          @closed = true
          @pending.clear
          @work_ready.broadcast
          @workers.dup
        end
        deadline = @clock.call + timeout
        workers.reject { |worker| worker == Thread.current }.each do |worker|
          left = deadline - @clock.call
          worker.join(left) if left.positive?
          if worker.alive?
            worker.kill
            worker.join(0.1)
          end
        end
        nil
      end

      private

      def submit(work)
        @work_lock.synchronize do
          raise Refused, "endpoint workers are closed" if @closed
          raise Refused, "every endpoint worker and queue slot is busy" if @pending.length >= @queue_limit

          @pending << work
          if @workers.empty?
            @workers = Array.new(@worker_limit) do |index|
              Thread.new do
                Thread.current.name = "script-endpoint-#{index + 1}"
                work_loop
              end
            end
          end
          @work_ready.signal
        end
      end

      def work_loop
        loop do
          work = @work_lock.synchronize do
            @work_ready.wait(@work_lock) while @pending.empty? && !@closed
            @closed ? nil : @pending.shift
          end
          break if work.nil?

          safely(&work)
        end
      end

      def safely
        yield
      rescue StandardError => e
        @logger&.warn { "scripting: endpoint call failed: #{e.class}: #{e.message}" }
      end

      def perform(row, params, body: nil, deadline: nil)
        deadline ||= @clock.call + request_timeout(row)
        ::Timeout.timeout(remaining_seconds(deadline)) do
          uri = resolve_uri(row, params)
          fetcher = Util::MediaFetcher.new(limit: MAX_BYTES, logger: @logger,
                                           http: @http, resolver: @resolver)
          # Carry the validated address into the connection rather than letting
          # the host resolve again after its public-address check.
          addresses = fetcher.send(:guard_public_address!, uri)
          raw = request(uri, row, params, body: body, addresses: addresses, deadline: deadline)
          response = decode(raw)
          remaining_seconds(deadline)
          response
        end
      rescue ::Timeout::Error
        raise Refused, "the endpoint exceeded its time limit"
      rescue Util::MediaFetcher::Error => e
        raise Refused, e.message
      end

      # Try each validated address until one answers, so an endpoint whose host
      # has an address family this deployment cannot route still gets called.
      def request(uri, row, params = {}, body: nil, addresses: [], deadline: nil)
        last = nil
        Array(addresses).each do |address|
          return attempt(uri, row, params, body: body, address: address, deadline: deadline)
        rescue *Util::MediaFetcher::UNREACHABLE_ERRORS => e
          last = e
        rescue Refused
          raise
        rescue StandardError => e
          raise Refused, "the endpoint did not answer: #{e.class}"
        end

        raise Refused, "the endpoint did not answer: #{last ? last.class : "no address to try"}"
      end

      def attempt(uri, row, params, body: nil, address: nil, deadline: nil)
        # Bounded by the endpoint's own timeout, but no longer than the fetcher's
        # open timeout, so an unreachable address costs one moment per candidate.
        timeout = deadline ? remaining_seconds(deadline) : request_timeout(row)
        http = Util::MediaFetcher.pinned_http(
          uri, address,
          open_timeout: [timeout, Util::MediaFetcher::OPEN_TIMEOUT].min, read_timeout: timeout
        )

        message = build_request(uri, row, params, body: body)
        completed = Object.new
        catch(completed) do
          http.request(message) do |response|
            capture = ->(bytes) do
              Captured.new(status: response.code.to_i,
                           content_type: response["content-type"].to_s.downcase, body: bytes)
            end
            bytes = capped_body(response, deadline: deadline) { |prefix| throw completed, capture.call(prefix) }
            throw completed, capture.call(bytes)
          end
        end
      end

      # Read the body as it arrives and stop at the cap, rather than reading
      # raw.body first. Escaping the enclosing request when the cap is reached
      # matters too: Net::HTTP otherwise drains the unread body into memory.
      def capped_body(response, deadline: nil)
        buffer = +"".b
        response.read_body do |chunk|
          remaining_seconds(deadline) if deadline
          buffer << chunk.byteslice(0, MAX_BYTES - buffer.bytesize)
          if buffer.bytesize >= MAX_BYTES
            return yield(buffer) if block_given?

            break
          end
        end
        buffer
      end

      def request_timeout(row)
        (Integer(row.timeout_seconds, exception: false) || 2).clamp(1, ControlPlane::ScriptEndpoints::MAX_TIMEOUT)
      end

      def remaining_seconds(deadline)
        left = deadline - @clock.call
        raise Refused, "the endpoint exceeded its time limit" unless left.positive?

        left
      end

      # A POST carries the script's params as YAML, which is what rubotty's own
      # API accepts. An endpoint's own headers are applied last and win, so an
      # administrator can override any of this for a service with other ideas.
      def build_request(uri, row, params = {}, body: nil)
        post = row.http_method.to_s.upcase == "POST"
        request = (post ? Net::HTTP::Post : Net::HTTP::Get).new(uri)
        if post
          request["Content-Type"] = YAML_TYPE
          request["Accept"] = YAML_TYPE
          request.body = request_body(row, params, body)
        else
          request["Accept"] = YAML_TYPE
        end
        headers(row).each { |key, value| request[key.to_s] = value.to_s }
        request
      end

      # The table the script passed, as YAML: Ruby writes the document, so a
      # value carrying a colon or newline cannot reshape it. A script that
      # passed only query parameters and no body sends those.
      def request_body(_row, params, body = nil)
        return YAMLCamel.dump(stringify(body)) unless body.nil?

        YAMLCamel.dump(stringify(params))
      end

      def stringify(params)
        return {} unless params.is_a?(Hash)

        params.each_with_object({}) { |(key, value), out| out[key.to_s] = value }
      end

      # Headers are the endpoint's, never the script's, which is what keeps an
      # API key out of Lua and out of anything a script could print.
      def headers(row)
        parsed = row.json_value(:headers)
        parsed.is_a?(Hash) ? parsed : {}
      rescue StandardError
        {}
      end

      def decode(raw)
        return Response.new(status: 0, ok: false, body: "", data: nil, format: "text") if raw.nil?

        data, format = decode_body(raw.body, raw.content_type)
        Response.new(status: raw.status, ok: raw.status.between?(200, 299), body: raw.body,
                     data: data, format: format)
      end

      # A YAML document can name a Ruby class to instantiate, which would let
      # whoever answers as this endpoint run code in the bot: no permitted
      # classes, and aliases off so a few lines cannot expand into gigabytes.
      # Anything else comes back as text with no data, JSON included.
      def decode_body(body, type)
        return [nil, "text"] unless YAML_TYPES.any? { |candidate| type.include?(candidate) }

        [safe_yaml(body), "yaml"]
      end

      def safe_yaml(body)
        YAMLCamel.load(body)
      rescue StandardError
        nil
      end

      # Substitute {placeholders}, then check against the host the administrator
      # configured: a parameter that can change where the request goes is the
      # same as no whitelist at all.
      def resolve_uri(row, params)
        template = row.url.to_s
        declared = URI.parse(template.gsub(/\{[^}]*\}/, "x"))
        filled = fill(template, params)

        uri = URI.parse(filled)
        # The query an administrator configured, merged on top of anything
        # already in the URL, so a placeholder works in either place.
        uri = with_configured_query(uri, row, params)
        raise Refused, "an endpoint has to be http or https" unless uri.is_a?(URI::HTTP)
        raise Refused, "a parameter tried to change the host" unless uri.host == declared.host

        uri
      rescue URI::InvalidURIError
        raise Refused, "that endpoint's url could not be read"
      end

      def lookup(params, key)
        return "" unless params.is_a?(Hash)

        (params[key.to_s] || params[key.to_sym]).to_s
      end

      # Substitute every {placeholder} from what the script passed, encoded, so a
      # value carrying an ampersand or a slash cannot escape its field.
      def fill(template, params)
        template.to_s.gsub(/\{([^}]*)\}/) do
          URI.encode_www_form_component(lookup(params, Regexp.last_match(1)))
        end
      end

      # The same substitution, unencoded, for a value that is not going into a
      # URL path.
      def fill_plain(template, params)
        template.to_s.gsub(/\{([^}]*)\}/) { lookup(params, Regexp.last_match(1)) }
      end

      def with_configured_query(uri, row, params)
        configured = decode_template(row.respond_to?(:query_params) ? row.query_params : nil)
        return uri if configured.empty?

        existing = URI.decode_www_form(uri.query.to_s)
        added = configured.map { |name, value| [name.to_s, fill_plain(value, params)] }
        uri.query = URI.encode_www_form(existing + added)
        uri
      end

      def decode_template(raw)
        return {} if raw.nil?
        return raw if raw.is_a?(Hash)

        decoded = JSON.parse(raw.to_s)
        decoded.is_a?(Hash) ? decoded : {}
      rescue StandardError
        {}
      end

    end
  end
end
