# frozen_string_literal: true

require "spec_helper"
require "rubotty/scripting"

# Outbound HTTP for scripts, by name. Unrestricted outbound access is a proxy for
# scanning somebody's internal network, so the assertions worth reading are the
# refusals: a script reaches only what an administrator listed, on the host listed.
RSpec.describe Rubotty::Scripting::Endpoints, :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:community) { models.community.first }

  # Every address resolves to something public unless a test says otherwise, so the
  # guard is exercised rather than sidestepped.
  let(:resolver) { ->(_host) { ["93.184.216.34"] } }
  let(:requests) { [] }
  let(:response) do
    streaming_response("---\ntemp: 19\n", "application/yaml")
  end

  subject(:endpoints) do
    described_class.new(models: models, logger: Rubotty::Log.null, resolver: resolver,
                        executor: ->(work) { work.call })
  end

  def define(name: "weather", url: "https://api.example.com/w?city={city}", **rest)
    now = Time.now
    models.script_endpoint.create({
      community_id: community.id, name: name, url: url, http_method: "GET",
      headers: JSON.generate("Authorization" => "Bearer secret-key"),
      allow_sync: true, timeout_seconds: 2, cache_seconds: 0, enabled: true,
      created_at: now, updated_at: now
    }.merge(rest))
  end

  # Stands in for the socket, recording what would have gone out.
  def stub_http!
    http = instance_double(Net::HTTP)
    allow(Net::HTTP).to receive(:new).and_return(http)
    allow(http).to receive(:use_ssl=)
    # The connection is pinned to the address the guard validated.
    allow(http).to receive(:ipaddr=)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)
    allow(http).to receive(:request) { |req, &block| requests << req; block ? block.call(response) : response }
    http
  end

  # Drives the live path. enqueue is the only caller in lib, and the injected runner lets a
  # spec run the job here and keep what it produced, so these assertions are about the code
  # that really executes.
  def call(name, params = {}, body: nil, scope: community)
    produced = nil
    endpoints.enqueue(scope, name, params, body: body) { |job| produced = job.call }
    produced
  end

  describe "calling a defined endpoint" do
    it "returns the decoded YAML answer" do
      define
      stub_http!

      result = call("weather", { "city" => "Lisbon" })

      expect(result.ok).to be(true)
      expect(result.data).to eq({ "temp" => 19 })
      expect(result.format).to eq("yaml")
    end

    it "asks for YAML, using the type RFC 9512 registered" do
      define
      stub_http!

      call("weather", {})

      expect(requests.first["Accept"]).to eq("application/yaml")
    end

    # A YAML document can name a Ruby class to instantiate, and this is a third
    # party's YAML. The reader builds core schema types only, so the tag is read
    # past and what the script sees is the plain mapping underneath it.
    it "will not instantiate a Ruby object an endpoint asks for" do
      define
      hostile = streaming_response("--- !ruby/object:Gem::Requirement\nx: 1\n", "application/yaml")
      http = stub_http!
      allow(http).to receive(:request) { |req, &block| requests << req; block.call(hostile) }

      result = call("weather", {})

      expect(result.data).to eq({ "x" => 1 })
      expect(result.data).to be_an_instance_of(Hash)
      expect(result.format).to eq("yaml")
    end

    it "hands anything that is not YAML back as text, decoded to nothing" do
      define
      plain = streaming_response("just words", "text/plain")
      http = stub_http!
      allow(http).to receive(:request) { |req, &block| requests << req; block.call(plain) }

      result = call("weather", {})

      expect(result.format).to eq("text")
      expect(result.data).to be_nil
      expect(result.body).to eq("just words")
    end

    it "substitutes parameters into the url, encoded" do
      define
      stub_http!

      call("weather", { "city" => "São Paulo" })

      expect(requests.first.uri.to_s).to include("city=S%C3%A3o+Paulo")
    end

    # The key belongs to the endpoint, so an operator writing a rule never
    # handles it and a script can never read it back.
    it "sends the endpoint's headers, which the script never sees" do
      define
      stub_http!

      result = call("weather", {})

      expect(requests.first["Authorization"]).to eq("Bearer secret-key")
      expect(result.to_lua.to_s).not_to include("secret-key")
    end
  end

  # The parts an administrator writes down, which belong to whoever owns the endpoint
  # because they are what the far end expects.
  describe "what the administrator configured" do
    it "adds the query parameters set on the endpoint" do
      define(url: "https://api.example.com/w",
             query_params: JSON.generate("town" => "{city}", "units" => "metric"))
      stub_http!

      call("weather", { "city" => "Lisbon" })

      query = URI.decode_www_form(requests.first.uri.query.to_s).to_h
      expect(query).to include("town" => "Lisbon", "units" => "metric")
    end

    it "keeps what the URL already carried and adds to it" do
      define(url: "https://api.example.com/w?city={city}",
             query_params: JSON.generate("units" => "metric"))
      stub_http!

      call("weather", { "city" => "Lisbon" })

      query = URI.decode_www_form(requests.first.uri.query.to_s).to_h
      expect(query).to include("city" => "Lisbon", "units" => "metric")
    end

    # The body is the script's table, so a POST given only query parameters sends
    # those rather than needing the same table twice.
    it "sends the script's own table as the body of a POST" do
      define(http_method: "POST", url: "https://api.example.com/w")
      stub_http!

      call("weather", { "city" => "Lisbon" })

      expect(YAMLCamel.load(requests.first.body)).to eq({ "city" => "Lisbon" })
    end

    # A value a script supplies must not be able to add a parameter of its own.
    it "encodes a value that would otherwise open a second parameter" do
      define(url: "https://api.example.com/w", query_params: JSON.generate("town" => "{city}"))
      stub_http!

      call("weather", { "city" => "Lisbon&admin=1" })

      query = URI.decode_www_form(requests.first.uri.query.to_s).to_h
      expect(query).to eq({ "town" => "Lisbon&admin=1" })
    end
  end

  # The body used to be validated by the caller and then dropped, leaving a POST
  # endpoint with the query table as its body.
  describe "the body a script passes" do
    it "sends it, rather than the query table" do
      define(http_method: "POST", url: "https://api.example.com/w")
      stub_http!

      endpoints.enqueue(community, "weather", { "city" => "Lisbon" },
                        body: { "note" => "hello" }) { |job| job.call }

      expect(YAMLCamel.load(requests.first.body)).to eq({ "note" => "hello" })
    end

    # The table a script passed is what goes out, written as YAML by Ruby rather than
    # substituted into a document somebody else typed.
    it "sends the table as it stands, with no shape configured over it" do
      define(http_method: "POST", url: "https://api.example.com/w")
      stub_http!

      endpoints.enqueue(community, "weather", {}, body: { "note" => "kept" }) { |job| job.call }

      expect(YAMLCamel.load(requests.first.body)).to eq({ "note" => "kept" })
    end

    # A value with a colon or a newline in it used to be pasted into the
    # administrator's document as text, where it could reshape the document around it.
    it "writes a value that would have broken a document it was pasted into" do
      define(http_method: "POST", url: "https://api.example.com/w")
      stub_http!

      awkward = { "note" => "hello: world\nfixed: no" }
      endpoints.enqueue(community, "weather", {}, body: awkward) { |job| job.call }

      expect(YAMLCamel.load(requests.first.body)).to eq(awkward)
    end

    it "falls back to the params when no body was passed at all" do
      define(http_method: "POST", url: "https://api.example.com/w")
      stub_http!

      endpoints.enqueue(community, "weather", { "city" => "Lisbon" }) { |job| job.call }

      expect(YAMLCamel.load(requests.first.body)).to eq({ "city" => "Lisbon" })
    end
  end

  describe "what it refuses" do
    it "refuses a name nobody defined" do
      expect { call("internal", {}) }
        .to raise_error(described_class::Refused, /no endpoint called/)
    end

    it "refuses another community's endpoint" do
      define
      other = models.community.create(slug: "other", name: "Other", status: "active",
                                      created_at: Time.now, updated_at: Time.now)

      expect { call("weather", {}, scope: other) }.to raise_error(described_class::Refused)
    end

    it "refuses a disabled endpoint" do
      define(enabled: false)

      expect { call("weather", {}) }.to raise_error(described_class::Refused)
    end

    # Encoding is what actually stops a path parameter moving the request: a
    # value with @ and / in it comes out percent encoded and stays in the path.
    it "encodes a parameter that tries to escape the path, leaving the host alone" do
      define(url: "https://api.example.com/{path}")
      stub_http!

      call("weather", { "path" => "..@evil.example/x" })

      expect(requests.first.uri.host).to eq("api.example.com")
      expect(requests.first.uri.to_s).to include("%40evil.example%2Fx")
    end

    # The case encoding cannot cover: a placeholder in the HOST. Whitelisting a name
    # and then letting a script choose the name is the same as having no whitelist.
    it "refuses a template whose host is itself a parameter" do
      define(url: "https://{host}/x")
      stub_http!

      expect { call("weather", { "host" => "evil.example" }) }
        .to raise_error(described_class::Refused, /change the host/)
    end

    # A whitelisted domain whose DNS points at link-local is the classic way round a
    # name-based whitelist, so the address is checked at connect time.
    it "refuses a host that resolves to a private address" do
      define
      metadata = described_class.new(models: models, logger: Rubotty::Log.null,
                                     resolver: ->(_host) { ["169.254.169.254"] }, executor: ->(work) { work.call })

      expect { begin
        produced = nil
        metadata.enqueue(community, "weather", {}) { |job| produced = job.call }
        produced
      end }
        .to raise_error(described_class::Refused, /non public/)
    end

    it "refuses a host that resolves to loopback" do
      define
      local = described_class.new(models: models, logger: Rubotty::Log.null,
                                  resolver: ->(_host) { ["127.0.0.1"] }, executor: ->(work) { work.call })

      expect { begin
        produced = nil
        local.enqueue(community, "weather", {}) { |job| produced = job.call }
        produced
      end }.to raise_error(described_class::Refused)
    end
  end

  describe "enqueue" do
    it "hands the work over and returns straight away" do
      define(allow_sync: false)
      jobs = []

      expect(endpoints.enqueue(community, "weather", {}) { |job| jobs << job }).to be(true)
      expect(jobs.length).to eq(1)
    end

    it "asks nothing about how the endpoint was configured before handing over" do
      define(allow_sync: false)

      expect { endpoints.enqueue(community, "weather", {}) { |_| nil } }.not_to raise_error
    end
  end
