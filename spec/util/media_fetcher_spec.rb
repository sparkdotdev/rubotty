# frozen_string_literal: true

require "spec_helper"

# The media fetcher is the one place a remote server hands this process an
# arbitrary URL to open. These specs cover the SSRF guard: a URL or redirect
# must never steer the fetch at loopback, a private range, link-local space
# (the 169.254.169.254 cloud metadata endpoint above all) or an IPv6 unique local address.
RSpec.describe Rubotty::Util::MediaFetcher do
  subject(:fetcher) { described_class.new }

  # Stands in for one Net::HTTP connection. It records the address it was pinned
  # to and hands that to the block, which decides whether opening works, so a
  # spec can make one address family unreachable without a socket.
  class FakeConnection
    attr_accessor :ipaddr

    def initialize(body: "bytes", &opener)
      @body = body
      @opener = opener
      @started = false
    end

    def use_ssl=(value); end

    def open_timeout=(value); end

    def read_timeout=(value); end

    def started? = @started

    def start
      @opener&.call(@ipaddr)
      @started = true
    end

    def finish
      @started = false
    end

    # A real Net::HTTPOK, because the fetcher decides what to do with a response
    # by its class.
    def request(_message)
      response = Net::HTTPOK.new("1.1", "200", "OK")
      body = @body
      response.define_singleton_method(:read_body) { |&block| block.call(body) }
      yield response
    end
  end

  def guard(url)
    fetcher.send(:guard_public_address!, URI.parse(url))
  end

  describe "the SSRF host guard" do
    {
      "IPv4 loopback" => "https://127.0.0.1/a.jpg",
      "an RFC1918 10.x address" => "https://10.1.2.3/a.jpg",
      "an RFC1918 192.168.x address" => "https://192.168.1.5/a.jpg",
      "the cloud metadata endpoint" => "https://169.254.169.254/latest/meta-data/",
      "IPv6 loopback" => "https://[::1]/a.jpg",
      "an IPv6 unique local (fc00::/7) address" => "https://[fc00::1]/a.jpg"
    }.each do |label, url|
      it "refuses #{label}" do
        expect { guard(url) }.to raise_error(described_class::Error)
      end
    end

    it "allows a normal public address" do
      expect { guard("https://93.184.216.34/a.jpg") }.not_to raise_error
    end

    # An IPv4 mapped IPv6 address is a classic way to smuggle a private target
    # past a guard that only understands one family.
    it "unwraps an IPv4 mapped IPv6 address before checking it" do
      expect { guard("https://[::ffff:169.254.169.254]/a.jpg") }.to raise_error(described_class::Error)
    end

    # The host may be a name rather than a literal IP, so the guard has to
    # resolve it. A name that resolves into a private range must still lose.
    it "resolves a hostname and refuses it when it points at a private address" do
      resolving = described_class.new(resolver: ->(_host) { ["10.0.0.9"] })
      expect { resolving.send(:guard_public_address!, URI.parse("https://cdn.example.com/a.jpg")) }
        .to raise_error(described_class::Error)
    end

    it "refuses a host that resolves to nothing rather than failing open" do
      unresolvable = described_class.new(resolver: ->(_host) { [] })
      expect { unresolvable.send(:guard_public_address!, URI.parse("https://nowhere.example.com/a.jpg")) }
        .to raise_error(described_class::Error)
    end
  end

  # A host answering in both families used to pin the fetch to whichever address came back
  # first. api.telegram.org answers AAAA first and the deployment has no working IPv6 route,
  # so every Telegram photo bound for Discord stalled until the open timeout and was dropped.
  describe "a host with more than one address" do
    let(:dual_stack) { ->(_host) { ["2001:67c:4e8:f004::9", "149.154.167.220"] } }

    it "hands back every validated address rather than only the first" do
      fetcher = described_class.new(resolver: dual_stack)
      addresses = fetcher.send(:guard_public_address!, URI.parse("https://api.telegram.org/a.jpg"))

      expect(addresses).to contain_exactly("2001:67c:4e8:f004::9", "149.154.167.220")
    end

    it "tries IPv4 before IPv6, since that is the family this deployment routes" do
      fetcher = described_class.new(resolver: dual_stack)
      addresses = fetcher.send(:guard_public_address!, URI.parse("https://api.telegram.org/a.jpg"))

      expect(addresses.first).to eq("149.154.167.220")
    end

    # The regression itself: the first address is unreachable and the second is
    # not, and the file has to arrive anyway.
    it "falls through to the next address when the first will not connect" do
      attempted = []
      allow(Net::HTTP).to receive(:new) do
        FakeConnection.new do |address|
          attempted << address
          raise Net::OpenTimeout, "Failed to open TCP connection to #{address}" if address.include?(":")
        end
      end

      # Resolved IPv6 first, so the fetch only works if it tries the other one.
      fetcher = described_class.new(resolver: dual_stack, sleeper: ->(_seconds) {})
      file = fetcher.fetch("https://api.telegram.org/file/bot123/photos/file_110.jpg")

      expect(attempted).to eq(["149.154.167.220"])
      expect(file).not_to be_nil
      file.close
      file.unlink
    end

    it "still reaches a host whose only working family is the one tried second" do
      attempted = []
      allow(Net::HTTP).to receive(:new) do
        FakeConnection.new do |address|
          attempted << address
          raise Net::OpenTimeout, "Failed to open TCP connection to #{address}" unless address.include?(":")
        end
      end

      fetcher = described_class.new(resolver: dual_stack, sleeper: ->(_seconds) {})
      file = fetcher.fetch("https://api.telegram.org/a.jpg")

      expect(attempted).to eq(["149.154.167.220", "2001:67c:4e8:f004::9"])
      expect(file).not_to be_nil
      file.close
      file.unlink
    end

    # The security property, pinned by a test rather than by reading: a single
    # non public answer refuses the whole request. Dropping it from the list and
    # using the rest would be a guard that can be walked past.
    it "refuses outright when any address in the list is not public" do
      mixed = described_class.new(resolver: ->(_host) { ["149.154.167.220", "169.254.169.254"] })

      expect { mixed.send(:guard_public_address!, URI.parse("https://api.telegram.org/a.jpg")) }
        .to raise_error(described_class::Error, /non public/)
    end

    it "never opens a connection when one address in the list is not public" do
      connected = false
      allow(Net::HTTP).to receive(:new) { connected = true }
      mixed = described_class.new(resolver: ->(_host) { ["149.154.167.220", "10.0.0.9"] })

      expect(mixed.fetch("https://api.telegram.org/a.jpg")).to be_nil
      expect(connected).to be(false)
    end
  end

  describe "retrying" do
    let(:public_host) { ->(_host) { ["93.184.216.34"] } }

    it "tries again when the network faults, so one bad moment is not the message" do
      starts = 0
      allow(Net::HTTP).to receive(:new) do
        FakeConnection.new do |_address|
          starts += 1
          raise Errno::ECONNRESET if starts == 1
        end
      end

      fetcher = described_class.new(resolver: public_host, sleeper: ->(_seconds) {})
      file = fetcher.fetch("https://cdn.example.com/a.jpg")

      expect(starts).to eq(2)
      expect(file).not_to be_nil
      file.close
      file.unlink
    end

    it "does not retry a refusal, since a blocked address is a decision" do
      lookups = 0
      blocked = lambda do |_host|
        lookups += 1
        ["169.254.169.254"]
      end

      expect(described_class.new(resolver: blocked).fetch("https://cdn.example.com/a.jpg")).to be_nil
      expect(lookups).to eq(1)
    end
  end

  describe "the total download deadline" do
    it "interrupts a body that keeps producing chunks and removes its partial file" do
      response = Net::HTTPOK.new("1.1", "200", "OK")
      allow(response).to receive(:read_body) do |&block|
        100.times { block.call("x"); sleep 0.02 }
      end
      connection = FakeConnection.new
      allow(connection).to receive(:request) { |_request, &block| block.call(response) }
      allow(Net::HTTP).to receive(:new).and_return(connection)
      partial = nil
      allow(Tempfile).to receive(:new).and_wrap_original do |original, *args, **keywords|
        partial = original.call(*args, **keywords)
      end
      limited = described_class.new(timeout: 0.08, resolver: ->(_) { ["93.184.216.34"] })
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      expect(limited.fetch("https://cdn.example/test.png")).to be_nil

      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 0.8
      expect(partial).to be_closed
      expect(partial.path).to be_nil
    end

    it "includes DNS resolution in the same deadline" do
      resolving = described_class.new(timeout: 0.05, resolver: ->(_) { sleep 5; ["93.184.216.34"] })
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      expect(resolving.fetch("https://cdn.example/test.png")).to be_nil
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 0.8
    end

    it "does not give another address a fresh time budget" do
      now = 0.0
      attempts = 0
      allow(Net::HTTP).to receive(:new) do
        FakeConnection.new do |_address|
          attempts += 1
          now += 2
          raise Net::OpenTimeout
        end
      end
      limited = described_class.new(timeout: 1, clock: -> { now }, sleeper: ->(_) {},
        resolver: ->(_) { ["93.184.216.34", "93.184.216.35"] })

      expect(limited.fetch("https://cdn.example/test.png")).to be_nil
      expect(attempts).to eq(1)
    end
  end

  # A self hosted deployment without a certificate, or one only reachable on a LAN address,
  # is the exact shape verbatim relay (Discord, Stoat, Fluxer and Matrix all download and
  # reupload a relayed attachment now) needs to degrade out of rather than crash on: the room
  # still gets a message, just with a "could not be relayed" note instead of the file.
  describe "a scheme or address this deployment will not fetch" do
    it "refuses a plain http url without raising" do
      expect(fetcher.fetch("http://cdn.example.com/a.jpg")).to be_nil
    end

    it "allows plain http only once explicitly configured insecure" do
      allow(Net::HTTP).to receive(:new) { FakeConnection.new }
      insecure = described_class.new(allow_insecure: true, resolver: ->(_host) { ["93.184.216.34"] })

      expect(insecure.fetch("http://cdn.example.com/a.jpg")).not_to be_nil
    end
  end

  # The cap has to hold even when nothing upstream can be trusted to have reported a size:
  # Content-Length is a header the remote server controls, and Telegram's own file_size is
  # optional on top of that, so the only enforcement that can be trusted counts bytes as they
  # actually arrive.
  describe "the byte limit" do
    it "refuses a body over the limit while it streams, not by trusting a claimed size" do
      allow(Net::HTTP).to receive(:new) { FakeConnection.new(body: "x" * 10_000) }
      tight = described_class.new(limit: 10, resolver: ->(_host) { ["93.184.216.34"] })

      expect(tight.fetch("https://cdn.example.com/a.jpg")).to be_nil
    end

    it "keeps a body within the limit" do
      allow(Net::HTTP).to receive(:new) { FakeConnection.new(body: "x" * 10) }
      exact = described_class.new(limit: 10, resolver: ->(_host) { ["93.184.216.34"] })

      file = exact.fetch("https://cdn.example.com/a.jpg")
      expect(file).not_to be_nil
      file.close
      file.unlink
    end
  end

  describe "fetching" do
    it "refuses a blocked address before opening any connection" do
      connected = false
      allow(Net::HTTP).to receive(:start) { connected = true }

      expect(fetcher.fetch("https://169.254.169.254/latest/meta-data/")).to be_nil
      expect(connected).to be(false)
    end

    # A public first hop that redirects to a private target is the exact shape
    # a naive one time check misses, so the guard has to run again on the hop.
    it "re-checks the address on a redirect hop and never connects to the private target" do
      connected = false
      allow(Net::HTTP).to receive(:start) { connected = true }

      redirect = { "location" => "https://169.254.169.254/latest/meta-data/" }
      origin = URI.parse("https://cdn.example.com/pic.jpg")

      expect { fetcher.send(:follow, redirect, origin, nil, 3) }
        .to raise_error(described_class::Error)
      expect(connected).to be(false)
    end
  end
end
