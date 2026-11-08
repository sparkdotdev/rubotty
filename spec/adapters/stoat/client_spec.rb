# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Adapters::Stoat::Client do
  # Records every request and replies from a scripted queue, so the real client
  # runs with no socket.
  class StoatFakeHttp
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

  let(:http) { StoatFakeHttp.new }

  subject(:client) do
    described_class.new(token: "secret-token", http: http)
  end

  it "authenticates every request with the x-bot-token header" do
    http.on(200, %({"_id":"me"}))
    client.own_id
    expect(http.last.headers["x-bot-token"]).to eq("secret-token")
  end

  it "reads the bot's own id from /users/@me" do
    http.on(200, %({"_id":"01BOTID"}))
    expect(client.own_id).to eq("01BOTID")
    expect(http.last.uri.path).to eq("/users/@me")
  end

  it "posts a message to the channel messages endpoint" do
    http.on(200, %({"_id":"01MSG"}))
    result = client.send_message("CHAN01", content: "hi")
    expect(http.last.verb).to eq(:post)
    expect(http.last.uri.path).to eq("/channels/CHAN01/messages")
    expect(JSON.parse(http.last.body)).to eq("content" => "hi")
    expect(result["_id"]).to eq("01MSG")
  end

  it "adds a reaction with the emoji in the path" do
    http.on(200, "")
    client.add_reaction("CHAN01", "01MSG", "👍")
    expect(http.last.verb).to eq(:put)
    expect(http.last.uri.path).to include("/reactions/")
  end

  it "returns nil for a 2xx with an empty body, as a delete gives" do
    http.on(204, "")
    expect(client.delete_message("CHAN01", "01MSG")).to be_nil
  end

  it "maps a 403 to a PermissionError" do
    http.on(403, %({"type":"MissingPermission"}))
    expect { client.send_message("CHAN01", content: "x") }
      .to raise_error(Rubotty::PermissionError, /MissingPermission/)
  end

  it "maps a 429 to a RateLimitedError with the wait in seconds" do
    http.on(429, %({"retry_after":2000}))
    expect { client.send_message("CHAN01", content: "x") }
      .to raise_error(Rubotty::RateLimitedError) { |error| expect(error.retry_after).to eq(2) }
  end

  it "builds a credential free CDN URL for an inbound file" do
    url = client.file_url("_id" => "f1", "filename" => "a.png", "tag" => "attachments")
    expect(url).to eq("https://cdn.stoatusercontent.com/attachments/f1/a.png")
  end

  # A Stoat filename is whatever the uploader called it, unescaped free
  # text, so a space or another character a URL cannot carry as-is has to
  # be encoded. Handed straight to a webhook as avatar_url, an unescaped
  # space produced a URL the target platform's API could refuse outright.
  it "escapes a filename that is not already URL safe" do
    url = client.file_url("_id" => "f1", "filename" => "my photo.png", "tag" => "attachments")
    expect { URI.parse(url) }.not_to raise_error
    expect(url).not_to include(" ")
  end

  # A path segment spells a space %20. Form encoding spells it "+", which reads
  # back as a space in a query string and as a literal plus in a path, so the CDN
  # would be asked for a file under a name nothing has.
  it "spells a space in the path as %20 rather than a plus" do
    url = client.file_url("_id" => "f1", "filename" => "my photo.png", "tag" => "attachments")
    expect(url).to end_with("/my%20photo.png")
    expect(url).not_to include("+")
  end

  describe "#fetch_channel (channel discovery, issue #203)" do
    it "fetches a channel by id" do
      http.on(200, %({"_id":"CHAN01","channel_type":"TextChannel","name":"general"}))
      result = client.fetch_channel("CHAN01")
      expect(http.last.verb).to eq(:get)
      expect(http.last.uri.path).to eq("/channels/CHAN01")
      expect(result["name"]).to eq("general")
    end

    it "returns nil rather than raising when the bot can no longer see the channel" do
      http.on(404, %({"type":"NotFound"}))
      expect(client.fetch_channel("gone")).to be_nil
    end

    it "returns nil for a nil id with no request made" do
      expect(client.fetch_channel(nil)).to be_nil
      expect(http.requests).to be_empty
    end
  end

  # A nickname chosen inside one server lives on the member, not the account,
  # so this is the only place a per server name can be read from.
  describe "#fetch_member" do
    it "fetches a member from the server members endpoint" do
      http.on(200, %({"_id":{"server":"SRV1","user":"u-ada"},"nickname":"Ada in SAMPLE"}))
      result = client.fetch_member("SRV1", "u-ada")
      expect(http.last.verb).to eq(:get)
      expect(http.last.uri.path).to eq("/servers/SRV1/members/u-ada")
      expect(result["nickname"]).to eq("Ada in SAMPLE")
    end

    it "unwraps the member out of a roles-bearing response" do
      http.on(200, %({"member":{"nickname":"Ada in SAMPLE"},"roles":{}}))
      expect(client.fetch_member("SRV1", "u-ada")["nickname"]).to eq("Ada in SAMPLE")
    end

    it "returns nil rather than raising for a member the bot cannot see" do
      http.on(404, %({"type":"NotFound"}))
      expect(client.fetch_member("SRV1", "stranger")).to be_nil
    end

    it "returns nil for a missing id with no request made" do
      expect(client.fetch_member(nil, "u-ada")).to be_nil
      expect(client.fetch_member("SRV1", nil)).to be_nil
      expect(http.requests).to be_empty
    end
  end
end