end

# YAML in both directions, everywhere, with no exception for an endpoint that
# happens to answer in something else.
RSpec.describe Rubotty::Scripting::Endpoints, "reading what came back", :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:community) { models.community.first }
  let(:resolver) { ->(_host) { ["93.184.216.34"] } }
  let(:endpoints) do
    described_class.new(models: models, logger: Rubotty::Log.null, resolver: resolver,
                        executor: ->(work) { work.call })
  end

  def answered(body, type)
    now = Time.now
    models.script_endpoint.create(community_id: community.id, name: "weather",
                                  url: "https://api.example.com/w", http_method: "GET",
                                  allow_sync: true, timeout_seconds: 2, cache_seconds: 0,
                                  enabled: true, created_at: now, updated_at: now)
    answer = streaming_response(body, type)
    http = instance_double(Net::HTTP)
    allow(Net::HTTP).to receive(:new).and_return(http)
    allow(http).to receive(:use_ssl=)
    # The connection is pinned to the address the guard validated.
    allow(http).to receive(:ipaddr=)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)
    allow(http).to receive(:request) { |_req, &block| block ? block.call(answer) : answer }
    produced = nil
    endpoints.enqueue(community, "weather", {}) { |job| produced = job.call }
    produced
  end

  # JSON is a subset of YAML 1.2, so the loader would take it. Refused anyway, since
  # an endpoint quietly accepting something else is how a second format gets back in.
  it "hands over nothing for a JSON answer, whatever the loader could do with it" do
    result = answered('{"town":"Lisbon"}', "application/json")

    expect(result.data).to be_nil
    expect(result.format).to eq("text")
  end

  it "reads YAML" do
    result = answered("town: Lisbon\n", "application/yaml")

    expect(result.data).to eq("town" => "Lisbon")
    expect(result.format).to eq("yaml")
  end

  it "hands over nothing for a page of HTML" do
    result = answered("<html>hello</html>", "text/html")

    expect(result.data).to be_nil
    expect(result.format).to eq("text")
  end

  it "says what the far end claimed, and reads a tagged document as plain data" do
    result = answered("--- !ruby/object:Gem::Requirement\nx: 1\n", "application/yaml")

    expect(result.data).to eq({ "x" => 1 })
    expect(result.format).to eq("yaml")
  end
end
