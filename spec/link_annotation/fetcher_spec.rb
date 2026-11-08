# frozen_string_literal: true

require "spec_helper"

# The URL here comes from whoever typed it into a room, which makes this the
# most exposed outbound call rubotty has. Every bound is checked.
RSpec.describe Rubotty::LinkAnnotation::Fetcher do
  let(:public_resolver) { ->(_host) { ["93.184.216.34"] } }

  def fetcher(resolver: public_resolver, **rest)
    described_class.new(logger: Rubotty::Log.null, resolver: resolver, **rest)
  end

  # A response the case/when in the fetcher can actually match, since it
  # dispatches on Net::HTTPSuccess and Net::HTTPRedirection rather than on a
  # status string.
  def response(klass, code, headers = {}, chunks = [])
    klass.new("1.1", code, "").tap do |instance|
      headers.each { |name, value| instance[name] = value }
      instance.define_singleton_method(:read_body) { |&block| chunks.each(&block) }
    end
  end

  # Stands in for the socket: every hop pins a fresh Net::HTTP to the address the guard
  # validated, so this stubs Net::HTTP.new rather than the class method Net::HTTP.start,
  # which the fetcher no longer calls.
  def serving(*responses)
    queue = responses.dup
    http = instance_double(Net::HTTP)
    allow(Net::HTTP).to receive(:new).and_return(http)
    allow(http).to receive(:ipaddr=)
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)
    allow(http).to receive(:start)
    allow(http).to receive(:started?).and_return(true)
    allow(http).to receive(:finish)
    allow(http).to receive(:request) { |_request, &handler| handler.call(queue.shift) }
    http
  end

  describe "the SSRF guard" do
    it "refuses a host that resolves into a reserved range, before connecting" do
      expect(Net::HTTP).not_to receive(:new)

      expect(fetcher(resolver: ->(_) { ["169.254.169.254"] }).call(URI("https://metadata.example/"))).to be_nil
    end

    it "refuses a name that answers with one public and one private address" do
      expect(Net::HTTP).not_to receive(:new)

      expect(fetcher(resolver: ->(_) { ["93.184.216.34", "127.0.0.1"] }).call(URI("https://x.example/"))).to be_nil
    end

    it "refuses a host that resolves to nothing" do
      expect(fetcher(resolver: ->(_) { [] }).call(URI("https://x.example/"))).to be_nil
    end
  end

  it "refuses a URL that is not https, so no member can put a plaintext request on the wire" do
    expect(Net::HTTP).not_to receive(:new)

    expect(fetcher.call(URI("http://example.com/"))).to be_nil
  end

  it "returns a page for a plain success" do
    serving(response(Net::HTTPOK, "200", { "content-type" => "text/html; charset=utf-8" },
                     ['<html lang="de"><body>Hallo</body></html>']))

    page = fetcher.call(URI("https://example.com/a"))

    expect(page.html).to include("lang=\"de\"")
    expect(page.requested.to_s).to eq("https://example.com/a")
  end

  it "follows a redirect and remembers where it started, so the landing can be checked" do
    serving(response(Net::HTTPFound, "302", { "location" => "https://other.example/b" }),
            response(Net::HTTPOK, "200", { "content-type" => "text/html" }, ["<html>hi</html>"]))

    page = fetcher.call(URI("https://example.com/a"))

    expect(page.url.to_s).to eq("https://other.example/b")
    expect(page.requested.to_s).to eq("https://example.com/a")
  end

  it "gives up rather than following a redirect chain forever" do
    loops = Array.new(6) { response(Net::HTTPFound, "302", { "location" => "https://example.com/next" }) }
    serving(*loops)

    expect(fetcher.call(URI("https://example.com/a"))).to be_nil
  end

  it "refuses a redirect that would leave https" do
    serving(response(Net::HTTPFound, "302", { "location" => "http://example.com/b" }))

    expect(fetcher.call(URI("https://example.com/a"))).to be_nil
  end

  # Content-Length is written by the remote server, so the cap is enforced on
  # the bytes as they arrive.
  it "stops reading at the byte cap however much the server wants to send" do
    serving(response(Net::HTTPOK, "200", { "content-type" => "text/html" }, ["x" * 400, "y" * 400, "z" * 400]))

    page = fetcher(limit: 500).call(URI("https://example.com/a"))

    expect(page.html.bytesize).to be <= 800
    expect(page.html).not_to include("z")
  end

  it "does not download something with no language in it" do
    serving(response(Net::HTTPOK, "200", { "content-type" => "application/pdf" }, ["%PDF"]))

    expect(fetcher.call(URI("https://example.com/a.pdf"))).to be_nil
  end

  it "is quiet about a page that answered with an error" do
    serving(response(Net::HTTPNotFound, "404"))

    expect(fetcher.call(URI("https://example.com/a"))).to be_nil
  end

  # A Latin-1 page read as UTF-8 loses exactly the accented characters the
  # function word lists are counting.
  it "decodes the body using the charset the response declares" do
    serving(response(Net::HTTPOK, "200", { "content-type" => "text/html; charset=iso-8859-1" },
                     ["<html><body>caf\xE9</body></html>".dup.force_encoding("BINARY")]))

    expect(fetcher.call(URI("https://example.com/a")).html).to include("café")
  end

  it "answers nil rather than raising when the connection fails" do
    http = instance_double(Net::HTTP)
    allow(Net::HTTP).to receive(:new).and_return(http)
    allow(http).to receive(:ipaddr=)
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)
    allow(http).to receive(:start).and_raise(Errno::ECONNREFUSED)

    expect(fetcher.call(URI("https://example.com/a"))).to be_nil
  end

  # The guard has to validate the answer that is actually connected to.
  # guard_public_address! resolved the hostname and refused a private answer,
  # but the fetcher then handed the hostname to Net::HTTP.start, which resolved
  # it again when opening the socket: a short DNS TTL could answer public to the guard, private to the connection.
  describe "a rebinding host" do
    # Answers public once, to the guard, and would answer loopback to
    # anything that asked a second time. Recorded so the spec can prove there
    # was no second lookup at all.
    let(:lookups) { [] }
    let(:rebinding_resolver) do
      lambda do |host|
        lookups << host
        lookups.length == 1 ? ["93.184.216.34"] : ["127.0.0.1"]
      end
    end

    it "connects to the address the guard validated, not to a fresh lookup" do
      pinned = []
      http = instance_double(Net::HTTP)
      allow(Net::HTTP).to receive(:new).and_return(http)
      allow(http).to receive(:ipaddr=) { |value| pinned << value }
      allow(http).to receive(:use_ssl=)
      allow(http).to receive(:open_timeout=)
      allow(http).to receive(:read_timeout=)
      allow(http).to receive(:start)
      allow(http).to receive(:started?).and_return(true)
      allow(http).to receive(:finish)
      allow(http).to receive(:request) do |_request, &handler|
        handler.call(response(Net::HTTPOK, "200", { "content-type" => "text/html" }, ["<html>hi</html>"]))
      end

      fetcher(resolver: rebinding_resolver).call(URI("https://rebind.example/a"))

      expect(pinned).to eq(["93.184.216.34"])
      expect(lookups).to eq(["rebind.example"])
    end
  end
end
