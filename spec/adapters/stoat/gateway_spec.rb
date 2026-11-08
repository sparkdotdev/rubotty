# frozen_string_literal: true

require "spec_helper"
require "stringio"

# A revoked token does not raise here. The server accepts the TCP and TLS
# handshake, reads the Authenticate frame, and closes, so connect_once
# returns normally, and the supervisor used to treat that as healthy: reset
# the failure count, reconnect at once, and answer #running? true while receiving nothing.
RSpec.describe Rubotty::Adapters::Stoat::Gateway do
  let(:sink) { StringIO.new }
  let(:received) { [] }

  subject(:gateway) do
    described_class.new(
      token: "bot-token", on_event: ->(event) { received << event },
      logger: Rubotty::Log.build(level: "info", io: sink)
    )
  end

  # #supervise names the thread it runs on, which here is the one running the
  # suite.
  around do |example|
    name = Thread.current.name
    example.run
    Thread.current.name = name
  end

  before { gateway.instance_variable_set(:@running, true) }

  # A socket that opens and closes with no Authenticated frame in between.
  def refused_attempt
    allow(gateway).to receive(:connect_once)
    allow(gateway).to receive(:wait_while_connected)
    gateway.send(:attempt)
  end

  def authenticated_attempt
    allow(gateway).to receive(:connect_once)
    allow(gateway).to receive(:wait_while_connected) do
      gateway.send(:on_frame, JSON.generate(type: "Authenticated"))
    end
    gateway.send(:attempt)
  end

  describe "a connection that dies before the handshake" do
    it "counts as a failure rather than as a healthy connection" do
      expect(refused_attempt).to match(/closed before authenticating/)
    end

    # The supervisor is stopped by counting connects rather than waits, so a
    # build where the loop never waits at all ends rather than spinning here.
    def supervise_three_connections(waits)
      connects = 0
      allow(gateway).to receive(:connect_once) do
        connects += 1
        gateway.instance_variable_set(:@running, false) if connects >= 3
      end
      allow(gateway).to receive(:wait_while_connected)
      allow(gateway).to receive(:sleep_interruptibly) { |seconds| waits << seconds }
      gateway.send(:supervise)
    end

    it "waits longer each time instead of reconnecting flat out" do
      waits = []
      supervise_three_connections(waits)
      expect(waits).to eq([1, 2, 4])
    end

    it "says so in the log, which is what a revoked token left no trace of" do
      supervise_three_connections([])
      expect(sink.string).to include("closed before authenticating")
      expect(sink.string).to include("reconnecting in 1s")
    end

    it "stops answering #running? true once it keeps happening" do
      expect(gateway).to be_running
      refused_attempt
      expect(gateway).to be_running
      refused_attempt
      expect(gateway).not_to be_running
    end
  end

  describe "a connection that authenticates" do
    it "counts as a success, so the next drop reconnects without a wait" do
      expect(authenticated_attempt).to be_nil
      expect(gateway).to be_running
    end

    it "clears the failures an earlier refusal left behind" do
      2.times { refused_attempt }
      expect(gateway).not_to be_running
      authenticated_attempt
      expect(gateway).to be_running
    end

    it "still passes the frame on to the adapter" do
      authenticated_attempt
      expect(received.map { |event| event["type"] }).to eq(["Authenticated"])
    end
  end

  # A rolling deploy on the remote end, or a proxy resetting connections right
  # after the handshake, authenticates and drops the session over and over.
  # Each attempt in isolation looks like a clean success, so left unguarded
  # this reconnects hot, bounded only by handshake speed.
  describe "a session that authenticates and drops repeatedly" do
    it "eventually stops treating another instant reconnect as a success" do
      results = Array.new(4) { authenticated_attempt }
      expect(results).to include(a_string_matching(/keeps ending again/))
    end

    it "does not mark itself unreachable the way a refused token does" do
      4.times { authenticated_attempt }
      expect(gateway).to be_running
    end

    it "backs off through supervise once the flapping repeats enough times" do
      waits = []
      connects = 0
      allow(gateway).to receive(:connect_once) do
        connects += 1
        gateway.instance_variable_set(:@running, false) if connects >= 5
      end
      allow(gateway).to receive(:wait_while_connected) do
        gateway.send(:on_frame, JSON.generate(type: "Authenticated"))
      end
      allow(gateway).to receive(:sleep_interruptibly) { |seconds| waits << seconds }

      gateway.send(:supervise)

      expect(waits).not_to be_empty
    end

    it "resets the streak once a session actually stays up a while" do
      # Two instant drops alone stay under the streak that trips a wait, so
      # this alone proves nothing; it is here to show that without the reset
      # below, one more pair of instant drops would push the streak past the
      # trip point.
      2.times { authenticated_attempt }

      allow(gateway).to receive(:connect_once)
      allow(gateway).to receive(:wait_while_connected) do
        gateway.send(:on_frame, JSON.generate(type: "Authenticated"))
        started = Time.now - Rubotty::Adapters::Stoat::Gateway::MIN_SESSION_SECONDS
        gateway.instance_variable_set(:@authenticated_at, started)
      end
      expect(gateway.send(:attempt)).to be_nil

      results = Array.new(2) { authenticated_attempt }
      expect(results).to all(be_nil)
    end
  end

  describe "#note_refused" do
    it "stops reporting itself as running, since the token cannot come back" do
      authenticated_attempt
      gateway.note_refused("Logout")
      expect(gateway).not_to be_running
    end

    it "makes the next attempt back off rather than reconnect at once" do
      gateway.note_refused("Logout")
      allow(gateway).to receive(:connect_once)
      allow(gateway).to receive(:wait_while_connected)
      expect(gateway.send(:attempt)).to eq("session ended by the server")
    end
  end

  it "logs the close itself, which nothing did before" do
    gateway.send(:mark_closed)
    expect(sink.string).to include("socket closed before authenticating")
  end
end
