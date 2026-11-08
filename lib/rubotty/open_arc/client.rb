# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Rubotty
  module OpenArc
    # The common bounded chat-completions surface used by local text features.
    # Callers choose their own prompt and run it outside inbound message work.
    # Every one of them comes through #complete, which is why a call has to
    # name the feature it is for and the community it belongs to: a call that
    # cannot name them is one whose cost nothing could attribute.
    class Client
      # +permanent+ marks a failure a second attempt cannot change: the server
      # refused this request on its own merits rather than faulting. Anything
      # that reads it duck-types the predicate, so no caller has to know this
      # class to decide whether retrying is worth a round trip.
      class Error < Rubotty::Error
        def initialize(message = nil, permanent: false, model_unloaded: false)
          @permanent = permanent
          @model_unloaded = model_unloaded
          super(message)
        end

        def permanent? = @permanent

        # The one refusal worth answering rather than only reporting: the
        # server is up and simply is not holding the model the completion
        # named, which is something that can be put right and the question
        # then asked again. Duck-typed like #permanent?, so a caller deciding
        # what to do with a failure still needs no constant from here.
        def model_unloaded? = @model_unloaded
      end

      OPEN_TIMEOUT = 5
      READ_TIMEOUT = 120
      # A listing is a cheap read that the Integrations page waits on while it
      # draws, so it gets its own ceiling well under a completion's.
      LIST_READ_TIMEOUT = 10
      # Registering and loading a model is real work on the server, not a
      # chat turn, so it gets a ceiling generous enough for a large one.
      LOAD_READ_TIMEOUT = 900

      # What OpenArc answers when it is not holding the model a completion
      # named. It refuses with a 4xx like any other bad request, so the
      # server's own sentence is the only thing marking this apart from the
      # refusals that really are final. Matching words is the price of the
      # server having no code of its own for it.
      MODEL_UNLOADED = /is not loaded or no worker is available/i

      # How long a failed reload is left alone. A server that could not load a
      # model a moment ago will load it no better for a queue of jobs each
      # spending LOAD_READ_TIMEOUT finding that out, and every one of those is
      # a room waiting; a try a minute still catches the moment it can again.
      RELOAD_COOLDOWN = 60

      # The lowest temperature this deployment's model worker is known to run.
      # At zero the configured worker refuses the call outright and then
      # stops answering for every feature sharing it, so a caller that wants
      # as little sampling variety as it can get asks for this and not less.
      # {ContentPolicy::Service::DECISION_TEMPERATURE} is set to exactly this.
      LOWEST_WORKING_TEMPERATURE = 0.01

      # How much of a refused response's own body travels in the error message:
      # enough for the server's reason, short of pasting a page into a log line.
      FAILURE_DETAIL_LIMIT = 300

      # openarc/load's model_type, a closed set the server itself enforces.
      MODEL_TYPES = %w[llm vlm whisper qwen3_asr kokoro qwen3_tts_custom_voice
                       qwen3_tts_voice_design qwen3_tts_voice_clone emb rerank].freeze
      # openarc/load's engine, the other closed set.
      ENGINES = %w[optimum ovgenai openvino].freeze

      # One answer, and the two things about it worth counting beyond its text:
      # what the server stopped on, and how much it generated getting there.
      Answer = Struct.new(:text, :finish_reason, :completion_tokens, keyword_init: true) do
        # Stopped on the budget rather than on itself, which is the shape a
        # derived budget set too low produces.
        def truncated? = finish_reason.to_s == "length"
      end

      # Putting a model back is work on one shared server, and every feature
      # builds a client of its own, so the guard against several of them doing
      # it at once cannot live on an instance.
      @reload_lock = Mutex.new
      @reload_failed_at = nil

      class << self
        # Runs the block with one caller inside at a time. A reload that failed
        # less than {RELOAD_COOLDOWN} ago stops the block running at all, since
        # the answer would be the same and the wait would not be. A block that
        # reports success clears that cooldown for everyone.
        #
        # @yieldreturn [Boolean] whether the model is loaded now
        # @return [Boolean]
        def reloading
          @reload_lock.synchronize do
            return false if cooling_down?

            loaded = yield
            @reload_failed_at = loaded ? nil : now
            loaded
          end
        end

        private

        def cooling_down?
          return false if @reload_failed_at.nil?

          now - @reload_failed_at < RELOAD_COOLDOWN
        end

        def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # @param settings [Settings]
      # @param stats [ControlPlane::ModelCallStats, nil] where each call's own
      #   numbers go. Nil records nothing, which is what a spec or a one-off
      #   connection test wants.
      # @param logger [Logger, nil] where a model going missing and coming
      #   back is written down. Nil says nothing, which is what a spec wants.
      # @param http [#call, nil] receives (uri, body, headers) in specs
      # @param http_get [#call, nil] receives (uri, headers) in specs
      def initialize(settings:, stats: nil, logger: nil, http: nil, http_get: nil)
        @settings = settings
        @stats = stats
        @logger = logger
        @http = http
        @http_get = http_get
      end

      # The text alone, which is all most callers want. One that has to tell an
      # answer cut off at its budget from a whole one it could not read asks for
      # the {Answer} instead, since the two are the same string to a reader.
      def complete(**) = complete_answer(**).text

      # @param max_tokens [Integer] bounded completion length
      # @param feature [String] one of ControlPlane::ModelCallStats::FEATURES
      # @param community_id [Integer] the community whose budget this spends
      # @param temperature [Numeric] sampling temperature, above zero
      # @param retried [Boolean] a second ask at the same question
      # @param options [Hash] extra request fields, merged last; a deployment
      #   rejecting an unknown one answers 4xx, so pass with a retry in hand
      # @return [Answer]
      def complete_answer(messages:, max_tokens:, feature:, community_id:, temperature: 0.2,
                          options: {}, retried: false)
        raise Error, "OpenArc is not configured" unless @settings.configured?
        unless temperature.to_f.positive?
          raise Error, "temperature has to be above zero (#{LOWEST_WORKING_TEMPERATURE} is the " \
                       "lowest this deployment is known to run); at zero the worker stops " \
                       "answering for every feature, not only this call"
        end

        body = {
          model: @settings.model, temperature: temperature, max_tokens: max_tokens,
          stream: false, messages: Array(messages)
        }
        payload = JSON.generate(body.merge(options))
        ask = lambda do |again|
          measured(feature: feature, community_id: community_id, budget: max_tokens, retried: again) do
            completion_from(post(endpoint_for("chat/completions"), payload))
          end
        end

        begin
          ask.call(retried)
        rescue Error => e
          # The server is there and has simply not got the model: put it back
          # and ask once more. Both attempts are counted, because both were
          # time a room spent waiting, and the second is marked a retry for the
          # same reason the thinking-option fallback marks its own.
          raise unless e.model_unloaded? && reload_model

          ask.call(true)
        end
      end

      # Every model the configured server has LOADED, by id, from the
      # /v1/models listing endpoint. A model registered on the server but
      # not currently loaded is absent, which is the right set for a choice that
      # has to be usable now; loading one is done on the server, not from here.
      #
      # @return [Array<String>] ids, in the order the server gave them
      # @raise [Error]
      def models
        raise Error, "OpenArc is not configured" unless @settings.configured?

        response = get(endpoint_for("models"))
        code = response.code.to_i
        raise failure(code, response) unless code.between?(200, 299)

        payload = JSON.parse(response.body.to_s)
        entries = payload.is_a?(Hash) ? payload["data"] : payload
        Array(entries).filter_map { |entry| model_id(entry) }.uniq
      rescue JSON::ParserError => e
        raise Error, "OpenArc answered with invalid JSON: #{e.message}"
      end

      # Whether the chosen model is among what the server is holding now.
      #
      # @raise [Error] when the listing itself cannot be read
      def loaded? = models.include?(@settings.model)

      # A read-only endpoint check for the Integrations page, over the same
      # listing. A server that answers with nothing loaded is reachable and
      # still unusable, which is worth saying rather than passing.
      #
      # @return [Array<String>] the ids the listing named
      def test_connection = models

      # Registers and loads a model on the configured server in one call,
      # OpenArc's own interface for putting something new there rather than
      # choosing among what is already loaded. Slow, and can fail for reasons
      # only the server knows; model_type and engine are checked against the
      # server's own closed sets first, so a typo fails at once.
      #
      # @param model_path [String] a path meaningful only on the OpenArc host
      # @return [String] the server's own response body
      def load_model(model_path:, model_name:, model_type:, engine:, device:, cache_dir: nil)
        raise Error, "OpenArc is not configured" unless @settings.configured?

        required = { model_path: model_path, model_name: model_name, model_type: model_type,
                     engine: engine, device: device }
        missing = required.select { |_, value| blank?(value) }.keys
        raise Error, "#{missing.join(", ")} #{missing.one? ? "is" : "are"} required" if missing.any?
        raise Error, "model_type has to be one of: #{MODEL_TYPES.join(", ")}" unless MODEL_TYPES.include?(model_type)
        raise Error, "engine has to be one of: #{ENGINES.join(", ")}" unless ENGINES.include?(engine)

        body = required.merge(cache_dir: blank?(cache_dir) ? nil : cache_dir).compact
        response = post(management_endpoint_for("load"), JSON.generate(body), read_timeout: LOAD_READ_TIMEOUT)
        code = response.code.to_i
        raise failure(code, response) unless code.between?(200, 299)

        response.body.to_s
      end

      # Puts {Settings#model} back after a completion has found it missing, and
      # says whether it is there now. Nothing here decides a model OUGHT to be
      # reloaded: OpenArc has already said it is gone, which is the only thing
      # that starts this. A deployment that kept no recipe answers false, which
      # leaves the original failure to travel as it did before this existed.
      #
      # @return [Boolean] whether the model is loaded now
      def reload_model
        spec = @settings.reload_spec
        unless spec
          @logger&.debug { "OpenArc: #{@settings.model} is not loaded and no reload recipe is stored" }
          return false
        end

        self.class.reloading do
          # Four features share one server, so by the time this caller holds
          # the lock another may have done the work already. A listing costs a
          # fraction of a load, so it is worth asking before repeating one.
          if loaded?
            true
          else
            @logger&.warn { "OpenArc: #{@settings.model} is not loaded; loading #{spec["model_path"]}" }
            load_model(**spec.transform_keys(&:to_sym))
            @logger&.info { "OpenArc: #{@settings.model} is loaded again" }
            true
          end
        rescue Error => e
          @logger&.error { "OpenArc: could not put #{@settings.model} back: #{e.message}" }
          false
        end
      end

      # The richer read alongside #models: per loaded entry, the server's own
      # model_name, model_type, engine and device, so a page can show what is
      # loaded on which device rather than only a flat list of ids.
      #
      # @return [Array<Hash>] each entry as the server reported it
      # @raise [Error]
      def status
        raise Error, "OpenArc is not configured" unless @settings.configured?

        response = get(management_endpoint_for("status"))
        code = response.code.to_i
        raise failure(code, response) unless code.between?(200, 299)

        payload = JSON.parse(response.body.to_s)
        entries = payload.is_a?(Hash) ? payload["data"] : payload
        Array(entries).select { |entry| entry.is_a?(Hash) }
      rescue JSON::ParserError => e
        raise Error, "OpenArc answered with invalid JSON: #{e.message}"
      end

      private

      def endpoint_for(path)
        uri = URI.parse(@settings.url.to_s)
        raise URI::InvalidURIError, "an http or https URL is required" unless uri.is_a?(URI::HTTP) && uri.host

        base_path = uri.path.to_s.sub(%r{/+\z}, "")
        base_path = "#{base_path}/v1" unless base_path.end_with?("/v1")
        uri.path = "#{base_path}/#{path}"
        uri
      rescue URI::Error, ArgumentError => e
        raise Error, "OpenArc URL is invalid: #{e.message}"
      end

      # openarc/load and openarc/status sit beside the completion API's /v1
      # surface, not under it, so a stored /v1 suffix is stripped rather than
      # carried along.
      def management_endpoint_for(path)
        uri = URI.parse(@settings.url.to_s)
        raise URI::InvalidURIError, "an http or https URL is required" unless uri.is_a?(URI::HTTP) && uri.host

        base_path = uri.path.to_s.sub(%r{/+\z}, "").sub(%r{/v1\z}, "")
        uri.path = "#{base_path}/openarc/#{path}"
        uri
      rescue URI::Error, ArgumentError => e
        raise Error, "OpenArc URL is invalid: #{e.message}"
      end

      def post(uri, body, read_timeout: READ_TIMEOUT)
        return @http.call(uri, body, headers) if @http

        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                            open_timeout: OPEN_TIMEOUT, read_timeout: read_timeout) do |http|
          request = Net::HTTP::Post.new(uri)
          headers.each { |name, value| request[name] = value }
          request.body = body
          http.request(request)
        end
      rescue Error
        raise
      rescue StandardError => e
        raise Error, "could not reach OpenArc: #{e.class}: #{e.message}"
      end

      # One listed entry's id, for either shape a server may answer in: the
      # listing object with an "id", or a bare string.
      def model_id(entry)
        id = entry.is_a?(Hash) ? entry["id"] : entry
        text = id.to_s.strip
        text.empty? ? nil : text
      end

      def get(uri)
        return @http_get.call(uri, headers) if @http_get

        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                            open_timeout: OPEN_TIMEOUT, read_timeout: LIST_READ_TIMEOUT) do |http|
          request = Net::HTTP::Get.new(uri)
          headers.each { |name, value| request[name] = value }
          http.request(request)
        end
      rescue Error
        raise
      rescue StandardError => e
        raise Error, "could not reach OpenArc: #{e.class}: #{e.message}"
      end

      def headers
        values = { "Content-Type" => "application/json", "Accept" => "application/json" }
        values["Authorization"] = "Bearer #{@settings.api_key}" if @settings.api_key
        values
      end

      def blank?(value) = value.to_s.strip.empty?

      # A short one-line excerpt of a refused response's own body. That
      # sentence is usually the whole diagnosis ("Model 'X' is not loaded or no
      # worker is available", a bad path, a device the server does not have),
      # and without it a status code alone reaches the log and nothing else.
      def failure_detail(response)
        detail = response.body.to_s.strip.gsub(/\s+/, " ")
        return "" if detail.empty?
        return ": #{detail}" if detail.length <= FAILURE_DETAIL_LIMIT

        ": #{detail[0, FAILURE_DETAIL_LIMIT]}..."
      end

      # A model not loaded, or loaded with every worker busy, answers 400. It
      # reads like a refusal and is not one: the same request succeeds once the
      # model is back, so classifying it with the rest of the 4xx spent the
      # whole ladder in one attempt and settled the job for good. Wider than
      # {MODEL_UNLOADED}, which every body matching it also matches: the narrow
      # sentence says a reload is worth attempting, this says only that the
      # server is not ready, which is enough to keep the ladder. Matching this
      # and not that retries without reloading a model nobody asked for.
      NOT_READY = /not loaded|no worker is available/i

      # A 4xx that is not a rate limit is the server refusing this request on
      # its own merits, so sending it again spends another round trip on the
      # same answer. Everything else may clear on its own and keeps its ladder.
      def refused?(code) = code.between?(400, 499) && code != 429

      # Whether the body says the server is not ready rather than unwilling.
      def not_ready?(response) = NOT_READY.match?(response.body.to_s)

      def failure(code, response)
        Error.new("OpenArc answered HTTP #{code}#{failure_detail(response)}",
                  permanent: refused?(code) && !not_ready?(response),
                  model_unloaded: MODEL_UNLOADED.match?(response.body.to_s))
      end

      # Time one attempt and record what it cost, whether it answered or not: a
      # failed attempt still spent the wait the room felt. Recording never
      # raises over the call it is measuring.
      def measured(feature:, community_id:, budget:, retried:)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        answer = yield
        observe(feature, community_id, started, budget, retried, answer)
        answer
      rescue StandardError
        observe(feature, community_id, started, budget, retried, nil)
        raise
      end

      def observe(feature, community_id, started, budget, retried, answer)
        return if @stats.nil?

        @stats.record(
          community_id: community_id, feature: feature, retried: retried, budget_tokens: budget,
          seconds: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started,
          failed: answer.nil?, used_tokens: answer&.completion_tokens, truncated: !!answer&.truncated?
        )
      rescue StandardError
        nil
      end

      def completion_from(response)
        code = response.code.to_i
        raise failure(code, response) unless code.between?(200, 299)

        data = JSON.parse(response.body.to_s)
        text = data.dig("choices", 0, "message", "content").to_s.strip
        raise Error, "OpenArc answered without completion text" if text.empty?

        Answer.new(text: text, finish_reason: data.dig("choices", 0, "finish_reason"),
                   completion_tokens: data.dig("usage", "completion_tokens").to_i)
      rescue JSON::ParserError => e
        raise Error, "OpenArc answered with invalid JSON: #{e.message}"
      end
    end
  end
end
