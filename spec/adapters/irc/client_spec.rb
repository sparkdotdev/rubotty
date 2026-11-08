# frozen_string_literal: true

require "spec_helper"

# Client is thin, with the wire logic in the pure Protocol module, so these
# cover the handful of behaviours that genuinely live in Client and are cheap to
# drive through the private #handle_line with no socket.
RSpec.describe Rubotty::Adapters::Irc::Client do
  # Resolves each level's block eagerly, so a spec can assert on the rendered message.
  let(:logger) do
    Class.new do
      attr_reader :errors, :warnings, :infos

      def initialize
        @errors = []
        @warnings = []
        @infos = []
      end

      def error(&block) = @errors << block.call
      def warn(&block) = @warnings << block.call
      def info(&block) = @infos << block.call
    end.new
  end

  let(:writes) { [] }
  let(:socket) { double("socket") }

  subject(:client) do
    described_class.new(server: "irc.example.org", nick: "rubotty", logger: logger)
  end

  before do
    # Wire-unit examples bypass the handshake on an already registered socket.
    allow(socket).to receive(:write) { |data| writes << data }
    client.instance_variable_set(:@socket, socket)
    client.instance_variable_set(:@registered, true)
  end

  describe "#join" do
    it "sends a plain JOIN for a channel with no key" do
      client.join("#general")
      expect(writes).to eq(["JOIN #general\r\n"])
    end

    it "sends the +k key after the channel, resolved by the caller from its env var" do
      client.join("#ops", key: "hunter2")
      expect(writes).to eq(["JOIN #ops hunter2\r\n"])
    end
  end

  # The adapter's #running? reads this instead of the @running latch #close
  # sets, so a clean close from the server cannot look like a healthy
  # connection.
  describe "#alive?" do
    it "is false before any #connect" do
      expect(client.alive?).to be(false)
    end

    it "goes false, and logs, when the read loop ends on a clean close from the server" do
      allow(socket).to receive(:gets).and_return(nil)
      client.instance_variable_set(:@running, true)
      client.send(:read_loop)

      expect(client.alive?).to be(false)
      expect(logger.warnings).not_to be_empty
    end

    it "goes false, and logs the exception, when the read loop ends on an error" do
      allow(socket).to receive(:gets).and_raise(IOError, "stream closed")
      client.instance_variable_set(:@running, true)
      client.send(:read_loop)

      expect(client.alive?).to be(false)
      expect(logger.warnings.last).to include("IOError")
    end

    it "goes false with no warning when #close ended it on purpose" do
      allow(socket).to receive(:gets).and_return(nil)
      client.instance_variable_set(:@running, false) # what #close sets before the loop next wakes
      client.send(:read_loop)

      expect(client.alive?).to be(false)
      expect(logger.warnings).to be_empty
    end
  end

  describe "an invite only (or otherwise refused) join" do
    def numeric(code, channel, reason)
      line = Rubotty::Adapters::Irc::Protocol.parse(
        ":irc.example.org #{code} rubotty #{channel} :Cannot join channel (#{reason})"
      )
      client.send(:handle_line, line)
    end

    it "logs a clear, specific reason instead of retrying" do
      numeric("473", "#ops", "+i")
      expect(logger.errors).to eq(
        ["IRC could not join #ops: invite only (+i); the bot needs an invite, or an op to /invite it"]
      )
    end

    it "does not attempt another JOIN itself: no code path here writes to the socket" do
      numeric("473", "#ops", "+i")
      expect(writes).to be_empty
    end

    it "logs once per refusal, not a growing retry storm" do
      numeric("473", "#ops", "+i")
      numeric("473", "#ops", "+i")
      expect(logger.errors.size).to eq(2)
      expect(writes).to be_empty
    end

    it "reports a bad or missing channel key distinctly" do
      numeric("475", "#ops", "+k")
      expect(logger.errors.first).to include("channel key (+k)")
    end

    it "marks the channel unusable, so a later send raises instead of vanishing into it" do
      numeric("473", "#ops", "+i")
      expect { client.privmsg("#ops", "hello") }.to raise_error(Rubotty::AdapterError, /never joined/)
    end

    it "leaves a channel that WAS joined untouched" do
      numeric("473", "#ops", "+i")
      expect { client.privmsg("#general", "hello") }.not_to raise_error
    end
  end

  describe "SASL PLAIN" do
    subject(:client) do
      described_class.new(
        server: "irc.example.org", nick: "rubotty",
        sasl_user: "rubotty", sasl_password: "s3cret", logger: logger
      )
    end

    def line(raw) = Rubotty::Adapters::Irc::Protocol.parse(raw)

    it "answers the server's AUTHENTICATE + prompt with the base64 PLAIN payload" do
      client.send(:handle_line, line("AUTHENTICATE +"))
      expect(writes.last).to eq("AUTHENTICATE #{Base64.strict_encode64("rubotty\0rubotty\0s3cret")}\r\n")
    end

    it "starts the AUTHENTICATE exchange once the server ACKs the sasl capability" do
      client.send(:handle_line, line(":irc.example.org CAP * ACK :sasl"))
      expect(writes).to eq(["AUTHENTICATE PLAIN\r\n"])
    end

    it "gives up cleanly (CAP END) when the server NAKs sasl" do
      client.send(:handle_line, line(":irc.example.org CAP * NAK :sasl"))
      expect(writes).to eq(["CAP END\r\n"])
      expect(logger.warnings).not_to be_empty
    end

    it "sends CAP END once SASL succeeds, so registration can complete" do
      client.send(:handle_line, line(":irc.example.org 903 rubotty :SASL authentication successful"))
      expect(writes).to eq(["CAP END\r\n"])
      expect(logger.infos).not_to be_empty
    end

    it "still sends CAP END on SASL failure, rather than hanging registration forever" do
      client.send(:handle_line, line(":irc.example.org 904 rubotty :SASL authentication failed"))
      expect(writes).to eq(["CAP END\r\n"])
      expect(logger.errors).not_to be_empty
    end
  end

  # CAP LS 302, requesting only the intersection of what the server advertised
  # and what this client understands, with SASL folded into the same exchange.
  describe "CAP REQ/ACK/NAK (issue #220)" do
    def line(raw) = Rubotty::Adapters::Irc::Protocol.parse(raw)

    it "requests only capabilities both advertised and understood, ignoring the rest" do
      client.send(:handle_line, line(
        ":irc.example.org CAP * LS :message-tags server-time some-unknown-cap chghost"
      ))
      # The order comes from UNDERSTOOD_CAPS; sasl is absent because this
      # subject never configured it.
      expect(writes).to eq(["CAP REQ :message-tags server-time chghost\r\n"])
    end

    it "reassembles a multiline 'CAP LS 302' response before requesting anything" do
      client.send(:handle_line, line(":irc.example.org CAP * LS * :message-tags server-time"))
      expect(writes).to be_empty # the continuation page has not arrived yet

      client.send(:handle_line, line(":irc.example.org CAP * LS :msgid echo-message"))
      expect(writes).to eq(["CAP REQ :message-tags server-time msgid echo-message\r\n"])
    end

    it "adds every capability the server ACKs to negotiated_capabilities" do
      client.send(:handle_line, line(":irc.example.org CAP * LS :message-tags msgid"))
      client.send(:handle_line, line(":irc.example.org CAP rubotty ACK :message-tags msgid"))
      expect(client.negotiated_capabilities).to contain_exactly("message-tags", "msgid")
    end

    it "does not negotiate a capability the server NAKs, and still ends CAP" do
      client.send(:handle_line, line(":irc.example.org CAP * LS :message-tags msgid"))
      writes.clear
      client.send(:handle_line, line(":irc.example.org CAP rubotty NAK :message-tags msgid"))
      expect(client.negotiated_capabilities).to be_empty
      expect(writes).to eq(["CAP END\r\n"])
    end

    it "sends CAP END immediately when the server advertises nothing this client understands" do
      client.send(:handle_line, line(":irc.example.org CAP * LS :some-unknown-cap another-unknown"))
      expect(writes).to eq(["CAP END\r\n"])
    end

    context "with SASL configured alongside other capabilities" do
      subject(:client) do
        described_class.new(
          server: "irc.example.org", nick: "rubotty",
          sasl_user: "rubotty", sasl_password: "s3cret", logger: logger
        )
      end

      it "requests sasl on its own REQ line, separate from the rest" do
        client.send(:handle_line, line(":irc.example.org CAP * LS :sasl=PLAIN message-tags msgid"))
        expect(writes).to eq(["CAP REQ :sasl\r\n", "CAP REQ :message-tags msgid\r\n"])
      end

      it "does not request sasl when the server's mechanism list excludes PLAIN" do
        client.send(:handle_line, line(":irc.example.org CAP * LS :sasl=EXTERNAL message-tags"))
        expect(writes).to eq(["CAP REQ :message-tags\r\n"])
        expect(logger.warnings).not_to be_empty
      end

      it "holds CAP END until BOTH the sasl exchange and the other REQ have settled" do
        client.send(:handle_line, line(":irc.example.org CAP * LS :sasl=PLAIN message-tags"))
        writes.clear

        # sasl is still authenticating, so CAP END must not appear yet or
        # registration would race it.
        client.send(:handle_line, line(":irc.example.org CAP rubotty ACK :message-tags"))
        expect(writes).to be_empty

        client.send(:handle_line, line(":irc.example.org CAP rubotty ACK :sasl"))
        expect(writes).to eq(["AUTHENTICATE PLAIN\r\n"])

        client.send(:handle_line, line(":irc.example.org 903 rubotty :SASL authentication successful"))
        expect(writes.last).to eq("CAP END\r\n")
      end

      it "still ends CAP once settled when sasl is NAKed but the rest is ACKed" do
        client.send(:handle_line, line(":irc.example.org CAP * LS :sasl=PLAIN message-tags"))
        writes.clear

        client.send(:handle_line, line(":irc.example.org CAP rubotty NAK :sasl"))
        expect(writes).to be_empty # message-tags' REQ has not settled yet

        client.send(:handle_line, line(":irc.example.org CAP rubotty ACK :message-tags"))
        expect(writes).to eq(["CAP END\r\n"])
        expect(client.negotiated_capabilities).to eq(["message-tags"])
      end
    end
  end

  # Parsing the inbound tag prefix into the event Client hands the adapter,
  # gated on negotiation.
  describe "message-tags on inbound PRIVMSG" do
    subject(:client) do
      described_class.new(server: "irc.example.org", nick: "rubotty", logger: logger)
    end

    let(:events) { [] }

    before do
      client.on_message { |event| events << event }
      # A settled negotiation with no real CAP round trip.
      client.instance_variable_set(:@negotiated_caps, negotiated)
    end

    def line(raw) = Rubotty::Adapters::Irc::Protocol.parse(raw)

    context "with message-tags, msgid and server-time negotiated" do
      let(:negotiated) { Set.new(%w[message-tags msgid server-time]) }

      it "carries the server assigned msgid through to the event" do
        client.send(:handle_line, line("@msgid=abc123 :ada!u@h PRIVMSG #room :hello"))
        expect(events.first["msgid"]).to eq("abc123")
      end

      it "carries a +draft/reply target through to the event" do
        client.send(:handle_line, line("@msgid=2;+draft/reply=abc123 :ada!u@h PRIVMSG #room :sure"))
        expect(events.first["reply_to"]).to eq("abc123")
      end

      it "parses server-time's tag into a real Time" do
        client.send(:handle_line, line("@time=2011-10-19T16:40:51.620Z :ada!u@h PRIVMSG #room :hi"))
        expect(events.first["timestamp"]).to eq(Time.iso8601("2011-10-19T16:40:51.620Z"))
      end
    end

    context "with nothing negotiated (a plain IRC server)" do
      let(:negotiated) { Set.new }

      it "still delivers the message, with no msgid, reply target or timestamp" do
        client.send(:handle_line, line("@msgid=abc123 :ada!u@h PRIVMSG #room :hello"))
        event = events.first
        expect(event["body"]).to eq("hello")
        expect(event["msgid"]).to be_nil
        expect(event["timestamp"]).to be_nil
      end
    end
  end

  # A TAGMSG carrying both +draft/reply and +draft/react is how a reaction
  # crosses the wire; there is no separate add or remove form.
  describe "client-only reaction tags (TAGMSG)" do
    subject(:client) do
      described_class.new(server: "irc.example.org", nick: "rubotty", logger: logger)
    end

    let(:events) { [] }

    before do
      client.on_message { |event| events << event }
      client.instance_variable_set(:@negotiated_caps, Set.new(%w[message-tags msgid]))
    end

    def line(raw) = Rubotty::Adapters::Irc::Protocol.parse(raw)

    it "delivers a reaction event from a TAGMSG carrying both tags" do
      client.send(:handle_line, line("@+draft/reply=abc123;+draft/react=\u{1F44D} :ada!u@h TAGMSG #room"))
      event = events.first
      expect(event["kind"]).to eq("reaction")
      expect(event["target_msgid"]).to eq("abc123")
      expect(event["reaction"]).to eq("\u{1F44D}")
    end

    it "ignores a TAGMSG missing either tag" do
      client.send(:handle_line, line("@+draft/react=\u{1F44D} :ada!u@h TAGMSG #room"))
      expect(events).to be_empty
    end

    it "ignores a TAGMSG when message-tags was never negotiated" do
      client.instance_variable_set(:@negotiated_caps, Set.new)
      client.send(:handle_line, line("@+draft/reply=abc123;+draft/react=\u{1F44D} :ada!u@h TAGMSG #room"))
      expect(events).to be_empty
    end

    it "never relays our own echoed TAGMSG" do
      client.send(:handle_line, line("@+draft/reply=abc123;+draft/react=\u{1F44D} :rubotty!u@h TAGMSG #room"))
      expect(events).to be_empty
    end
  end

  describe "membership: JOIN, PART, QUIT and KICK" do
    subject(:client) do
      described_class.new(server: "irc.example.org", nick: "rubotty", logger: logger)
    end

    let(:events) { [] }

    before { client.on_message { |event| events << event } }

    def line(raw) = Rubotty::Adapters::Irc::Protocol.parse(raw)

    it "relays a JOIN as a join event" do
      client.send(:handle_line, line(":ada!u@host JOIN #general"))
      expect(events.first).to include("channel" => "#general", "nick" => "ada", "kind" => "join")
    end

    it "does not relay our own JOIN confirming us in the channel" do
      client.send(:handle_line, line(":rubotty!u@host JOIN #general"))
      expect(events).to be_empty
    end

    it "relays a PART as a leave event" do
      client.send(:handle_line, line(":ada!u@host JOIN #general"))
      client.send(:handle_line, line(":ada!u@host PART #general :bye"))
      expect(events.last).to include("channel" => "#general", "nick" => "ada", "kind" => "leave")
    end

    it "relays a KICK as a leave event naming the kicked nick" do
      client.send(:handle_line, line(":op!u@host KICK #general ada :spamming"))
      expect(events.last).to include("channel" => "#general", "nick" => "ada", "kind" => "leave")
    end

    it "logs rather than relaying a leave when the bot itself is kicked" do
      client.send(:handle_line, line(":op!u@host KICK #general rubotty :bye"))
      expect(events).to be_empty
      expect(logger.warnings).not_to be_empty
    end

    it "relays a QUIT as a leave on every channel it shared with that nick" do
      client.send(:handle_line, line(":ada!u@host JOIN #general"))
      client.send(:handle_line, line(":ada!u@host JOIN #ops"))
      client.send(:handle_line, line(":ada!u@host QUIT :goodbye"))

      channels = events.select { |e| e["kind"] == "leave" }.map { |e| e["channel"] }
      expect(channels).to contain_exactly("#general", "#ops")
    end

    it "does not relay a QUIT for a nick it never saw join or speak" do
      client.send(:handle_line, line(":ghost!u@host QUIT :gone"))
      expect(events).to be_empty
    end

    it "also learns membership from an ordinary PRIVMSG" do
      client.send(:handle_line, line(":ada!u@host PRIVMSG #general :hi"))
      events.clear
      client.send(:handle_line, line(":ada!u@host QUIT :bye"))
      expect(events.last).to include("channel" => "#general", "kind" => "leave")
    end

    it "re-keys tracked membership on a live NICK change, so a later QUIT under the new nick still relays" do
      client.send(:handle_line, line(":ada!u@host JOIN #general"))
      client.send(:handle_line, line(":ada!u@host NICK :ada2"))
      client.send(:handle_line, line(":ada2!u@host QUIT :bye"))

      expect(events.last).to include("channel" => "#general", "nick" => "ada2", "kind" => "leave")
    end
  end

  describe "NOTICE" do
    let(:events) { [] }

    before { client.on_message { |event| events << event } }

    def line(raw) = Rubotty::Adapters::Irc::Protocol.parse(raw)

    it "relays a channel NOTICE the same way a channel PRIVMSG is relayed" do
      client.send(:handle_line, line(":ChanServ!services@host NOTICE #general :the channel is now +m"))
      expect(events.first).to include("channel" => "#general", "nick" => "ChanServ", "body" => "the channel is now +m")
    end

    it "does not relay a NOTICE addressed only to us, only logs it" do
      client.send(:handle_line, line(":NickServ!services@host NOTICE rubotty :This nickname is registered."))
      expect(events).to be_empty
      expect(logger.infos).not_to be_empty
    end
  end

  describe "433 nickname-in-use during registration" do
    before { client.instance_variable_set(:@registered, false) }

    def line(raw) = Rubotty::Adapters::Irc::Protocol.parse(raw)

    it "retries registration under a fallback nick rather than failing outright" do
      client.send(:handle_line, line(":irc.example.org 433 * rubotty :Nickname is already in use."))
      expect(writes).to eq(["NICK rubotty_\r\n"])
      expect(client.nick).to eq("rubotty_")
    end

    it "keeps appending underscores on repeated collisions" do
      3.times { client.send(:handle_line, line(":irc.example.org 433 * x :Nickname is already in use.")) }
      expect(client.nick).to eq("rubotty___")
    end

    it "fails the connection once MAX_NICK_RETRIES is exhausted" do
      stub_const("#{described_class}::MAX_NICK_RETRIES", 1)
      client.send(:handle_line, line(":irc.example.org 433 * rubotty :Nickname is already in use."))
      writes.clear
      client.send(:handle_line, line(":irc.example.org 433 * rubotty_ :Nickname is already in use."))

      expect(writes).to be_empty
      expect(client.instance_variable_get(:@ready).pop(timeout: 0.1)).to include("nickname already in use")
    end

    it "does not retry a 433 once registration has already completed" do
      client.send(:handle_line, line(":irc.example.org 001 rubotty :Welcome"))
      writes.clear
      client.send(:handle_line, line(":irc.example.org 433 * rubotty :Nickname is already in use."))

      expect(writes).to be_empty
    end
  end

  # #privmsg's return value depends on an echo arriving on the read loop, so
  # its wait runs on its own thread, signalled by a Thread::Queue when the
  # write happens. A message with several hard newlines becomes that many
  # wire PRIVMSGs, uncapped; unpaced, that is a flood kill waiting to happen.
  describe "#privmsg pacing consecutive wire lines" do
    it "waits at least SEND_INTERVAL between the first line and the second" do
      stub_const("#{described_class}::SEND_INTERVAL", 0.03)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      client.privmsg("#general", "line one\nline two")
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(elapsed).to be >= 0.03
      expect(writes).to eq(["PRIVMSG #general :line one\r\n", "PRIVMSG #general :line two\r\n"])
    end

    it "does not delay a message that fits on a single wire line" do
      stub_const("#{described_class}::SEND_INTERVAL", 5)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      client.privmsg("#general", "one line only")
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(elapsed).to be < 1
    end
  end

  describe "#privmsg capturing a msgid via echo-message" do
    subject(:client) do
      described_class.new(server: "irc.example.org", nick: "rubotty", logger: logger)
    end

    def line(raw) = Rubotty::Adapters::Irc::Protocol.parse(raw)

    it "returns the msgid from the echo when echo-message and msgid are both negotiated" do
      client.instance_variable_set(:@negotiated_caps, Set.new(%w[message-tags echo-message msgid]))
      sent = Thread::Queue.new
      allow(socket).to receive(:write) { |data| writes << data; sent << true }

      result = nil
      thread = Thread.new { result = client.privmsg("#general", "hello") }
      sent.pop(timeout: 2) # #privmsg has written, so its echo wait is registered (same critical section)
      client.send(:handle_line, line("@msgid=srv-1 :rubotty!u@h PRIVMSG #general :hello"))
      thread.join(2)

      expect(result).to eq("srv-1")
      expect(writes).to eq(["PRIVMSG #general :hello\r\n"])
    end

    it "falls back to nil, not an error, when the echo never arrives" do
      client.instance_variable_set(:@negotiated_caps, Set.new(%w[message-tags echo-message msgid]))
      stub_const("#{described_class}::ECHO_TIMEOUT", 0.05)

      expect(client.privmsg("#general", "hello")).to be_nil
    end

    it "returns nil with no wait at all when echo-message was not negotiated" do
      client.instance_variable_set(:@negotiated_caps, Set.new(%w[message-tags msgid]))
      expect(client.privmsg("#general", "hello")).to be_nil
    end

    it "does not let one timed out echo permanently offset the FIFO for later sends" do
      client.instance_variable_set(:@negotiated_caps, Set.new(%w[message-tags echo-message msgid]))
      stub_const("#{described_class}::ECHO_TIMEOUT", 0.05)

      expect(client.privmsg("#general", "one")).to be_nil # nothing fed, times out

      sent = Thread::Queue.new
      allow(socket).to receive(:write) { |data| writes << data; sent << true }
      second = nil
      thread = Thread.new { second = client.privmsg("#general", "two") }
      sent.pop(timeout: 2)
      client.send(:handle_line, line("@msgid=srv-2 :rubotty!u@h PRIVMSG #general :two"))
      thread.join(2)

      expect(second).to eq("srv-2")
    end
  end

  # A stand in for the TCP/TLS socket, blocking on both directions through a
  # Thread::Queue so a spec can step through the reactive CAP exchange with no
  # sleep. Never bind it to +let(:socket)+: the top level +before+ hook stubs
  # #write on whatever +socket+ resolves to, which would clobber the real one.
  class ScriptedIrcSocket
    def initialize
      @replies = Thread::Queue.new
      @writes = Thread::Queue.new
    end

    def write(data)
      @writes << data
      data.bytesize
    end

    def gets = @replies.pop

    def feed(reply) = (@replies << "#{reply}\r\n")

    def next_write(timeout: 2) = @writes.pop(timeout: timeout)

    def close = nil
  end

  # CAP LS 302 must be safe to send unconditionally, and #connect must complete
  # on the 001 numeric alone, never hanging for a CAP reply a plain server will
  # never send.
  describe "#connect against a server with no CAP support" do
    subject(:client) do
      described_class.new(server: "irc.example.org", nick: "rubotty", logger: logger)
    end

    let(:irc_socket) { ScriptedIrcSocket.new }

    before { allow(client).to receive(:open_socket).and_return(irc_socket) }

    after { client.close }

    it "registers via plain NICK/USER and returns once 001 arrives, never having sent CAP END" do
      result = nil
      thread = Thread.new { result = client.connect(ready_timeout: 2) }

      expect(irc_socket.next_write).to eq("CAP LS 302\r\n")
      expect(irc_socket.next_write).to eq("NICK rubotty\r\n")
      expect(irc_socket.next_write).to eq("USER rubotty 0 * :rubotty\r\n")

      # A CAP unaware server ignores "CAP LS 302" and just welcomes the connection.
      irc_socket.feed("001 rubotty :Welcome")

      thread.join(2)
      expect(result).to eq(client)
      expect(client.negotiated_capabilities).to eq([])
    end
  end

  # A CAP aware server withholds 001 until CAP END, so #connect completes only
  # once the exchange has settled.
  describe "#connect against a modern, IRCv3 capable server" do
    subject(:client) do
      described_class.new(server: "irc.example.org", nick: "rubotty", logger: logger)
    end

    let(:irc_socket) { ScriptedIrcSocket.new }

    before { allow(client).to receive(:open_socket).and_return(irc_socket) }

    after { client.close }

    it "negotiates across a multiline LS and only registers after CAP END" do
      thread = Thread.new { client.connect(ready_timeout: 2) }

      expect(irc_socket.next_write).to eq("CAP LS 302\r\n")
      expect(irc_socket.next_write).to eq("NICK rubotty\r\n")
      expect(irc_socket.next_write).to eq("USER rubotty 0 * :rubotty\r\n")

      irc_socket.feed(":irc.example.org CAP * LS * :message-tags server-time msgid")
      irc_socket.feed(":irc.example.org CAP * LS :echo-message sasl=PLAIN unsupported-cap")

      expect(irc_socket.next_write).to eq("CAP REQ :message-tags server-time msgid echo-message\r\n")
      irc_socket.feed(":irc.example.org CAP rubotty ACK :message-tags server-time msgid echo-message")

      expect(irc_socket.next_write).to eq("CAP END\r\n")
      irc_socket.feed("001 rubotty :Welcome")

      thread.join(2)
      expect(client.negotiated_capabilities).to contain_exactly(
        "message-tags", "server-time", "msgid", "echo-message"
      )
    end
  end

  # 001 never arrives, whether the server stays silent or refuses
  # registration outright, and #connect must not return as if it did.
  describe "#connect when the server never welcomes us" do
    subject(:client) do
      described_class.new(server: "irc.example.org", nick: "rubotty", logger: logger)
    end

    let(:irc_socket) { ScriptedIrcSocket.new }

    before { allow(client).to receive(:open_socket).and_return(irc_socket) }

    after { client.close }

    it "raises rather than returning once ready_timeout elapses with total silence" do
      expect { client.connect(ready_timeout: 0.05) }.to raise_error(Rubotty::AdapterError, /never sent 001/)
    end

    it "raises with the server's own reason when a registration numeral arrives instead" do
      thread = Thread.new { client.connect(ready_timeout: 2) }
      3.times { irc_socket.next_write } # CAP LS 302, NICK, USER
      irc_socket.feed(":irc.example.org 464 * rubotty :Password incorrect.")

      expect { thread.value }.to raise_error(Rubotty::AdapterError, /password incorrect/)
    end

    it "retries under a fallback nick on 433, and only fails once the retries are exhausted" do
      stub_const("#{described_class}::MAX_NICK_RETRIES", 1)
      thread = Thread.new { client.connect(ready_timeout: 2) }
      3.times { irc_socket.next_write } # CAP LS 302, NICK, USER
      irc_socket.feed(":irc.example.org 433 * rubotty :Nickname is already in use.")

      expect(irc_socket.next_write).to eq("NICK rubotty_\r\n")
      irc_socket.feed(":irc.example.org 433 * rubotty_ :Nickname is already in use.")

      expect { thread.value }.to raise_error(Rubotty::AdapterError, /nickname already in use/)
    end
  end

  # Deletes are gated on the server advertising message-redaction, with no
  # client-only substitute.
  describe "#redact" do
    it "sends REDACT with the channel and the target message's msgid" do
      client.redact("#general", "srv-42")
      expect(writes).to eq(["REDACT #general srv-42\r\n"])
    end

    it "includes a reason when one is given" do
      client.redact("#general", "srv-42", reason: "off topic")
      expect(writes).to eq(["REDACT #general srv-42 :off topic\r\n"])
    end

    it "walks every id a wrapped #privmsg crossed as, and the first" do
      client.instance_variable_set(:@negotiated_caps, Set.new(%w[message-tags echo-message msgid]))
      sent = Thread::Queue.new
      allow(socket).to receive(:write) { |data| writes << data; sent << true }
      parse = ->(raw) { Rubotty::Adapters::Irc::Protocol.parse(raw) }

      first_id = nil
      thread = Thread.new { first_id = client.privmsg("#general", "one\ntwo") }
      sent.pop(timeout: 2)
      client.send(:handle_line, parse.call("@msgid=srv-1 :rubotty!u@h PRIVMSG #general :one"))
      sent.pop(timeout: 2)
      client.send(:handle_line, parse.call("@msgid=srv-2 :rubotty!u@h PRIVMSG #general :two"))
      thread.join(2)
      expect(first_id).to eq("srv-1")

      writes.clear
      client.redact("#general", first_id)
      expect(writes).to eq(["REDACT #general srv-1\r\n", "REDACT #general srv-2\r\n"])
    end
  end

  # There is no request id, so a moderation error numeral is matched to the
  # oldest in-flight kick/ban/unban command against the same channel.
  describe "#kick, #ban and #unban reading moderation errors" do
    def line(raw) = Rubotty::Adapters::Irc::Protocol.parse(raw)

    def kick_and_capture_error
      sent = Thread::Queue.new
      allow(socket).to receive(:write) { |data| writes << data; sent << true }
      error = nil
      thread = Thread.new do
        client.kick("#ops", "troll")
      rescue StandardError => e
        error = e
      end
      sent.pop(timeout: 2)
      yield
      thread.join(2)
      error
    end

    it "raises a PermissionError when the server answers 482 (not a channel operator)" do
      stub_const("#{described_class}::MODERATION_TIMEOUT", 2)
      error = kick_and_capture_error do
        client.send(:handle_line, line(":irc.example.org 482 rubotty #ops :You're not channel operator"))
      end
      expect(error).to be_a(Rubotty::PermissionError)
    end

    it "raises a plain AdapterError when the target is not on the channel (441)" do
      stub_const("#{described_class}::MODERATION_TIMEOUT", 2)
      error = kick_and_capture_error do
        client.send(:handle_line, line(":irc.example.org 441 rubotty troll #ops :They aren't on that channel"))
      end
      expect(error).to be_a(Rubotty::AdapterError)
      expect(error).not_to be_a(Rubotty::PermissionError)
    end

    it "treats silence within the window as success, exactly as before this existed" do
      stub_const("#{described_class}::MODERATION_TIMEOUT", 0.05)
      expect { client.kick("#general", "troll") }.not_to raise_error
    end

    it "does not let a refusal on a different channel fail an unrelated command" do
      stub_const("#{described_class}::MODERATION_TIMEOUT", 0.05)
      client.send(:handle_line, line(":irc.example.org 482 rubotty #other :You're not channel operator"))
      expect { client.kick("#general", "troll") }.not_to raise_error
    end
  end

  describe "#ban and #unban writing a hostmask, when one has been observed" do
    def line(raw) = Rubotty::Adapters::Irc::Protocol.parse(raw)

    before { stub_const("#{described_class}::MODERATION_TIMEOUT", 0.02) }

    it "bans on the observed user@host once a JOIN has been seen from the target" do
      client.send(:handle_line, line(":troll!ident@10.0.0.5 JOIN #general"))
      client.ban("#general", "troll")
      expect(writes).to include("MODE #general +b *!ident@10.0.0.5\r\n")
    end

    it "falls back to a nick-only mask when nothing has been observed for the target" do
      client.ban("#general", "ghost")
      expect(writes).to include("MODE #general +b ghost!*@*\r\n")
    end

    it "also learns the hostmask from an ordinary PRIVMSG" do
      client.send(:handle_line, line(":troll!ident@10.0.0.5 PRIVMSG #general :hi"))
      client.ban("#general", "troll")
      expect(writes).to include("MODE #general +b *!ident@10.0.0.5\r\n")
    end

    it "unbans with the same mask it would ban with right now" do
      client.send(:handle_line, line(":troll!ident@10.0.0.5 JOIN #general"))
      client.unban("#general", "troll")
      expect(writes).to include("MODE #general -b *!ident@10.0.0.5\r\n")
    end
  end
end
