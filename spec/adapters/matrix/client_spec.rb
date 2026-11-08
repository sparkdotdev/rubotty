# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Adapters::Matrix::Client do
  class MatrixFakeHttp
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
      @queue.shift || Response.new(200, "{}")
    end

    def last = @requests.last
  end

  let(:http) { MatrixFakeHttp.new }

  subject(:client) do
    described_class.new(access_token: "secret-token", homeserver: "https://example.org", http: http)
  end

  it "authenticates every request with a Bearer access token" do
    http.on(200, %({"user_id":"@bot:example.org"}))
    expect(client.whoami).to eq("@bot:example.org")
    expect(http.last.headers["authorization"]).to eq("Bearer secret-token")
    expect(http.last.uri.path).to eq("/_matrix/client/v3/account/whoami")
  end

  it "sends a room event through a versioned send path and returns its id" do
    http.on(200, %({"event_id":"$abc"}))
    id = client.send_event("!room:example.org", "m.room.message", { "body" => "hi" }, txn_id: "tx1")
    expect(http.last.verb).to eq(:put)
    # The room id's `!` and `:` are percent encoded in the path, as Matrix requires.
    expect(http.last.uri.path).to eq("/_matrix/client/v3/rooms/%21room%3Aexample.org/send/m.room.message/tx1")
    expect(id).to eq("$abc")
  end

  it "builds an unauthenticated media download URL from an mxc uri" do
    url = client.media_http_url("mxc://example.org/abc123")
    expect(url).to eq("https://example.org/_matrix/media/v3/download/example.org/abc123")
  end

  it "maps M_LIMIT_EXCEEDED (429) to a RateLimitedError with the wait in seconds" do
    http.on(429, %({"errcode":"M_LIMIT_EXCEEDED","error":"slow down","retry_after_ms":2000}))
    expect { client.send_event("!room:example.org", "m.room.message", {}, txn_id: "t") }
      .to raise_error(Rubotty::RateLimitedError) { |e| expect(e.retry_after).to eq(2) }
  end

  it "maps M_FORBIDDEN (403) to a PermissionError" do
    http.on(403, %({"errcode":"M_FORBIDDEN","error":"no"}))
    expect { client.kick("!room:example.org", "@bad:example.org") }.to raise_error(Rubotty::PermissionError)
  end

  it "accepts an invite through the versioned join path, returning the joined room id" do
    http.on(200, %({"room_id":"!joined:example.org"}))
    expect(client.join_room("#alias:example.org")).to eq("!joined:example.org")
    expect(http.last.verb).to eq(:post)
    expect(http.last.uri.path).to eq("/_matrix/client/v3/join/%23alias%3Aexample.org")
  end

  it "leaves a room, the same call whether joined or only invited" do
    http.on(200, "{}")
    client.leave_room("!room:example.org")
    expect(http.last.verb).to eq(:post)
    expect(http.last.uri.path).to eq("/_matrix/client/v3/rooms/%21room%3Aexample.org/leave")
  end

  # The client-server API lists every room the account has joined outright.
  describe "room enumeration" do
    it "lists joined rooms from the client-server API" do
      http.on(200, %({"joined_rooms":["!a:example.org","!b:example.org"]}))
      expect(client.joined_rooms).to eq(%w[!a:example.org !b:example.org])
      expect(http.last.uri.path).to eq("/_matrix/client/v3/joined_rooms")
    end

    it "answers an empty array, never nil, when the account has joined nothing" do
      http.on(200, %({"joined_rooms":[]}))
      expect(client.joined_rooms).to eq([])
    end

    it "reads a room's published name" do
      http.on(200, %({"name":"General"}))
      expect(client.room_name("!room:example.org")).to eq("General")
      expect(http.last.uri.path).to eq("/_matrix/client/v3/rooms/%21room%3Aexample.org/state/m.room.name")
    end

    it "treats a missing m.room.name state event (404) as no name, not an error" do
      http.on(404, %({"errcode":"M_NOT_FOUND","error":"not found"}))
      expect(client.room_name("!room:example.org")).to be_nil
    end

    it "reads a room's published canonical alias" do
      http.on(200, %({"alias":"#general:example.org"}))
      expect(client.room_canonical_alias("!room:example.org")).to eq("#general:example.org")
    end

    it "treats a missing canonical alias (404) as none, not an error" do
      http.on(404, %({"errcode":"M_NOT_FOUND","error":"not found"}))
      expect(client.room_canonical_alias("!room:example.org")).to be_nil
    end
  end

  # /messages pages backward from a token; a backfill sweep's first page has
  # none in hand yet, which is the cursor-acquisition step itself.
  describe "history pagination" do
    it "asks for no from on the first page, which a homeserver resolves to the live end of the room" do
      http.on(200, %({"chunk":[{"event_id":"$a"}],"end":"tok1"}))
      events, next_token = client.messages("!room:example.org", dir: "b", limit: 50)
      expect(http.last.uri.query).not_to include("from=")
      expect(http.last.uri.query).to include("dir=b").and include("limit=50")
      expect(events).to eq([{ "event_id" => "$a" }])
      expect(next_token).to eq("tok1")
    end

    it "carries a given token as from for a later page" do
      http.on(200, %({"chunk":[],"end":"tok2"}))
      client.messages("!room:example.org", from: "tok1", dir: "b")
      expect(http.last.uri.query).to include("from=tok1")
    end

    it "answers no next token once the room has nothing older left" do
      http.on(200, %({"chunk":[{"event_id":"$last"}]}))
      _events, next_token = client.messages("!room:example.org", from: "tok9")
      expect(next_token).to be_nil
    end
  end

  # Reaction backfill reads the relations family, which is v1 only.
  describe "relations" do
    it "reads a page of m.annotation relations from the v1 path" do
      http.on(200, %({"chunk":[{"event_id":"$r1"}]}))
      chunk = client.relations("!room:example.org", "$target", limit: 50)
      expect(http.last.uri.path).to eq(
        "/_matrix/client/v1/rooms/%21room%3Aexample.org/relations/%24target/m.annotation"
      )
      expect(http.last.uri.query).to include("limit=50")
      expect(chunk).to eq([{ "event_id" => "$r1" }])
    end

    it "answers an empty array, never nil, when a message has none" do
      http.on(200, %({"chunk":[]}))
      expect(client.relations("!room:example.org", "$target")).to eq([])
    end
  end

  # The write half #media_http_url has no counterpart for.
  describe "media upload" do
    it "posts raw bytes with the file's own content type and gets back an mxc uri" do
      http.on(200, %({"content_uri":"mxc://example.org/newid"}))
      uri = client.upload("PNGDATA", filename: "a.png", content_type: "image/png")
      expect(http.last.verb).to eq(:post)
      expect(http.last.uri.path).to eq("/_matrix/media/v3/upload")
      expect(http.last.uri.query).to include("filename=a.png")
      expect(http.last.headers["content-type"]).to eq("image/png")
      expect(http.last.body).to eq("PNGDATA")
      expect(uri).to eq("mxc://example.org/newid")
    end

    it "defaults to application/octet-stream and carries no filename when none is given" do
      http.on(200, %({"content_uri":"mxc://example.org/newid"}))
      client.upload("BYTES")
      expect(http.last.headers["content-type"]).to eq("application/octet-stream")
      expect(http.last.uri.query.to_s).not_to include("filename")
    end

    it "still authenticates with the bearer token" do
      http.on(200, %({"content_uri":"mxc://example.org/newid"}))
      client.upload("BYTES")
      expect(http.last.headers["authorization"]).to eq("Bearer secret-token")
    end
  end
end
