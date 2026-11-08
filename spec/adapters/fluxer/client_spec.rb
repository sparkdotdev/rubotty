# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Adapters::Fluxer::Client do
  class FluxerFakeHttp
    Response = Struct.new(:code, :body)
    Request = Struct.new(:verb, :uri, :headers, :body)

    def initialize
      @requests = []
      @queue = []
    end

    attr_reader :requests

    def on(code, body) = (@queue << Response.new(code, body))

    def request(verb, uri, headers: {}, body: nil)
      @requests << Request.new(verb, uri, headers, body)
      @queue.shift || Response.new(200, "")
    end

    def last = @requests.last
  end

  let(:http) { FluxerFakeHttp.new }

  subject(:client) { described_class.new(token: "secret-token", http: http) }

  it "authenticates every request with an Authorization: Bot header" do
    http.on(200, %({"id":"me"}))
    client.own_id
    expect(http.last.headers["authorization"]).to eq("Bot secret-token")
  end

  it "posts a message to the channel messages endpoint" do
    http.on(200, %({"id":"01MSG"}))
    result = client.send_message("111", content: "hi")
    expect(http.last.verb).to eq(:post)
    expect(http.last.uri.host).to eq("api.fluxer.app")
    expect(http.last.uri.path).to eq("/channels/111/messages")
    expect(JSON.parse(http.last.body)).to eq("content" => "hi")
    expect(result["id"]).to eq("01MSG")
  end

  it "lists the guilds the bot belongs to" do
    http.on(200, %([{"id":"8000000000000000008","name":"Example Gaming Community"}]))
    guilds = client.list_guilds
    expect(http.last.verb).to eq(:get)
    expect(http.last.uri.to_s).to end_with("/users/@me/guilds")
    expect(guilds.map { |guild| guild["name"] }).to eq(["Example Gaming Community"])
  end

  it "lists one guild's channels with their types" do
    http.on(200, %([{"id":"10","name":"general","type":0},{"id":"11","name":"Lounge","type":2}]))
    channels = client.list_guild_channels("8000000000000000008")
    expect(http.last.uri.to_s).to end_with("/guilds/8000000000000000008/channels")
    expect(channels.map { |channel| channel["type"] }).to eq([0, 2])
  end

  it "raises a PermissionError when a guild refuses its channel listing" do
    http.on(403, %({"message":"Missing Access"}))
    expect { client.list_guild_channels("1") }.to raise_error(Rubotty::PermissionError, /Missing Access/)
  end

  it "executes a webhook with wait=true so the created id comes back" do
    http.on(200, %({"id":"01WHMSG"}))
    client.execute_webhook("wh1", "tok", content: "hi")
    expect(http.last.uri.query).to include("wait=true")
    expect(http.last.uri.path).to eq("/webhooks/wh1/tok")
  end

  it "returns nil for a 2xx empty body, as a delete gives" do
    http.on(204, "")
    expect(client.delete_message("111", "01MSG")).to be_nil
  end

  it "maps a 403 to a PermissionError and a 429 to a RateLimitedError" do
    http.on(403, %({"message":"Missing Permissions"}))
    expect { client.send_message("111", content: "x") }.to raise_error(Rubotty::PermissionError)

    http.on(429, %({"retry_after":1.5}))
    expect { client.send_message("111", content: "x") }
      .to raise_error(Rubotty::RateLimitedError) { |e| expect(e.retry_after).to eq(2) }
  end

  it "sends a multipart message carrying a payload_json part and one files[n] part per file" do
    http.on(200, %({"id":"01MSG"}))
    file = StringIO.new("PNGDATA")
    client.send_message_with_files("111", { content: "hi" },
                                   [{ filename: "a.png", mime_type: "image/png", io: file }])

    expect(http.last.verb).to eq(:post)
    expect(http.last.uri.path).to eq("/channels/111/messages")
    expect(http.last.headers["content-type"]).to start_with("multipart/form-data; boundary=")
    expect(http.last.body).to include(%(name="payload_json"))
    expect(http.last.body).to include(%(name="files[0]"; filename="a.png"))
    expect(http.last.body).to include("Content-Type: image/png")
    expect(http.last.body).to include("PNGDATA")
  end

  it "leaves a guild through DELETE /users/@me/guilds/:id" do
    http.on(204, "")
    client.leave_guild("999")
    expect(http.last.verb).to eq(:delete)
    expect(http.last.uri.path).to eq("/users/@me/guilds/999")
  end

  it "pins and unpins a message" do
    http.on(204, "")
    client.pin_message("111", "900")
    expect(http.last.verb).to eq(:put)
    expect(http.last.uri.path).to eq("/channels/111/pins/900")

    http.on(204, "")
    client.unpin_message("111", "900")
    expect(http.last.verb).to eq(:delete)
    expect(http.last.uri.path).to eq("/channels/111/pins/900")
  end

  # The general request path compacts a nil out of the body before it is
  # sent, which would silently turn "clear this timeout" into "change
  # nothing": the API only clears communication_disabled_until on a literal
  # null, never on a missing key.
  it "sends a literal null to clear a timeout rather than dropping the key" do
    http.on(200, %({"id":"u1"}))
    client.timeout_member("g1", "u1", nil, reason: nil)

    expect(http.last.verb).to eq(:patch)
    expect(http.last.uri.path).to eq("/guilds/g1/members/u1")
    body = JSON.parse(http.last.body)
    expect(body).to have_key("communication_disabled_until")
    expect(body["communication_disabled_until"]).to be_nil
  end

  it "sends a real timeout timestamp when muting" do
    http.on(200, %({"id":"u1"}))
    client.timeout_member("g1", "u1", "2026-01-01T00:00:00Z", reason: "bridged by mod")

    body = JSON.parse(http.last.body)
    expect(body["communication_disabled_until"]).to eq("2026-01-01T00:00:00Z")
    expect(body["timeout_reason"]).to eq("bridged by mod")
  end

  # A nickname chosen inside one guild lives on the member, not the account, so
  # this is the only place a per-guild name can be read from (issue #904).
  describe "#fetch_member" do
    it "fetches a member from the guild members endpoint" do
      http.on(200, %({"nick":"Server Alex","user":{"id":"55","username":"alex"}}))
      result = client.fetch_member("g1", "55")
      expect(http.last.verb).to eq(:get)
      expect(http.last.uri.path).to eq("/guilds/g1/members/55")
      expect(result["nick"]).to eq("Server Alex")
    end

    it "returns nil rather than raising for a member the bot cannot see" do
      http.on(404, %({"message":"Unknown Member"}))
      expect(client.fetch_member("g1", "stranger")).to be_nil
    end

    it "returns nil for a missing id with no request made" do
      expect(client.fetch_member(nil, "55")).to be_nil
      expect(client.fetch_member("g1", nil)).to be_nil
      expect(http.requests).to be_empty
    end
  end
end
