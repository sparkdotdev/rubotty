# frozen_string_literal: true

require "spec_helper"

# The check behind the dashboard header's drift warning. spec_helper stubs
# Net::HTTP.start to raise, so every case that needs an upstream injects a fake
# connection through that seam and the rest prove no request was made at all.
RSpec.describe Rubotty::Core::DeployDrift do
  let(:now) { Time.utc(2026, 8, 4, 12, 0, 0) }
  let(:clock) { -> { @now } }

  before { @now = now }

  def advance(seconds) = @now += seconds

  def fake_upstream(body:, status_class: Net::HTTPOK, code: "200")
    response = status_class.new("1.1", code, "")
    allow(response).to receive(:body).and_return(body)
    fake_http = instance_double(Net::HTTP, request: response)
    allow(Net::HTTP).to receive(:start) do |*_args, **_kwargs, &block|
      block.call(fake_http)
    end
    fake_http
  end

  def drift(**overrides)
    described_class.new(
      head_url: "https://upstream.example/head", commit: "4acb0e3",
      grace: 900, ttl: 0, clock: clock, **overrides
    )
  end

  describe "with nothing configured" do
    it "is not configured, says nothing and never reaches for the network" do
      checker = described_class.new(clock: clock)
      expect(Net::HTTP).not_to receive(:start)

      expect(checker.configured?).to be(false)
      expect(checker.warnings).to eq([])
    end
  end

  describe "the running commit against the head of the default branch" do
    it "says nothing when they are the same commit" do
      fake_upstream(body: "4acb0e3d9f1a2b3c4d5e6f708192a3b4c5d6e7f8\n")

      expect(drift.warnings).to eq([])
    end

    it "stays quiet while the difference is still inside the grace period" do
      fake_upstream(body: "9f1a2b3c4d5e6f708192a3b4c5d6e7f84acb0e3d")
      checker = drift

      expect(checker.warnings).to eq([])
      advance(899)
      expect(checker.warnings).to eq([])
    end

    it "warns once the difference has outlasted the grace period" do
      fake_upstream(body: "9f1a2b3c4d5e6f708192a3b4c5d6e7f84acb0e3d")
      checker = drift

      checker.warnings
      advance(901)

      expect(checker.warnings).to contain_exactly(
        a_string_including("main is at 9f1a2b3", "still running 4acb0e3")
      )
    end

    it "restarts the grace period when main moves again" do
      fake_upstream(body: "9f1a2b3c4d5e6f708192a3b4c5d6e7f84acb0e3d")
      checker = drift
      checker.warnings
      advance(901)
      expect(checker.warnings).not_to be_empty

      fake_upstream(body: "1122334455667788990011223344556677889900")
      expect(checker.warnings).to eq([])
    end

    it "clears the warning once the deploy catches up" do
      fake_upstream(body: "9f1a2b3c4d5e6f708192a3b4c5d6e7f84acb0e3d")
      checker = drift
      checker.warnings
      advance(901)
      expect(checker.warnings).not_to be_empty

      fake_upstream(body: "4acb0e3d9f1a2b3c4d5e6f708192a3b4c5d6e7f8")
      expect(checker.warnings).to eq([])
    end

    it "reads the sha out of GitHub's commit JSON when the Accept header is ignored" do
      fake_upstream(body: '{"sha":"9f1a2b3c4d5e6f708192a3b4c5d6e7f84acb0e3d","commit":{}}')
      checker = drift

      checker.warnings
      advance(901)

      expect(checker.warnings.first).to include("main is at 9f1a2b3")
    end

    it "sends the bearer token when the configuration named an environment variable for one" do
      fake_http = fake_upstream(body: "4acb0e3")

      drift(token: "ghp-secret").warnings

      expect(fake_http).to have_received(:request) do |request|
        expect(request["Authorization"]).to eq("Bearer ghp-secret")
        expect(request["Accept"]).to eq(described_class::SHA_ACCEPT)
      end
    end

    it "sends no credential when no token was configured" do
      fake_http = fake_upstream(body: "4acb0e3")

      drift.warnings

      expect(fake_http).to have_received(:request) { |request| expect(request["Authorization"]).to be_nil }
    end

    it "says nothing when the upstream cannot be reached, and does not raise" do
      allow(Net::HTTP).to receive(:start).and_raise(Errno::ECONNREFUSED)
      checker = drift

      checker.warnings
      advance(901)

      expect { checker.warnings }.not_to raise_error
      expect(checker.warnings).to eq([])
    end

    it "says nothing when the upstream answers with a body carrying no commit" do
      fake_upstream(body: "<html>not found</html>")
      checker = drift

      checker.warnings
      advance(901)

      expect(checker.warnings).to eq([])
    end

    it "says nothing when the upstream refuses the request" do
      fake_upstream(status_class: Net::HTTPForbidden, code: "403", body: "no")
      checker = drift

      checker.warnings
      advance(901)

      expect(checker.warnings).to eq([])
    end

    it "says nothing when this process does not know its own commit" do
      expect(Net::HTTP).not_to receive(:start)

      expect(drift(commit: Rubotty::Core::BuildInfo::UNKNOWN).warnings).to eq([])
    end

    it "reuses one answer for the whole cache window instead of asking again" do
      fake_http = fake_upstream(body: "4acb0e3")
      checker = drift(ttl: 300)

      3.times { checker.warnings }
      advance(299)
      checker.warnings

      expect(fake_http).to have_received(:request).once
    end
  end

  describe "the bot process against this one" do
    def bot(info) = -> { info }

    it "says nothing when both processes are on the same version" do
      checker = described_class.new(
        bot_info: bot({ "reachable" => true, "version" => "0.5.55" }),
        version: "0.5.55", grace: 900, ttl: 0, clock: clock
      )

      checker.warnings
      advance(901)
      expect(checker.warnings).to eq([])
    end

    it "surfaces a mismatch once it has outlasted the grace period" do
      checker = described_class.new(
        bot_info: bot({ "reachable" => true, "version" => "0.5.53" }),
        version: "0.5.55", grace: 900, ttl: 0, clock: clock
      )

      expect(checker.warnings).to eq([])
      advance(901)

      expect(checker.warnings).to contain_exactly(
        a_string_including("the bot process is running 0.5.53", "this one is running 0.5.55")
      )
    end

    it "says nothing when the bot process could not be reached" do
      checker = described_class.new(
        bot_info: bot({ "reachable" => false, "error" => "connection refused" }),
        version: "0.5.55", grace: 900, ttl: 0, clock: clock
      )

      checker.warnings
      advance(901)
      expect(checker.warnings).to eq([])
    end

    it "says nothing when asking the bot raises" do
      checker = described_class.new(
        bot_info: -> { raise Errno::ECONNREFUSED },
        version: "0.5.55", grace: 900, ttl: 0, clock: clock
      )

      checker.warnings
      advance(901)
      expect { checker.warnings }.not_to raise_error
      expect(checker.warnings).to eq([])
    end

    it "reports both differences together when the deployment has drifted from main as well" do
      fake_upstream(body: "9f1a2b3c4d5e6f708192a3b4c5d6e7f84acb0e3d")
      checker = drift(
        bot_info: bot({ "reachable" => true, "version" => "0.5.53" }), version: "0.5.55"
      )

      checker.warnings
      advance(901)

      expect(checker.warnings.size).to eq(2)
    end
  end
end
