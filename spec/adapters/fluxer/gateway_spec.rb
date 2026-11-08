# frozen_string_literal: true

require "spec_helper"

# What goes out on IDENTIFY decides which events the bot is sent. Fluxer
# has no intents: dispatch is opt OUT, through ignored_events, so naming
# nothing there is how a bridge asks for everything its permissions allow.
# Sending Discord's intents bitfield here would read as "we asked for none".
RSpec.describe Rubotty::Adapters::Fluxer::Gateway do
  let(:socket) { FluxerFakes::Socket.new }
  let(:received) { [] }

  subject(:gateway) do
    described_class.new(
      url: "wss://gateway.fluxer.test", token: "bot-token",
      on_event: ->(event) { received << event }, logger: Rubotty::Log.null
    )
  end

  def identify_frame
    gateway.instance_variable_set(:@socket, socket)
    gateway.send(:identify)
    socket.frames.last
  end

  it "identifies with the bot token" do
    expect(identify_frame["d"]["token"]).to eq("bot-token")
  end

  it "uses the IDENTIFY opcode Fluxer shares with Discord" do
    expect(identify_frame["op"]).to eq(described_class::IDENTIFY)
  end

  it "names the three properties Fluxer's validator requires" do
    expect(identify_frame["d"]["properties"]).to eq(
      "os" => "linux", "browser" => "rubotty", "device" => "rubotty"
    )
  end

  it "asks for no intents, there being no such thing on this platform" do
    expect(identify_frame["d"]).not_to have_key("intents")
  end

  # Naming an event here would suppress it, so an empty IDENTIFY is what keeps
  # message and reaction dispatch arriving.
  it "ignores no events, which is how it receives reactions" do
    expect(identify_frame["d"]).not_to have_key("ignored_events")
  end
end

# Heartbeat requests and acknowledgments are independent of chat traffic.
# A socket can stay open after the peer has stopped answering it.
RSpec.describe Rubotty::Adapters::Fluxer::Gateway, "heartbeat recovery" do
  let(:socket) { FluxerFakes::Socket.new }
  let(:received) { [] }
  subject(:gateway) do
    described_class.new(url: "wss://gateway.fluxer.test", token: "bot-token",
                        on_event: ->(event) { received << event }, logger: Rubotty::Log.null)
  end

  before do
    gateway.instance_variable_set(:@socket, socket)
    allow(gateway).to receive(:heartbeat_clock).and_return(100.0)
  end

  def frame(op, **fields)
    gateway.send(:on_frame, JSON.generate({ op: op }.merge(fields)))
  end

  it "answers a server-requested heartbeat before any dispatch" do
    frame(described_class::HEARTBEAT)

    expect(socket.frames).to eq([{ "op" => described_class::HEARTBEAT, "d" => nil }])
    expect(received).to be_empty
  end

  it "answers with the latest dispatch sequence" do
    frame(described_class::DISPATCH, s: 42, t: "READY", d: {})
    frame(described_class::HEARTBEAT)

    expect(socket.frames.last["d"]).to eq(42)
  end

  it "closes an unacknowledged connection after one interval" do
    gateway.send(:heartbeat_tick)
    allow(gateway).to receive(:heartbeat_clock).and_return(141.25)

    expect(socket).to receive(:close)
    expect(gateway.send(:heartbeat_tick)).to be(false)
    expect(socket.frames.size).to eq(1)
    expect(gateway.instance_variable_get(:@socket)).to be_nil
  end

  it "keeps an acknowledged connection and starts a new deadline" do
    gateway.send(:heartbeat_tick)
    frame(described_class::HEARTBEAT_ACK)
    allow(gateway).to receive(:heartbeat_clock).and_return(141.25)

    expect(socket).not_to receive(:close)
    expect(gateway.send(:heartbeat_tick)).to be(true)
    expect(socket.frames.size).to eq(2)
  end

  it "does not extend the deadline when the server requests another heartbeat" do
    gateway.send(:heartbeat_tick)
    allow(gateway).to receive(:heartbeat_clock).and_return(140.0)
    frame(described_class::HEARTBEAT)
    allow(gateway).to receive(:heartbeat_clock).and_return(141.25)

    expect(socket).to receive(:close)
    expect(gateway.send(:heartbeat_tick)).to be(false)
  end

  it "starts a fresh connection without the previous session's sequence or pending acknowledgment" do
    frame(described_class::DISPATCH, s: 42, t: "READY", d: {})
    gateway.send(:heartbeat_tick)
    allow(gateway).to receive(:connect_once)
    allow(gateway).to receive(:wait_while_connected)
    gateway.send(:attempt)
    allow(gateway).to receive(:heartbeat_clock).and_return(200.0)

    expect(gateway.send(:heartbeat_tick)).to be(true)
    expect(socket.frames.last["d"]).to be_nil
  end

  it "uses the timeout check in the actual heartbeat thread" do
    gateway.instance_variable_set(:@running, true)
    allow(gateway).to receive(:sleep_interruptibly)
    expect(gateway).to receive(:heartbeat_tick).and_return(false)

    thread = gateway.send(:start_heartbeat)
    expect(thread.join(3)).to eq(thread)
  ensure
    gateway.stop
  end

  it "leaves a replacement socket to its own heartbeat thread" do
    gateway.instance_variable_set(:@running, true)
    replacement = FluxerFakes::Socket.new
    allow(gateway).to receive(:sleep_interruptibly) { gateway.instance_variable_set(:@socket, replacement) }
    expect(gateway).not_to receive(:heartbeat_tick)

    thread = gateway.send(:start_heartbeat)
    expect(thread.join(3)).to eq(thread)
    expect(replacement.frames).to be_empty
  ensure
    gateway.stop
  end

  it "rejects invalid heartbeat intervals without entering a hot loop" do
    allow(gateway).to receive(:start_heartbeat)
    [0, -1, "soon", nil].each do |interval|
      frame(described_class::HELLO, d: { heartbeat_interval: interval })
      expect(gateway.instance_variable_get(:@heartbeat_ms)).to eq(described_class::DEFAULT_HEARTBEAT_MS)
    end
  end

  it "uses the positive interval supplied by the server" do
    allow(gateway).to receive(:start_heartbeat)
    frame(described_class::HELLO, d: { heartbeat_interval: 10_000 })
    gateway.send(:heartbeat_tick)
    allow(gateway).to receive(:heartbeat_clock).and_return(110.0)

    expect(gateway.send(:heartbeat_tick)).to be(false)
  end
