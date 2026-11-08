# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Translation::Client do
  # A stand in for the network: receives (uri, body) and returns whatever was
  # queued, so no test here ever opens a socket.
  class TranslationFakeHttp
    Response = Struct.new(:code, :body)

    def initialize
      @queue = []
      @requests = []
    end

    attr_reader :requests

    def queue(code, body) = @queue << Response.new(code.to_s, body)

    def call(uri, body)
      @requests << { uri: uri, body: body }
      @queue.shift || Response.new("200", '{"translatedText":"ok"}')
    end
  end

  let(:http) { TranslationFakeHttp.new }
  let(:settings) do
    Rubotty::Translation::Settings.new(env: { Rubotty::Translation::Settings::URL_VAR => "http://lt.example" })
  end
  let(:client) { described_class.new(settings: settings, http: http) }

  it "posts to <url>/translate with the text, source and target" do
    http.queue(200, '{"translatedText":"ola"}')

    result = client.translate("hello", source: "en", target: "pt")

    expect(result).to eq("ola")
    request = http.requests.first
    expect(request[:uri].to_s).to eq("http://lt.example/translate")
    body = JSON.parse(request[:body])
    expect(body).to include("q" => "hello", "source" => "en", "target" => "pt", "format" => "text")
  end

  it "sends the api key when the connection has one" do
    keyed = Rubotty::Translation::Settings.new(
      env: { Rubotty::Translation::Settings::URL_VAR => "http://lt.example",
             Rubotty::Translation::Settings::API_KEY_VAR => "shh" }
    )
    http.queue(200, '{"translatedText":"ola"}')

    described_class.new(settings: keyed, http: http).translate("hi", source: "en", target: "pt")

    expect(JSON.parse(http.requests.first[:body])["api_key"]).to eq("shh")
  end

  it "raises when the connection is not configured" do
    unconfigured = described_class.new(settings: Rubotty::Translation::Settings.new(env: {}))

    expect { unconfigured.translate("hi", source: "en", target: "pt") }
      .to raise_error(Rubotty::Translation::Client::Error, /not configured/)
  end

  it "raises Error rather than a bare URI error for an unparsable URL, so a typo on the Integrations " \
     "page's Test button surfaces as a flash rather than a 500" do
    bad = Rubotty::Translation::Settings.new(env: { Rubotty::Translation::Settings::URL_VAR => "not a url" })

    expect { described_class.new(settings: bad, http: http).translate("hi", source: "en", target: "pt") }
      .to raise_error(Rubotty::Translation::Client::Error, /not a usable URL/)
  end

  it "raises rather than call out when the pair is not allowed" do
    narrow = Rubotty::Translation::Settings.new(
      env: { Rubotty::Translation::Settings::URL_VAR => "http://lt.example",
             Rubotty::Translation::Settings::ALLOWED_PAIRS_VAR => "en:pt" }
    )

    expect { described_class.new(settings: narrow, http: http).translate("hi", source: "en", target: "de") }
      .to raise_error(Rubotty::Translation::Client::Error, /not an allowed pair/)
    expect(http.requests).to be_empty
  end

  it "raises on a non 2xx answer" do
    http.queue(503, "down for maintenance")

    expect { client.translate("hi", source: "en", target: "pt") }
      .to raise_error(Rubotty::Translation::Client::Error, /503/)
  end

  it "raises on a body that is not the JSON LibreTranslate promises" do
    http.queue(200, "not json")

    expect { client.translate("hi", source: "en", target: "pt") }
      .to raise_error(Rubotty::Translation::Client::Error, /not JSON/)
  end

  it "raises when the answer has no translatedText" do
    http.queue(200, "{}")

    expect { client.translate("hi", source: "en", target: "pt") }
      .to raise_error(Rubotty::Translation::Client::Error, /translatedText/)
  end

  it "wraps a transport failure so it still propagates as Client::Error, for the scheduler's own retry" do
    failing = Class.new { def call(*) = raise Errno::ECONNREFUSED }.new

    expect { described_class.new(settings: settings, http: failing).translate("hi", source: "en", target: "pt") }
      .to raise_error(Rubotty::Translation::Client::Error, /could not reach/)
  end

  describe "#test_connection" do
    # A stand in for the network's GET half: receives (uri) and returns
    # whatever was queued, so no test here ever opens a socket either.
    class TranslationFakeHttpGet
      Response = Struct.new(:code, :body)

      def initialize
        @queue = []
        @requests = []
      end

      attr_reader :requests

      def queue(code, body) = @queue << Response.new(code.to_s, body)

      def call(uri)
        @requests << { uri: uri }
        @queue.shift || Response.new("200", "[]")
      end
    end

    let(:http_get) { TranslationFakeHttpGet.new }
    let(:client) { described_class.new(settings: settings, http_get: http_get) }

    it "gets <url>/languages, never posting and never spending a translation" do
      http_get.queue(200, '[{"code":"en","name":"English"},{"code":"pt","name":"Portuguese"}]')

      result = client.test_connection

      expect(result.length).to eq(2)
      expect(http_get.requests.first[:uri].to_s).to eq("http://lt.example/languages")
    end

    it "sends the api key as a query parameter when the connection has one" do
      keyed = Rubotty::Translation::Settings.new(
        env: { Rubotty::Translation::Settings::URL_VAR => "http://lt.example",
               Rubotty::Translation::Settings::API_KEY_VAR => "shh" }
      )
      http_get.queue(200, "[]")

      described_class.new(settings: keyed, http_get: http_get).test_connection

      expect(http_get.requests.first[:uri].query).to eq("api_key=shh")
    end

    it "raises when the connection is not configured" do
      unconfigured = described_class.new(settings: Rubotty::Translation::Settings.new(env: {}))

      expect { unconfigured.test_connection }.to raise_error(Rubotty::Translation::Client::Error, /not configured/)
    end

    it "raises on a non 2xx answer" do
      http_get.queue(401, "unauthorized")

      expect { client.test_connection }.to raise_error(Rubotty::Translation::Client::Error, /401/)
    end

    it "raises when the answer is not a JSON array of languages" do
      http_get.queue(200, '{"error":"nope"}')

      expect { client.test_connection }.to raise_error(Rubotty::Translation::Client::Error, /list of languages/)
    end

    it "raises on a body that is not JSON" do
      http_get.queue(200, "not json")

      expect { client.test_connection }.to raise_error(Rubotty::Translation::Client::Error, /not JSON/)
    end

    it "wraps a transport failure so it still propagates as Client::Error" do
      failing = Class.new { def call(*) = raise Errno::ECONNREFUSED }.new

      expect { described_class.new(settings: settings, http_get: failing).test_connection }
        .to raise_error(Rubotty::Translation::Client::Error, /could not reach/)
    end
  end
end
