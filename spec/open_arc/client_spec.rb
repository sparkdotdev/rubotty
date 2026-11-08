# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::OpenArc::Client do
  class OpenArcFakeHttp
    Response = Struct.new(:code, :body)

    attr_reader :requests

    def initialize
      @requests = []
      @responses = []
    end

    def queue(code, body) = @responses << Response.new(code.to_s, body)

    def call(uri, body, headers)
      @requests << { uri: uri, body: body, headers: headers }
      @responses.shift || Response.new("200", '{"choices":[{"message":{"content":"Done."}}]}')
    end
  end

  class OpenArcFakeHttpGet
    Response = Struct.new(:code, :body)

    attr_reader :requests

    def initialize
      @requests = []
      @responses = []
    end

    def queue(code, body) = @responses << Response.new(code.to_s, body)

    def call(uri, headers)
      @requests << { uri: uri, headers: headers }
      @responses.shift || Response.new("200", '{"data":[]}')
    end
  end

  let(:http) { OpenArcFakeHttp.new }
  let(:http_get) { OpenArcFakeHttpGet.new }
  let(:store) { Struct.new(:url, :api_key).new("http://openarc.example:8000/v1", nil) }
  let(:settings) { Rubotty::OpenArc::Settings.new(store: store) }
  let(:client) { described_class.new(settings: settings, http: http, http_get: http_get) }

  # Every completion has to say what it is for and whose it is, so the spec
  # carries one pair rather than repeating it on each call.
  let(:attribution) { { feature: "content_policy", community_id: 7 } }

  it "falls back to the built-in model through the shared chat endpoint" do
    http.queue(200, '{"choices":[{"message":{"content":"The room agreed."}}]}')

    answer = client.complete(messages: [{ role: "user", content: "hello" }], max_tokens: 80, **attribution)

    expect(answer).to eq("The room agreed.")

    request = http.requests.first
    expect(request[:uri].to_s).to eq("http://openarc.example:8000/v1/chat/completions")
    expect(JSON.parse(request[:body])).to include(
      "model" => Rubotty::OpenArc::Settings::DEFAULT_MODEL, "stream" => false, "max_tokens" => 80
    )
  end

  # The point of storing the model at all: a deployment pointed at a server
  # carrying something else asks for what that server has.
  it "asks for the stored model once one has been chosen" do
    chosen = Struct.new(:url, :api_key, :model).new("http://openarc.example:8000/v1", nil, "second-test-model-int4")
    client = described_class.new(settings: Rubotty::OpenArc::Settings.new(store: chosen), http: http)

    client.complete(messages: [], max_tokens: 80, **attribution)

    expect(JSON.parse(http.requests.first[:body])["model"]).to eq("second-test-model-int4")
  end

  # A classifier wants the same verdict twice on one message and a summary
  # does not, so the caller decides and the shared default stays where the
  # generative callers left it.
  it "sends the caller's own temperature, and its own default when a caller has no opinion" do
    client.complete(messages: [], max_tokens: 80, **attribution,
                    temperature: Rubotty::ContentPolicy::Service::DECISION_TEMPERATURE)
    client.complete(messages: [], max_tokens: 80, **attribution)

    expect(JSON.parse(http.requests.first[:body])["temperature"]).to eq(0.01)
    expect(JSON.parse(http.requests.last[:body])["temperature"]).to eq(0.2)
  end

  # A caller that needs a chat-template field carries it itself, so the shared
  # body stays the same for every caller that does not.
  it "merges a caller's extra request fields and sends none by default" do
    http.queue(200, '{"choices":[{"message":{"content":"{}"}}]}')
    client.complete(messages: [{ role: "user", content: "hello" }], max_tokens: 80, **attribution,
                    options: { chat_template_kwargs: { enable_thinking: false } })
    client.complete(messages: [{ role: "user", content: "hello" }], max_tokens: 80, **attribution)

    expect(JSON.parse(http.requests.first[:body])).to include(
      "chat_template_kwargs" => { "enable_thinking" => false }
    )
    expect(JSON.parse(http.requests.last[:body])).not_to have_key("chat_template_kwargs")
  end

  it "sends the stored key as a bearer token" do
    store.api_key = "secret"

    client.complete(messages: [{ role: "user", content: "hello" }], max_tokens: 80, **attribution)

    expect(http.requests.first[:headers]["Authorization"]).to eq("Bearer secret")
  end

  it "checks the read-only models endpoint without sending text" do
    http_get.queue(200, '{"data":[{"id":"test-model-quantized"}]}')

    expect(client.test_connection).to eq(["test-model-quantized"])
    expect(http_get.requests.first[:uri].to_s).to eq("http://openarc.example:8000/v1/models")
    expect(http.requests).to be_empty
  end

  describe "#models" do
    it "lists what the server reports it has loaded, in the order it gave them" do
      http_get.queue(200, '{"data":[{"id":"test-model"},{"id":"second-test-model"},{"id":"test-model"}]}')

      expect(client.models).to eq(%w[test-model second-test-model])
    end

    # Not every completion server wraps its listing the same way, and a
    # bare array of ids costs one branch to accept.
    it "reads a bare array of ids as well as the wrapped object" do
      http_get.queue(200, '["test-model", "second-test-model"]')

      expect(client.models).to eq(%w[test-model second-test-model])
    end

    it "answers empty for a server that has nothing loaded" do
      http_get.queue(200, '{"data":[]}')

      expect(client.models).to eq([])
    end

    it "raises on a refused listing rather than reading it as no models" do
      http_get.queue(503, "upstream is down")

      expect { client.models }.to raise_error(described_class::Error, /HTTP 503/)
    end

    it "raises on a listing that is not JSON at all" do
      http_get.queue(200, "<html>proxy error</html>")

      expect { client.models }.to raise_error(described_class::Error, /invalid JSON/)
    end

    it "raises when nothing has been configured" do
      unconfigured = described_class.new(settings: Rubotty::OpenArc::Settings.new)

      expect { unconfigured.models }.to raise_error(described_class::Error, /not configured/)
    end
  end

  describe "#load_model" do
    it "registers and loads through openarc/load, beside v1 rather than under it" do
      http.queue(200, "loading")

      client.load_model(model_path: "/models/test-model", model_name: "test-model", model_type: "llm",
                        engine: "openvino", device: "CPU")

      request = http.requests.first
      expect(request[:uri].to_s).to eq("http://openarc.example:8000/openarc/load")
      expect(JSON.parse(request[:body])).to eq(
        "model_path" => "/models/test-model", "model_name" => "test-model", "model_type" => "llm",
        "engine" => "openvino", "device" => "CPU"
      )
    end

    it "carries an optional cache_dir when one is given" do
      http.queue(200, "loading")

      client.load_model(model_path: "/models/test-model", model_name: "test-model", model_type: "llm",
                        engine: "openvino", device: "CPU", cache_dir: "/cache")

      expect(JSON.parse(http.requests.first[:body])["cache_dir"]).to eq("/cache")
    end

    it "leaves cache_dir out of the request entirely when it is blank" do
      http.queue(200, "loading")

      client.load_model(model_path: "/models/test-model", model_name: "test-model", model_type: "llm",
                        engine: "openvino", device: "CPU", cache_dir: "  ")

      expect(JSON.parse(http.requests.first[:body])).not_to have_key("cache_dir")
    end

    it "rejects a model_type outside the server's closed set before sending anything" do
      expect do
        client.load_model(model_path: "/models/x", model_name: "x", model_type: "bogus",
                          engine: "openvino", device: "CPU")
      end.to raise_error(described_class::Error, /model_type has to be one of/)
      expect(http.requests).to be_empty
    end

    it "rejects an engine outside the server's closed set before sending anything" do
      expect do
        client.load_model(model_path: "/models/x", model_name: "x", model_type: "llm",
                          engine: "bogus", device: "CPU")
      end.to raise_error(described_class::Error, /engine has to be one of/)
      expect(http.requests).to be_empty
    end

    it "names every required field left blank" do
      expect do
        client.load_model(model_path: "", model_name: "x", model_type: "llm", engine: "openvino", device: "")
      end.to raise_error(described_class::Error, "model_path, device are required")
    end

    it "says 'is' rather than 'are' for exactly one missing field" do
      expect do
        client.load_model(model_path: "/x", model_name: "x", model_type: "llm", engine: "openvino", device: "")
      end.to raise_error(described_class::Error, "device is required")
    end

    it "raises on a refused load, carrying the server's own reason" do
      http.queue(422, '{"detail":"no such path"}')

      expect do
        client.load_model(model_path: "/models/x", model_name: "x", model_type: "llm",
                          engine: "openvino", device: "CPU")
      end.to raise_error(described_class::Error, /HTTP 422.*no such path/)
    end

    it "raises when nothing has been configured" do
      unconfigured = described_class.new(settings: Rubotty::OpenArc::Settings.new)

      expect do
        unconfigured.load_model(model_path: "/x", model_name: "x", model_type: "llm", engine: "openvino",
                                device: "CPU")
      end.to raise_error(described_class::Error, /not configured/)
    end
  end

  describe "#status" do
    it "reads what is loaded, richer than the bare model list" do
      http_get.queue(200,
                     '{"data":[{"model_name":"test-model","model_type":"llm","engine":"openvino","device":"CPU"}]}')

      expect(client.status).to eq(
        [{ "model_name" => "test-model", "model_type" => "llm", "engine" => "openvino", "device" => "CPU" }]
      )
      expect(http_get.requests.first[:uri].to_s).to eq("http://openarc.example:8000/openarc/status")
    end

    it "reads a bare array the same as a wrapped one" do
      http_get.queue(200, '[{"model_name":"test-model","model_type":"llm","engine":"openvino","device":"CPU"}]')

      expect(client.status.first["model_name"]).to eq("test-model")
    end

    it "answers empty for a server with nothing loaded" do
      http_get.queue(200, '{"data":[]}')

      expect(client.status).to eq([])
    end

    it "raises on a refused status read" do
      http_get.queue(503, "upstream is down")

      expect { client.status }.to raise_error(described_class::Error, /HTTP 503/)
    end

    it "raises when nothing has been configured" do
      unconfigured = described_class.new(settings: Rubotty::OpenArc::Settings.new)

      expect { unconfigured.status }.to raise_error(described_class::Error, /not configured/)
    end
  end

  it "raises when an integration has not been configured" do
    unconfigured = described_class.new(settings: Rubotty::OpenArc::Settings.new)

    expect { unconfigured.complete(messages: [], max_tokens: 80, **attribution) }
      .to raise_error(Rubotty::OpenArc::Client::Error, /not configured/)
  end

  it "raises on an unusable completion" do
    http.queue(200, '{"choices":[]}')

    expect { client.complete(messages: [], max_tokens: 80, **attribution) }
      .to raise_error(Rubotty::OpenArc::Client::Error, /without completion text/)
  end

  # A temperature of zero does not fail one call, it stops the shared worker
  # answering for every feature until somebody reloads the model by hand, so
  # the guard has to hold before anything leaves this process.
  describe "the temperature floor" do
    [0, 0.0, -1, "0"].each do |value|
      it "refuses #{value.inspect} without sending anything" do
        expect { client.complete(messages: [], max_tokens: 80, **attribution, temperature: value) }
          .to raise_error(described_class::Error, /temperature has to be above zero/)
        expect(http.requests).to be_empty
      end
    end

    it "names the value that does work, so nobody has to find it the hard way" do
      expect { client.complete(messages: [], max_tokens: 80, **attribution, temperature: 0) }
        .to raise_error(described_class::Error, /0\.01/)
    end

    it "sends the floor itself, which is what the content policy check asks for" do
      client.complete(messages: [], max_tokens: 80, **attribution,
                      temperature: described_class::LOWEST_WORKING_TEMPERATURE)

      expect(JSON.parse(http.requests.first[:body])["temperature"]).to eq(0.01)
    end

    # Written down in two places on purpose, and this is what keeps them equal.
    it "is the temperature the content policy check is set to" do
      expect(Rubotty::ContentPolicy::Service::DECISION_TEMPERATURE)
        .to eq(described_class::LOWEST_WORKING_TEMPERATURE)
    end
  end

  # A status code on its own identified nothing during the outage this comes
  # from: the server's body said the model was not loaded and only the code
  # reached the log.
  describe "what a refused completion says" do
    it "carries the server's own sentence into the error message" do
      http.queue(400, '{"detail":"Model \'other-test-model\' is not loaded or no worker is available"}')

      expect { client.complete(messages: [], max_tokens: 80, **attribution) }
        .to raise_error(described_class::Error, /HTTP 400.*is not loaded or no worker is available/)
    end

    it "flattens a multi-line body so one failure stays one log line" do
      http.queue(500, "Generation failed:\n  Check 'temperature > 0' failed\n")
      flattened = "OpenArc answered HTTP 500: Generation failed: Check 'temperature > 0' failed"

      expect { client.complete(messages: [], max_tokens: 80, **attribution) }
        .to raise_error(described_class::Error, flattened)
    end

    it "truncates a body too long to belong in a log line" do
      http.queue(400, "x" * 5000)

      expect { client.complete(messages: [], max_tokens: 80, **attribution) }
        .to raise_error(described_class::Error) { |e| expect(e.message.length).to be < 400 }
    end

    it "says nothing extra for a refusal that answered with an empty body" do
      http.queue(400, "")

      expect { client.complete(messages: [], max_tokens: 80, **attribution) }
        .to raise_error(described_class::Error, "OpenArc answered HTTP 400")
    end
  end

  # Whether a second attempt could ever answer differently, which is what
  # decides between failing now and spending a retry ladder on the far end.
  describe "which failures a retry could fix" do
    { 400 => true, 404 => true, 422 => true, 429 => false, 500 => false, 503 => false }.each do |code, permanent|
      it "treats HTTP #{code} as #{permanent ? 'permanent' : 'worth another attempt'}" do
        http.queue(code, "no")

        expect { client.complete(messages: [], max_tokens: 80, **attribution) }
          .to raise_error(described_class::Error) { |e| expect(e.permanent?).to eq(permanent) }
      end
    end

    # OpenArc answers 400 while a model is loading or every worker is busy: it
    # reads like a refusal and is not one. Classified with the rest of the 4xx
    # it settled the job on its first attempt, so every check made during one
    # reload was dropped and never seen again, even once the model returned.
    [
      %({"detail":"Model 'other-test-model' is not loaded or no worker is available"}),
      %({"detail":"no worker is available"})
    ].each do |body|
      it "keeps the ladder for a 400 saying #{body[/not loaded|no worker is available/]}" do
        http.queue(400, body)

        expect { client.complete(messages: [], max_tokens: 80, **attribution) }
          .to raise_error(described_class::Error) { |e| expect(e.permanent?).to be(false) }
      end
    end

    it "still settles a 400 that refuses the request on its merits" do
      http.queue(400, %({"detail":"max_tokens must be a positive integer"}))

      expect { client.complete(messages: [], max_tokens: 80, **attribution) }
        .to raise_error(described_class::Error) { |e| expect(e.permanent?).to be(true) }
    end

    it "keeps a connection with nothing configured on the ladder, since no server refused anything" do
      unconfigured = described_class.new(settings: Rubotty::OpenArc::Settings.new)

      expect { unconfigured.complete(messages: [], max_tokens: 80, **attribution) }
        .to raise_error(described_class::Error) { |e| expect(e.permanent?).to be(false) }
    end
  end

  # This is the one place every model-backed feature goes through, so it is
  # where a call's cost is measured rather than in four copies of the same
  # timing code.
  describe "what it records" do
    class RecordingStats
      attr_reader :calls

      def initialize(raising: false)
        @calls = []
        @raising = raising
      end

      def record(**call)
        raise "the rollup is down" if @raising

        @calls << call
        true
      end
    end

    let(:recorder) { RecordingStats.new }
    let(:client) { described_class.new(settings: settings, stats: recorder, http: http) }

    it "attributes a call to the feature and the community that asked for it" do
      client.complete(messages: [], max_tokens: 80, **attribution)

      expect(recorder.calls.first).to include(feature: "content_policy", community_id: 7, failed: false)
    end

    it "keeps the budget beside what the server said it generated" do
      http.queue(200, '{"choices":[{"message":{"content":"ok"}}],"usage":{"completion_tokens":41}}')

      client.complete(messages: [], max_tokens: 80, **attribution)

      expect(recorder.calls.first).to include(budget_tokens: 80, used_tokens: 41)
    end

    it "notices an answer that stopped on the budget rather than on itself" do
      http.queue(200, '{"choices":[{"message":{"content":"ok"},"finish_reason":"length"}]}')

      client.complete(messages: [], max_tokens: 80, **attribution)

      expect(recorder.calls.first).to include(truncated: true)
    end

    it "reads an ordinary answer as untruncated" do
      http.queue(200, '{"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}]}')

      client.complete(messages: [], max_tokens: 80, **attribution)

      expect(recorder.calls.first).to include(truncated: false)
    end

    # A failed attempt still spent the wait, so it is timed like any other and
    # the error goes on to the caller untouched.
    it "records a failure and still raises it" do
      http.queue(500, "nope")

      expect { client.complete(messages: [], max_tokens: 80, **attribution) }
        .to raise_error(Rubotty::OpenArc::Client::Error)
      expect(recorder.calls.first).to include(failed: true, feature: "content_policy")
    end

    it "marks a second ask at the same question as a retry" do
      client.complete(messages: [], max_tokens: 80, **attribution, retried: true)

      expect(recorder.calls.first).to include(retried: true)
    end

    it "times every call, so nothing lands without a wait to file" do
      client.complete(messages: [], max_tokens: 80, **attribution)

      expect(recorder.calls.first[:seconds]).to be_a(Float).and be >= 0
    end

    it "never lets a broken rollup take down the call it was measuring" do
      failing = described_class.new(settings: settings, stats: RecordingStats.new(raising: true), http: http)

      expect(failing.complete(messages: [], max_tokens: 80, **attribution)).to eq("Done.")
    end

    it "records nothing at all without a rollup to record into" do
      plain = described_class.new(settings: settings, http: http)

      expect(plain.complete(messages: [], max_tokens: 80, **attribution)).to eq("Done.")
      expect(recorder.calls).to be_empty
    end
  end
  describe "putting a dropped model back" do
    # What OpenArc answers a completion with when it is not holding the model:
    # a 400 whose body carries the only words that say so.
    let(:missing) { %q({"detail":"Model 'other-test-model' is not loaded or no worker is available"}) }
    let(:recipe) do
      { "model_path" => "/models/other-test-model-int4_sym-ov", "model_name" => "other-test-model",
        "model_type" => "llm", "engine" => "ovgenai", "device" => "GPU" }
    end
    # The shared store above deliberately carries no recipe, since most of this
    # file is about a deployment that has never kept one.
    let(:keeping_store) do
      Struct.new(:url, :api_key, :model, :reload_spec)
            .new("http://openarc.example:8000/v1", nil, "other-test-model", recipe)
    end
    let(:keeping_client) do
      described_class.new(settings: Rubotty::OpenArc::Settings.new(store: keeping_store),
                          http: http, http_get: http_get)
    end

    # The cooldown that stops a failed reload being tried again at once lives
    # on the class, so it outlives an example unless it is put back.
    before { described_class.instance_variable_set(:@reload_failed_at, nil) }

    it "loads the model again and asks a second time" do
      http.queue(400, missing)
      http_get.queue(200, %q({"data":[]}))
      http.queue(200, %q({"status":"loaded"}))
      http.queue(200, %q({"choices":[{"message":{"content":"It answered."}}]}))

      answer = keeping_client.complete(messages: [], max_tokens: 80, **attribution)

      expect(answer).to eq("It answered.")
      expect(http.requests[1][:uri].to_s).to eq("http://openarc.example:8000/openarc/load")
      expect(JSON.parse(http.requests[1][:body])).to eq(recipe)
    end

    it "leaves the failure alone when no recipe has been kept" do
      http.queue(400, missing)

      expect { client.complete(messages: [], max_tokens: 80, **attribution) }
        .to raise_error(described_class::Error, /not loaded/)
      expect(http.requests.length).to eq(1)
    end

    it "leaves a recipe naming another model alone" do
      keeping_store.reload_spec = recipe.merge("model_name" => "second-test-model")
      http.queue(400, missing)

      expect { keeping_client.complete(messages: [], max_tokens: 80, **attribution) }
        .to raise_error(described_class::Error, /not loaded/)
      expect(http.requests.length).to eq(1)
    end

    # Every other 4xx really is final, and spending a load on one would buy the
    # same answer twice.
    it "does not reload for a refusal that is not about a missing model" do
      http.queue(400, %q({"detail":"max_tokens must be positive"}))

      expect { keeping_client.complete(messages: [], max_tokens: 80, **attribution) }
        .to raise_error(described_class::Error, /max_tokens/)
      expect(http.requests.length).to eq(1)
    end

    it "asks the listing first, and skips a load another caller has already done" do
      http.queue(400, missing)
      http_get.queue(200, %q({"data":[{"id":"other-test-model"}]}))
      http.queue(200, %q({"choices":[{"message":{"content":"Back already."}}]}))

      answer = keeping_client.complete(messages: [], max_tokens: 80, **attribution)

      expect(answer).to eq("Back already.")
      expect(http.requests.map { |request| request[:uri].path }).to eq(["/v1/chat/completions"] * 2)
    end

    it "does not try a second load while a failed one is still cooling off" do
      http.queue(400, missing)
      http_get.queue(200, %q({"data":[]}))
      http.queue(500, "no room on the card")
      expect { keeping_client.complete(messages: [], max_tokens: 80, **attribution) }
        .to raise_error(described_class::Error, /not loaded/)

      http.queue(400, missing)
      expect { keeping_client.complete(messages: [], max_tokens: 80, **attribution) }
        .to raise_error(described_class::Error, /not loaded/)

      expect(http.requests.count { |request| request[:uri].path == "/openarc/load" }).to eq(1)
    end

    it "counts both attempts, and marks the second a retry" do
      recorder = RecordingStats.new
      counting = described_class.new(settings: Rubotty::OpenArc::Settings.new(store: keeping_store),
                                     stats: recorder, http: http, http_get: http_get)
      http.queue(400, missing)
      http_get.queue(200, %q({"data":[]}))
      http.queue(200, %q({"status":"loaded"}))
      http.queue(200, %q({"choices":[{"message":{"content":"Second time."}}]}))

      counting.complete(messages: [], max_tokens: 80, **attribution)

      expect(recorder.calls.map { |call| call.values_at(:failed, :retried) }).to eq([[true, false], [false, true]])
    end
  end
end
