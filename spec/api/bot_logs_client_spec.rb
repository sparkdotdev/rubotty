# frozen_string_literal: true

require "spec_helper"
require "rubotty/api"

# The web-to-bot half of the admin debug/logs endpoint. spec_helper stubs
# Net::HTTP.start to raise, so every case injects a fake connection through that seam.
RSpec.describe Rubotty::Api::BotLogsClient do
  def fake_connection(status_class: Net::HTTPOK, code: "200", body: "entries: []\n")
    response = status_class.new("1.1", code, "")
    allow(response).to receive(:body).and_return(body)
    fake_http = instance_double(Net::HTTP, request: response)
    allow(Net::HTTP).to receive(:start) do |*_args, **_kwargs, &block|
      block.call(fake_http)
    end
    [fake_http, response]
  end

  describe "#configured?" do
    it "is false with no bot_url" do
      expect(described_class.new(bot_url: nil, secret: "s3cret").configured?).to be(false)
    end

    it "is false with no secret" do
      expect(described_class.new(bot_url: "http://bot:8080", secret: nil).configured?).to be(false)
    end

    it "is true with both set" do
      expect(described_class.new(bot_url: "http://bot:8080", secret: "s3cret").configured?).to be(true)
    end
  end

  describe "#fetch" do
    it "never touches the network when unconfigured, answering an explanatory error" do
      client = described_class.new(bot_url: nil, secret: nil)
      expect(Net::HTTP).not_to receive(:start)

      result = client.fetch
      expect(result.ok?).to be(false)
      expect(result.error).to include("not configured")
    end

    it "GETs the health server's logs path with the shared secret header" do
      fake_http, = fake_connection(body: "entries:\n- time: '2026-07-27T12:00:00Z'\n  level: WARN\n  text: hi\n")
      client = described_class.new(bot_url: "http://bot:8080", secret: "s3cret")

      result = client.fetch(level: "warn", limit: 5)

      expect(result.ok?).to be(true)
      expect(result.entries).to eq([{ "time" => "2026-07-27T12:00:00Z", "level" => "WARN", "text" => "hi" }])
      expect(fake_http).to have_received(:request) do |request|
        expect(request.path).to start_with(Rubotty::Core::HealthServer::LOGS_PATH)
        expect(request.path).to include("level=warn")
        expect(request.path).to include("limit=5")
        expect(request[Rubotty::Core::HealthServer::RELOAD_SECRET_HEADER]).to eq("s3cret")
      end
    end

    # With no logs route mounted the request falls through to HealthServer's liveness
    # handler, which answers 200 "ok". Reading that as an empty success would say the
    # bot logged nothing when it cannot answer at all.
    it "reports a missing logs route as an error, never as an empty success" do
      fake_connection(body: "ok\n")
      client = described_class.new(bot_url: "http://bot:8080", secret: "s3cret")

      result = client.fetch
      expect(result.ok?).to be(false)
      expect(result.error).to include("no logs route")
    end

    it "still accepts a genuinely empty entries list as a success" do
      fake_connection(body: "entries: []\n")
      client = described_class.new(bot_url: "http://bot:8080", secret: "s3cret")

      result = client.fetch
      expect(result.ok?).to be(true)
      expect(result.entries).to eq([])
    end

    it "answers an error, never raising, on a non-success response" do
      fake_connection(status_class: Net::HTTPForbidden, code: "403", body: "")
      client = described_class.new(bot_url: "http://bot:8080", secret: "wrong")

      result = client.fetch
      expect(result.ok?).to be(false)
      expect(result.error).to include("403")
    end

    it "answers an error, never raising, when the connection itself fails" do
      allow(Net::HTTP).to receive(:start).and_raise(Errno::ECONNREFUSED)
      client = described_class.new(bot_url: "http://bot:8080", secret: "s3cret")

      result = nil
      expect { result = client.fetch }.not_to raise_error
      expect(result.ok?).to be(false)
    end
  end

  # The generalised hop #fetch and #fetch_info are both built on: an
  # authenticated GET against any path the bot's health server mounts.
  describe "#get" do
    it "never touches the network when unconfigured, answering an explanatory error" do
      client = described_class.new(bot_url: nil, secret: nil)
      expect(Net::HTTP).not_to receive(:start)

      result = client.get("/internal/backfill-gaps")
      expect(result.ok?).to be(false)
      expect(result.error).to include("not configured")
    end

    it "GETs the given path with the shared secret header and the given params" do
      fake_http, = fake_connection(body: "channels: []\n")
      client = described_class.new(bot_url: "http://bot:8080", secret: "s3cret")

      result = client.get("/internal/backfill-gaps", params: { "since" => nil, "limit" => 5 })

      expect(result.ok?).to be(true)
      expect(result.body).to eq({ "channels" => [] })
      expect(fake_http).to have_received(:request) do |request|
        expect(request.path).to eq("/internal/backfill-gaps?limit=5")
        expect(request[Rubotty::Core::HealthServer::RELOAD_SECRET_HEADER]).to eq("s3cret")
      end
    end

    it "answers an error, never raising, on a non-success response" do
      fake_connection(status_class: Net::HTTPForbidden, code: "403", body: "")
      client = described_class.new(bot_url: "http://bot:8080", secret: "wrong")

      result = client.get("/internal/backfill-gaps")
      expect(result.ok?).to be(false)
      expect(result.error).to include("403")
    end
  end
end
