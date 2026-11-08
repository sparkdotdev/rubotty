# frozen_string_literal: true

require "spec_helper"
require "rubotty/api"
require "rack/test"

# Posting into a room and watching one live, driven in-process with rack-test over
# the seeded SAMPLE control plane. room_key is unique only within a community, so
# "general" exists in nearly every tenant: a developer key naming another
# community's room gets a 404, never a 403 that would confirm the room is there.
RSpec.describe "the REST API's live messaging", :control_plane do
  include Rack::Test::Methods

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }
  let(:room) { models.room.where(community_id: community.id, room_key: "general").first }
  let(:deps) { Rubotty::Api::Deps.new(db: db, logger: Rubotty::Log.null, rate_max: 200) }
  let(:app) { Rubotty::Api::App.assemble(deps: deps, env: {}) }
  let(:keys) { Rubotty::ControlPlane::ApiKeys.new(models: models) }
  let(:buffer) { Rubotty::ControlPlane::LiveRoomFeed.new(models: models) }

  # A second tenant whose room is called "general" too, so a lookup that forgot to
  # scope by community serves the wrong one.
  def other_community
    now = Time.now
    other = models.community.create(
      slug: "other-co", name: "Other Co", status: "active", settings: "{}",
      created_at: now, updated_at: now
    )
    models.room.create(
      community_id: other.id, room_key: "general", label: "General",
      display_name: "{}", created_at: now, updated_at: now
    )
    other
  end

  def developer_token(on: community)
    keys.issue(scope: "developer", community: on, label: "test developer key").token
  end

  def administrator_token
    keys.issue(scope: "administrator", label: "test admin key").token
  end

  def bearer(token)
    { "HTTP_AUTHORIZATION" => "Bearer #{token}" }
  end

  describe "POST /communities/:slug/rooms/:room_key/messages" do
    it "queues the post and answers 201, saying queued rather than sent" do
      post "/communities/sample/rooms/general/messages", { body: "hello from a client" }, bearer(developer_token)

      expect(last_response.status).to eq(201)
      expect(last_response.content_type).to start_with("application/yaml")
      answer = YAMLCamel.load(last_response.body)
      expect(answer["status"]).to eq("queued")
      expect(answer["room_key"]).to eq("general")
      expect(answer["id"]).to be_a(Integer)
    end

    it "writes a row the bot's relay will find, tagged api and never guest" do
      post "/communities/sample/rooms/general/messages", { body: "hello" }, bearer(developer_token)

      row = models.api_pending_message.order(:id).last
      expect(row.community_id).to eq(community.id)
      expect(row.room_id).to eq(room.id)
      expect(row.body).to eq("hello")
      expect(row.author_kind).to eq("api")
      # The key's own name under the fixed @api-client domain, so it cannot read as
      # a member of a real platform or as a guest.
      expect(row.author_label).to eq("test developer key@api-client")
      expect(row.api_key_id).not_to be_nil
    end

    it "lets an administrator key post into any community's room" do
      other = other_community
      post "/communities/#{other.slug}/rooms/general/messages", { body: "hi" }, bearer(administrator_token)

      expect(last_response.status).to eq(201)
      expect(models.api_pending_message.order(:id).last.community_id).to eq(other.id)
    end

    it "404s, not 403, when a developer key posts into another community's room" do
      other_community
      post "/communities/other-co/rooms/general/messages", { body: "hi" }, bearer(developer_token)

      expect(last_response.status).to eq(404)
      expect(models.api_pending_message.count).to eq(0)
    end

    it "404s identically for a room that does not exist at all, so the two are indistinguishable" do
      other_community
      real = begin
        post "/communities/other-co/rooms/general/messages", { body: "hi" }, bearer(developer_token)
        [last_response.status, last_response.body]
      end
      imaginary = begin
        post "/communities/sample/rooms/no-such-room/messages", { body: "hi" }, bearer(developer_token)
        [last_response.status, last_response.body]
      end

      expect(real).to eq(imaginary)
    end

    it "rejects an empty body" do
      post "/communities/sample/rooms/general/messages", { body: "   " }, bearer(developer_token)

      expect(last_response.status).to eq(422)
      expect(models.api_pending_message.count).to eq(0)
    end

    it "rejects a body past the length cap" do
      oversize = "x" * (Rubotty::ControlPlane::ApiMessages::MAX_BODY + 1)
      post "/communities/sample/rooms/general/messages", { body: oversize }, bearer(developer_token)

      expect(last_response.status).to eq(422)
      expect(models.api_pending_message.count).to eq(0)
    end

    it "accepts a YAML body as well as a form one, like every other write route" do
      post "/communities/sample/rooms/general/messages", YAMLCamel.dump({ "body" => "from yaml" }),
           bearer(developer_token).merge("CONTENT_TYPE" => "application/yaml")

      expect(last_response.status).to eq(201)
      expect(models.api_pending_message.order(:id).last.body).to eq("from yaml")
    end

    # A YAML 1.2 client (yamlcamel, the Swift client library) writes a plain
    # scalar like "No" unquoted, which is spec-correct for it. Written as a
    # raw string rather than through the dumper, which quotes an ambiguous
    # word defensively and would hide what this spec is about.
    it "keeps a body given as an unquoted No, which YAML 1.2 reads as the word" do
      post "/communities/sample/rooms/general/messages", "body: No\n",
           bearer(developer_token).merge("CONTENT_TYPE" => "application/yaml")

      expect(last_response.status).to eq(201)
      expect(models.api_pending_message.order(:id).last.body).to eq("No")
    end

    it "400s a body given as a real YAML boolean rather than stringifying it" do
      post "/communities/sample/rooms/general/messages", "body: true\n",
           bearer(developer_token).merge("CONTENT_TYPE" => "application/yaml")

      expect(last_response.status).to eq(400)
      expect(YAMLCamel.load(last_response.body)["error"]).to include("YAML boolean")
      expect(models.api_pending_message.count).to eq(0)
    end
  end

  describe "GET /communities/:slug/rooms/:room_key/stream" do
    # One buffer pass, then close, so rack-test does not block on an open connection.
    # Production leaves this unset and streams indefinitely.
    let(:app) { Rubotty::Api::App.assemble(deps: deps, env: { "API_SSE_MAX_PASSES" => "1" }) }

    def buffer!(text, community_id: community.id, room_key: "general", author: "ada@telegram")
      buffer.record(community_id: community_id, room_key: room_key, body: text,
                    origin_key: "tg-general", author_label: author)
    end

    it "streams buffered messages as text/event-stream, with id-tagged YAML frames" do
      buffer!("a live line")

      get "/communities/sample/rooms/general/stream", { since: 0 }, bearer(developer_token)

      expect(last_response.status).to eq(200)
      expect(last_response.headers["Content-Type"]).to include("text/event-stream")
      expect(last_response.headers["X-Accel-Buffering"]).to eq("no")
      expect(last_response.body).to include("id:")
      expect(last_response.body).to include("data:")
      expect(last_response.body).to include("a live line")
    end

    # YAML on the wire even here, where every published SSE example is JSON. The data
    # lines rejoin into one YAML document.
    it "carries YAML in the data frames, never JSON" do
      buffer!("readable as yaml")

      get "/communities/sample/rooms/general/stream", { since: 0 }, bearer(developer_token)

      frame = last_response.body.split("\n\n").find { |chunk| chunk.include?("readable as yaml") }
      document = frame.lines.grep(/\Adata: /).map { |line| line.sub(/\Adata: /, "") }.join("\n")
      parsed = YAMLCamel.load(document)
      expect(parsed["room_key"]).to eq("general")
      expect(parsed["messages"].first["body"]).to eq("readable as yaml")
      expect(parsed["messages"].first["origin"]).to eq("tg-general")
      expect(parsed["messages"].first["author"]).to eq("ada@telegram")
      expect(last_response.body).not_to include("{\"")
    end

    it "resumes after the client's Last-Event-ID" do
      first = buffer!("first")
      buffer!("second")

      header "Last-Event-ID", first.id.to_s
      get "/communities/sample/rooms/general/stream", {}, bearer(developer_token)

      expect(last_response.body).not_to include("first")
      expect(last_response.body).to include("second")
    end

    # No backlog on a fresh connect; the buffer holds seconds of history and this
    # feature never serves it as an archive.
    it "starts at the current head when no cursor is given, so nothing already buffered is replayed" do
      buffer!("said before anyone was watching")

      get "/communities/sample/rooms/general/stream", {}, bearer(developer_token)

      expect(last_response.body).not_to include("said before anyone was watching")
    end

    it "refuses a row already past the buffer's TTL, even when the sweep has not run" do
      row = buffer!("too old to serve")
      row.update(created_at: Time.now - (Rubotty::ControlPlane::LiveRoomFeed::TTL_SECONDS + 60))

      get "/communities/sample/rooms/general/stream", { since: 0 }, bearer(developer_token)

      expect(last_response.body).not_to include("too old to serve")
    end

    # authenticate! runs once, in the before filter, and the stream loop then
    # runs until the client hangs up. Revoking a leaked key stops new requests
    # at once but does nothing to a stream already open, defeating revocation
    # for exactly the live private-room traffic that matters most.
    describe "when the key is revoked mid stream" do
      # Enough passes that the loop would keep going on its own; the revocation
      # is what has to end it.
      let(:app) { Rubotty::Api::App.assemble(deps: deps, env: { "API_SSE_MAX_PASSES" => "20" }) }

      # Revoke during the first buffer read, which is the review's own timing:
      # the key dies while the stream is mid flight rather than between requests.
      def revoke_on_first_read!(public_id)
        reads = 0
        feed = deps.live_room_feed
        allow(feed).to receive(:since).and_wrap_original do |original, **kwargs|
          reads += 1
          keys.revoke_by_public_id(public_id: public_id) if reads == 1
          original.call(**kwargs)
        end
        -> { reads }
      end

      it "ends the stream instead of serving the holder of a dead token" do
        issued = keys.issue(scope: "developer", community: community, label: "leaked")
        reads = revoke_on_first_read!(issued.key_row.public_id)

        get "/communities/sample/rooms/general/stream", { since: 0 }, bearer(issued.token)

        expect(reads.call).to eq(1)
      end

      # The review's own sequence: revoke during the first pass, write during
      # the second. The line has to be written after the read that revoked, or
      # it would be picked up by that same read and prove nothing.
      it "does not deliver a message written after the revocation" do
        issued = keys.issue(scope: "developer", community: community, label: "leaked")
        reads = 0
        feed = deps.live_room_feed
        allow(feed).to receive(:since).and_wrap_original do |original, **kwargs|
          reads += 1
          entries = original.call(**kwargs)
          if reads == 1
            keys.revoke_by_public_id(public_id: issued.key_row.public_id)
            buffer!("written after the key died")
          end
          entries
        end

        get "/communities/sample/rooms/general/stream", { since: 0 }, bearer(issued.token)

        expect(last_response.body).not_to include("written after the key died")
      end

      it "still runs to its own limit while the key is good" do
        reads = 0
        feed = deps.live_room_feed
        allow(feed).to receive(:since).and_wrap_original do |original, **kwargs|
          reads += 1
          original.call(**kwargs)
        end

        get "/communities/sample/rooms/general/stream", { since: 0 }, bearer(developer_token)

        expect(reads).to eq(20)
      end
    end

    it "lets an administrator key watch any community's room" do
      other = other_community
      buffer!("other tenant's line", community_id: other.id)

      get "/communities/other-co/rooms/general/stream", { since: 0 }, bearer(administrator_token)

      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("other tenant's line")
    end

    it "404s, not 403, when a developer key watches another community's room" do
      other_community

      get "/communities/other-co/rooms/general/stream", { since: 0 }, bearer(developer_token)

      expect(last_response.status).to eq(404)
      expect(last_response.content_type).to start_with("application/yaml")
    end

    it "404s identically for a room that does not exist at all" do
      other_community
      real = begin
        get "/communities/other-co/rooms/general/stream", { since: 0 }, bearer(developer_token)
        [last_response.status, last_response.body]
      end
      imaginary = begin
        get "/communities/sample/rooms/nope/stream", { since: 0 }, bearer(developer_token)
        [last_response.status, last_response.body]
      end

      expect(real).to eq(imaginary)
    end

    # Authorization alone cannot catch this one: the key may watch a room called
    # "general", and two of them exist, so only a scoped query keeps them apart.
    it "never serves another community's rows for a room_key both communities have" do
      other = other_community
      buffer!("ours", community_id: community.id)
      buffer!("theirs", community_id: other.id)

      get "/communities/sample/rooms/general/stream", { since: 0 }, bearer(developer_token)

      expect(last_response.body).to include("ours")
      expect(last_response.body).not_to include("theirs")
    end

    it "rejects an unauthenticated watcher before it opens a stream at all" do
      get "/communities/sample/rooms/general/stream"

      expect(last_response.status).to eq(401)
      expect(last_response.content_type).to start_with("application/yaml")
    end
  end
end
