# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"

# The web-to-bot half of the push nudge. spec_helper stubs Net::HTTP.start to
# raise, so every case injects a fake connection through that seam and asserts what
# BotNudge sent and how it reads the response.
RSpec.describe Rubotty::Dashboard::BotNudge do
  def fake_connection(status_class: Net::HTTPOK, code: "200")
    response = status_class.new("1.1", code, "")
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

    it "is false when both are blank strings" do
      expect(described_class.new(bot_url: "  ", secret: "").configured?).to be(false)
    end

    it "is true with both set" do
      expect(described_class.new(bot_url: "http://bot:8080", secret: "s3cret").configured?).to be(true)
    end
  end

  describe "#nudge" do
    it "never touches the network when unconfigured" do
      nudge = described_class.new(bot_url: nil, secret: nil)
      expect(Net::HTTP).not_to receive(:start)
      expect(nudge.nudge).to be(false)
    end

    it "POSTs to the health server's reload path with the shared secret header and the reason as the body" do
      fake_http, = fake_connection
      nudge = described_class.new(bot_url: "http://bot:8080", secret: "s3cret")

      expect(nudge.nudge(reason: "community rename")).to be(true)
      expect(fake_http).to have_received(:request) do |request|
        expect(request.path).to eq(Rubotty::Core::HealthServer::RELOAD_PATH)
        expect(request[Rubotty::Core::HealthServer::RELOAD_SECRET_HEADER]).to eq("s3cret")
        expect(request.body).to eq("community rename")
      end
    end

    it "returns false on a non-success response" do
      fake_connection(status_class: Net::HTTPForbidden, code: "403")
      nudge = described_class.new(bot_url: "http://bot:8080", secret: "wrong")

      expect(nudge.nudge).to be(false)
    end

    it "never raises, and returns false, when the connection itself fails" do
      allow(Net::HTTP).to receive(:start).and_raise(Errno::ECONNREFUSED)
      nudge = described_class.new(bot_url: "http://bot:8080", secret: "s3cret")

      expect { nudge.nudge }.not_to raise_error
      expect(nudge.nudge).to be(false)
    end

    it "uses https when the bot_url is https" do
      allow(Net::HTTP).to receive(:start) do |_host, _port, **kwargs, &block|
        @use_ssl = kwargs[:use_ssl]
        block.call(instance_double(Net::HTTP, request: Net::HTTPOK.new("1.1", "200", "")))
      end
      nudge = described_class.new(bot_url: "https://bot.internal:8443", secret: "s3cret")

      nudge.nudge
      expect(@use_ssl).to be(true)
    end
  end

  # The Accept button's push. Unlike #nudge this one is not
  # best-effort: only the bot process holds the adapters that can actually
  # relay a proposal, so a failure here has to come back as a plain error the
  # dashboard route can show, not a silently swallowed false.
  describe "#relay_proposal" do
    it "never touches the network when unconfigured, and says why" do
      nudge = described_class.new(bot_url: nil, secret: nil)
      expect(Net::HTTP).not_to receive(:start)

      result = nudge.relay_proposal(42)

      expect(result.ok?).to be(false)
      expect(result.error).to include("not configured")
    end

    it "POSTs the proposal id to the relay path with the shared secret header" do
      fake_http, = fake_connection
      nudge = described_class.new(bot_url: "http://bot:8080", secret: "s3cret")

      result = nudge.relay_proposal(42)

      expect(result.ok?).to be(true)
      expect(fake_http).to have_received(:request) do |request|
        expect(request.path).to eq(Rubotty::Core::HealthServer::RELAY_PROPOSAL_PATH)
        expect(request[Rubotty::Core::HealthServer::RELOAD_SECRET_HEADER]).to eq("s3cret")
        expect(request.body).to eq("42")
      end
    end

    it "reports the bot's own error body on a non-success response, rather than claiming success" do
      response = Net::HTTPUnprocessableEntity.new("1.1", "422", "")
      allow(response).to receive(:body).and_return("that proposal is expired, not waiting for a decision\n")
      fake_http = instance_double(Net::HTTP, request: response)
      allow(Net::HTTP).to receive(:start) { |*_args, **_kwargs, &block| block.call(fake_http) }
      nudge = described_class.new(bot_url: "http://bot:8080", secret: "s3cret")

      result = nudge.relay_proposal(42)

      expect(result.ok?).to be(false)
      expect(result.error).to include("that proposal is expired")
    end

    it "never raises, and reports an unreachable bot plainly, when the connection itself fails" do
      allow(Net::HTTP).to receive(:start).and_raise(Errno::ECONNREFUSED)
      nudge = described_class.new(bot_url: "http://bot:8080", secret: "s3cret")

      result = nil
      expect { result = nudge.relay_proposal(42) }.not_to raise_error
      expect(result.ok?).to be(false)
      expect(result.error).to include("could not reach the bot process")
    end
  end
end
