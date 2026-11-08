# frozen_string_literal: true

require "spec_helper"
require "rubotty/api"
require "socket"

# Api::App#write_body_params called rack.input#rewind before reading it, but
# Rack does not promise a rewindable input, and the WEBrick handler this app
# ships on has none, so every structured write 500ed in production while
# Rack::Test specs (whose input is always a rewindable StringIO) stayed green.
RSpec.describe "a YAML request body over a non-rewindable input", :control_plane do
  # A stand-in for Rackup::Handler::WEBrick::Input: readable once, forward
  # only, no #rewind method at all (not even one that raises).
  class NonRewindableInput
    def initialize(data)
      @io = StringIO.new(data.to_s)
    end

    def read(*args) = @io.read(*args)
    def gets(*args) = @io.gets(*args)
    def each(&block) = @io.each(&block)
    def close = @io.close
  end

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }
  let(:deps) { Rubotty::Api::Deps.new(db: db, logger: Rubotty::Log.null, rate_max: 1000) }
  let(:app) { Rubotty::Api::App.assemble(deps: deps, env: {}) }
  let(:keys) { Rubotty::ControlPlane::ApiKeys.new(models: models) }
  let(:token) { keys.issue(scope: "developer", community: community, label: "non-rewindable body test").token }

  # Calls the real Sinatra app directly (no Rack::Test in the middle, since
  # Rack::Test is exactly the layer that hid this bug) with rack.input
  # swapped for a double that cannot be rewound.
  def call_with_body(body, content_type: "application/yaml")
    env = Rack::MockRequest.env_for(
      "/communities/sample/features/faq",
      method: "PATCH",
      input: body,
      "CONTENT_TYPE" => content_type,
      "HTTP_AUTHORIZATION" => "Bearer #{token}"
    )
    env["rack.input"] = NonRewindableInput.new(body)
    status, headers, body_parts = app.call(env)
    [status, headers, body_parts.to_ary.join]
  end

  it "PATCHes a valid YAML mapping body" do
    status, _headers, body = call_with_body("enabled: true\n")
    expect(status).to eq(200)
    expect(YAMLCamel.load(body)["enabled"]).to be(true)
  end

  it "treats an empty body as no fields rather than an error" do
    # feature_entry! 404s a feature with no row at all, which is unrelated to
    # this bug, so give it one first the same way the enabled-state specs do.
    deps.feature_controls.enable(community: community, selector: "all", feature: "faq")

    status, _headers, = call_with_body("")
    expect(status).to eq(200)
  end

  it "400s a malformed YAML body instead of 500ing" do
    status, _headers, body = call_with_body("enabled: [true\n")
    expect(status).to eq(400)
    expect(YAMLCamel.load(body)["error"]).to include("YAML")
  end

  it "still handles a form-encoded body exactly as before" do
    status, _headers, body = call_with_body("enabled=true", content_type: "application/x-www-form-urlencoded")
    expect(status).to eq(200)
    expect(YAMLCamel.load(body)["enabled"]).to be(true)
  end

  # Closer still to production: the real Sinatra app served through the same
  # Rackup::Handler::WEBrick class the deployed process uses, hit over an
  # actual socket and bound on port 0 to avoid fighting over a fixed one,
  # probed with a raw TCPSocket since spec_helper puts Net::HTTP off limits.
  context "through a real WEBrick server", :control_plane do
    require "rackup"
    require "rackup/handler/webrick"

    let(:server) do
      Rackup::Handler::WEBrick::Server.new(
        app,
        BindAddress: "127.0.0.1",
        Port: 0,
        Logger: WEBrick::Log.new(File::NULL),
        AccessLog: []
      )
    end

    before { @thread = Thread.new { server.start } }

    after do
      server.shutdown
      @thread&.join(5)
    end

    def bound_port
      server.listeners.first.addr[1]
    end

    def patch_over_socket(path, body, content_type:)
      socket = TCPSocket.new("127.0.0.1", bound_port)
      socket.write(
        "PATCH #{path} HTTP/1.0\r\n" \
        "Host: 127.0.0.1\r\n" \
        "Authorization: Bearer #{token}\r\n" \
        "Content-Type: #{content_type}\r\n" \
        "Content-Length: #{body.bytesize}\r\n" \
        "\r\n#{body}"
      )
      response = socket.read.to_s
      status_line = response.lines.first.to_s
      [status_line[/\d{3}/], response.split("\r\n\r\n", 2).last]
    ensure
      socket&.close
    end

    it "PATCHes a YAML body without 500ing, the exact production shape" do
      status, body = patch_over_socket(
        "/communities/sample/features/faq", "enabled: true\n", content_type: "application/yaml"
      )
      expect(status).to eq("200")
      expect(YAMLCamel.load(body)["enabled"]).to be(true)
    end
  end
end