end

# A refused token does not raise here. The server accepts the socket, reads
# IDENTIFY and closes, so connect_once returns normally and the supervisor used
# to treat that as a healthy connection: reset the failure count, reconnect at
# once, log nothing, and go on answering #running? true while receiving nothing.
RSpec.describe Rubotty::Adapters::Fluxer::Gateway, "a handshake the server refuses" do
  let(:sink) { StringIO.new }
  let(:received) { [] }

  subject(:gateway) do
    described_class.new(
      url: "wss://gateway.fluxer.test", token: "bot-token",
      on_event: ->(event) { received << event },
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

  def refused_attempt
    allow(gateway).to receive(:connect_once)
    allow(gateway).to receive(:wait_while_connected)
    gateway.send(:attempt)
  end

  def dispatched_attempt
    allow(gateway).to receive(:connect_once)
    allow(gateway).to receive(:wait_while_connected) do
      gateway.send(:on_frame, JSON.generate(op: described_class::DISPATCH, t: "READY", d: { "guilds" => [] }))
    end
    gateway.send(:attempt)
  end

  it "counts a connection that never dispatched as a failure" do
    expect(refused_attempt).to match(/closed before the first dispatch/)
  end

  # The supervisor is stopped by counting connects rather than waits, so a build
  # where the loop never waits at all ends rather than spinning here.
  it "waits longer each time instead of reconnecting flat out" do
    waits = []
    connects = 0
    allow(gateway).to receive(:connect_once) do
      connects += 1
      gateway.instance_variable_set(:@running, false) if connects >= 3
    end
    allow(gateway).to receive(:wait_while_connected)
    allow(gateway).to receive(:sleep_interruptibly) { |seconds| waits << seconds }

    gateway.send(:supervise)

    expect(waits).to eq([1, 2, 4])
    expect(sink.string).to include("closed before the first dispatch")
  end

  it "stops answering #running? true once it keeps happening" do
    expect(gateway).to be_running
    2.times { refused_attempt }
    expect(gateway).not_to be_running
  end

  it "treats the first dispatch as proof the token was accepted" do
    expect(dispatched_attempt).to be_nil
    expect(received.map { |event| event["t"] }).to eq(["READY"])
    expect(gateway).to be_running
  end

  it "clears the failures an earlier refusal left behind" do
    2.times { refused_attempt }
    dispatched_attempt
    expect(gateway).to be_running
  end

  it "logs the close itself, which nothing did before" do
    gateway.send(:mark_closed)
    expect(sink.string).to include("socket closed before the first dispatch")
  end

  # A rolling deploy on the remote end, or a proxy resetting connections right
  # after the handshake, identifies and drops the session over and over. Each
  # attempt in isolation looks like a clean success, so left unguarded this
  # reconnects hot, bounded only by handshake speed.
  describe "a session that identifies and drops repeatedly" do
    it "eventually stops treating another instant reconnect as a success" do
      results = Array.new(4) { dispatched_attempt }
      expect(results).to include(a_string_matching(/keeps ending again/))
    end

    it "does not mark itself unreachable the way a refused token does" do
      4.times { dispatched_attempt }
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
        gateway.send(:on_frame, JSON.generate(op: described_class::DISPATCH, t: "READY", d: { "guilds" => [] }))
      end
      allow(gateway).to receive(:sleep_interruptibly) { |seconds| waits << seconds }

      gateway.send(:supervise)

      expect(waits).not_to be_empty
    end

    it "resets the streak once a session actually stays up a while" do
      2.times { dispatched_attempt }

      allow(gateway).to receive(:connect_once)
      allow(gateway).to receive(:wait_while_connected) do
        gateway.send(:on_frame, JSON.generate(op: described_class::DISPATCH, t: "READY", d: { "guilds" => [] }))
        started = Time.now - Rubotty::Adapters::Fluxer::Gateway::MIN_SESSION_SECONDS
        gateway.instance_variable_set(:@identified_at, started)
      end
      expect(gateway.send(:attempt)).to be_nil

      results = Array.new(2) { dispatched_attempt }
      expect(results).to all(be_nil)
    end
  end
end
