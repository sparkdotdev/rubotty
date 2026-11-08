# frozen_string_literal: true

require "spec_helper"
require "rubotty/guest_portal"
require "rack/test"
require "tempfile"

# The guest portal web surface, room-scoped, driven in-process with rack-test
# over the seeded SAMPLE control plane; no socket, rack-test calls the Sinatra
# app directly. Asserts the security-sensitive gates: token and expiry
# checks, merged room scoping, no backlog before join, and rate limiting.
RSpec.describe Rubotty::GuestPortal::App, :control_plane do
  include Rack::Test::Methods

  # An upload's bytes go to the object store (migration 045), so the portal
  # needs a real one, and these look at what lands on it. Its own root per
  # example, so one example cannot see another's blobs.
  around do |example|
    with_object_store_root do |root|
      @root = root
      example.run
    end
  end

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }
  let(:room) { models.room.where(community_id: community.id, room_key: "general").first }
  let(:channel) { models.channel.where(community_id: community.id, endpoint_key: "dc-general").first }
  let(:other_channel) { models.channel.where(community_id: community.id, endpoint_key: "dc-gaming").first }
  let(:other_room) { models.room.where(community_id: community.id, room_key: "gaming").first }

  let(:rate_max) { 100 }
  let(:deps) do
    Rubotty::GuestPortal::Deps.new(db: db, logger: Rubotty::Log.null, rate_max: rate_max,
                                   file_store_path: @root)
  end
  # The public base every capability URL is built on. A deployment always sets
  # this; the portal refuses to mint a link without it rather than reading the
  # request's own Host, which a guest chooses.
  let(:portal_url) { "https://guest.example/guest-chat" }
  let(:app) { Rubotty::GuestPortal::App.assemble(deps: deps, env: { "GUEST_PORTAL_URL" => portal_url }) }

  let(:invites) { deps.invites }
  let(:feed) { deps.feed }

  # Guest access is off by default; turn it on for the rooms these tests issue
  # invites for (general and, for scoping, gaming).
  before do
    controls = Rubotty::ControlPlane::FeatureControls.new(models: models)
    controls.enable(community: community, selector: "general", feature: "guest_portal")
    controls.enable(community: community, selector: "gaming", feature: "guest_portal")
  end

  def issue!(nickname: "Sam", ttl: 3600, on: room)
    invites.issue(community: community, room: on, nickname: nickname, ttl_seconds: ttl)
  end

  def json = JSON.parse(last_response.body)

  # ------------------------------------------------------------------
  # token gating
  # ------------------------------------------------------------------
  describe "token gating" do
    it "shows the ended page for an unknown token, revealing nothing" do
      get "/g/not-a-real-token"
      expect(last_response.status).to eq(410)
      expect(last_response.body).to include("ended")
    end

    it "answers the poll for an unknown token as ended, so the client stops" do
      get "/g/not-a-real-token/messages.json"
      expect(last_response.status).to eq(200)
      expect(json["ended"]).to be(true)
    end

    it "refuses a send on an unknown token and records nothing" do
      expect { post "/g/not-a-real-token/messages", body: "hi" }
        .not_to change { models.guest_message.count }
      expect(last_response.status).to eq(410)
    end

    it "answers the liveness probe without a token" do
      get "/healthz"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("ok")
    end
  end

  # ------------------------------------------------------------------
  # a live invite
  # ------------------------------------------------------------------
  describe "opening a live invite" do
    it "serves the chat window and marks the guest as a temporary guest" do
      token = issue!.token
      get "/g/#{token}"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("Sam")
      expect(last_response.body).to include("guest")
    end

    it "pins the join cursor to the head of the feed on first open" do
      issued = issue!
      feed.record_in(community_id: community.id, room_id: room.id, author_label: "a", body: "before")
      before_head = feed.latest_id(room_id: room.id)

      get "/g/#{issued.token}"
      expect(issued.invite.refresh.joined_at).not_to be_nil
      expect(issued.invite.refresh.join_cursor).to eq(before_head)
    end
  end

  # ------------------------------------------------------------------
  # expiry and revocation
  # ------------------------------------------------------------------
  describe "expiry rejection" do
    it "shows the ended page once the invite has expired" do
      issued = issue!
      issued.invite.update(expires_at: Time.now - 60)
      get "/g/#{issued.token}"
      expect(last_response.status).to eq(410)
    end

    it "refuses a send on an expired invite and records nothing" do
      issued = issue!
      issued.invite.update(expires_at: Time.now - 60)
      expect { post "/g/#{issued.token}/messages", body: "too late" }
        .not_to change { models.guest_message.count }
      expect(last_response.status).to eq(410)
      expect(json["ended"]).to be(true)
    end

    it "refuses a send once the operator revokes the invite" do
      issued = issue!
      invites.revoke(invite: issued.invite)
      post "/g/#{issued.token}/messages", body: "nope"
      expect(last_response.status).to eq(410)
    end
  end

  # ------------------------------------------------------------------
  # room scoping and no backlog
  # ------------------------------------------------------------------
  describe "room scoping" do
    it "never serves a message from another room" do
      issued = issue!
      get "/g/#{issued.token}" # pins the cursor
      feed.record_in(community_id: community.id, room_id: other_room.id, author_label: "e", body: "elsewhere")
      feed.record_in(community_id: community.id, room_id: room.id, author_label: "a", body: "here")

      get "/g/#{issued.token}/messages.json", since: 0
      bodies = json["messages"].map { |m| m["body"] }
      expect(bodies).to eq(["here"])
    end

    it "merges messages from every channel bridged into the room (issue #156)" do
      issued = issue!
      get "/g/#{issued.token}" # pins the cursor
      feed.record_in(community_id: community.id, room_id: room.id, channel_id: channel.id,
                     author_label: "a", body: "from discord")
      feed.record_in(community_id: community.id, room_id: room.id,
                     channel_id: models.channel.where(community_id: community.id, endpoint_key: "tg-general").first.id,
                     author_label: "b", body: "from telegram")

      get "/g/#{issued.token}/messages.json", since: 0
      bodies = json["messages"].map { |m| m["body"] }
      expect(bodies).to eq(["from discord", "from telegram"])
    end
  end

  describe "no history before join" do
    # A prefetcher, a link-preview bot, or just someone hitting the JSON url
    # directly, before /g/:token was ever loaded once, must not get the
    # backlog just because join_cursor is still unset.
    it "serves no backlog to messages.json hit cold, before the chat page ever loaded" do
      issued = issue!
      feed.record_in(community_id: community.id, room_id: room.id, author_label: "a", body: "backlog")

      get "/g/#{issued.token}/messages.json", since: 0
      expect(json["messages"]).to eq([])
    end

    it "serves only messages from join-time forward" do
      issued = issue!
      feed.record_in(community_id: community.id, room_id: room.id, author_label: "a", body: "backlog")
      get "/g/#{issued.token}" # join pins the cursor above the backlog

      feed.record_in(community_id: community.id, room_id: room.id, author_label: "a", body: "fresh")
      get "/g/#{issued.token}/messages.json", since: 0
      bodies = json["messages"].map { |m| m["body"] }
      expect(bodies).to eq(["fresh"])
    end
  end

  # ------------------------------------------------------------------
  # sending
  # ------------------------------------------------------------------
  describe "sending" do
    it "records a guest send as a pending relay row the bot will fan out" do
      issued = issue!
      post "/g/#{issued.token}/messages", body: "hello from the web"
      expect(last_response.status).to eq(201)

      row = models.guest_message.where(direction: "out", invite_id: issued.invite.id).first
      expect(row).not_to be_nil
      expect(row.body).to eq("hello from the web")
      expect(row.relayed_at).to be_nil
      expect(row.author_label).to eq("Sam@guest-user")
    end

    it "shows the guest their own send back through the feed" do
      issued = issue!
      get "/g/#{issued.token}"
      post "/g/#{issued.token}/messages", body: "mine"

      get "/g/#{issued.token}/messages.json", since: 0
      mine = json["messages"].find { |m| m["body"] == "mine" }
      expect(mine["mine"]).to be(true)
    end

    it "rejects an empty message" do
      issued = issue!
      expect { post "/g/#{issued.token}/messages", body: "   " }
        .not_to change { models.guest_message.count }
      expect(last_response.status).to eq(422)
    end
  end

  # ------------------------------------------------------------------
  # rate limiting
  # ------------------------------------------------------------------
  describe "rate limiting" do
    let(:rate_max) { 2 }

    it "refuses a send once the per-session limit is reached, recording nothing more" do
      issued = issue!
      2.times { post "/g/#{issued.token}/messages", body: "m" }
      expect(last_response.status).to eq(201)

      expect { post "/g/#{issued.token}/messages", body: "one too many" }
        .not_to change { models.guest_message.where(direction: "out").count }
      expect(last_response.status).to eq(429)
      expect(last_response.headers["Retry-After"]).not_to be_nil
    end
  end

  # server-sent events
  describe "the SSE stream" do
    # One feed pass, then close, so rack-test does not block on an open
    # connection. Unset, the pass budget is DEFAULT_SSE_MAX_PASSES rather than
    # unbounded.
    let(:app) { Rubotty::GuestPortal::App.assemble(deps: deps, env: { "GUEST_SSE_MAX_PASSES" => "1" }) }

    it "streams new feed entries as text/event-stream events" do
      issued = issue!
      get "/g/#{issued.token}" # pins the join cursor at the head
      feed.record_in(community_id: community.id, room_id: room.id, author_label: "Ada", body: "live line")

      get "/g/#{issued.token}/stream", since: 0
      expect(last_response.status).to eq(200)
      expect(last_response.headers["Content-Type"]).to include("text/event-stream")
      expect(last_response.body).to include("id:")
      expect(last_response.body).to include("data:")
      expect(last_response.body).to include("live line")
    end

    it "resumes after the browser's Last-Event-ID" do
      issued = issue!
      get "/g/#{issued.token}"
      first = feed.record_in(community_id: community.id, room_id: room.id, author_label: "Ada", body: "first")
      feed.record_in(community_id: community.id, room_id: room.id, author_label: "Ada", body: "second")

      header "Last-Event-ID", first.id.to_s
      get "/g/#{issued.token}/stream"

      expect(last_response.body).not_to include("first")
      expect(last_response.body).to include("second")
    end

    it "answers an unknown token as ended, so the client stops and falls back" do
      get "/g/not-a-real-token/stream"
      expect(last_response.headers["Content-Type"]).to include("text/event-stream")
      expect(last_response.body).to include("\"ended\":true")
    end

    # A stream holds a thread and two queries a second, against a pool of four
    # shared with the dashboard and the API.
    describe "what bounds a stream" do
      let(:app) { Rubotty::GuestPortal::App.assemble(deps: deps, env: {}) }

      it "bounds the pass budget with GUEST_SSE_MAX_PASSES unset" do
        expect(app.new!.send(:sse_max_passes))
          .to eq(Rubotty::GuestPortal::App::DEFAULT_SSE_MAX_PASSES)
      end

      it "bounds it for a value that is not a positive number" do
        ["0", "-3", "not a number"].each do |raw|
          portal = Rubotty::GuestPortal::App.assemble(deps: deps, env: { "GUEST_SSE_MAX_PASSES" => raw })
          expect(portal.new!.send(:sse_max_passes))
            .to eq(Rubotty::GuestPortal::App::DEFAULT_SSE_MAX_PASSES), raw
        end
      end

      it "tells a guest already holding its share of streams to poll instead" do
        issued = issue!
        limiter = app.stream_limiter
        allow(limiter).to receive(:hold).and_return(nil)

        get "/g/#{issued.token}/stream"

        expect(last_response.status).to eq(200)
        expect(last_response.body).to include("\"poll\":true")
        expect(last_response.body).not_to include("\"ended\":true")
      end

      it "releases the slot once the stream closes" do
        issued = issue!
        limited = Rubotty::GuestPortal::App.assemble(deps: deps, env: { "GUEST_SSE_MAX_PASSES" => "1" })

        Rack::Test::Session.new(limited).get("/g/#{issued.token}/stream")

        expect(limited.stream_limiter.open_for(issued.invite.id)).to eq(0)
      end
    end
  end

  # file uploads
  describe "uploading a file" do
    def upload_file(bytes, filename: "shot.png", type: "image/png")
      file = Tempfile.new(["guest-upload", File.extname(filename)])
      file.binmode
      file.write(bytes)
      file.rewind
      Rack::Test::UploadedFile.new(file.path, type, original_filename: filename)
    end

    it "records the upload as a pending out row carrying an attachment descriptor" do
      issued = issue!
      post "/g/#{issued.token}/upload", file: upload_file("PNGDATA"), body: "have a look"
      expect(last_response.status).to eq(201)

      row = models.guest_message.where(direction: "out", invite_id: issued.invite.id).first
      expect(row.body).to eq("have a look")
      descriptor = JSON.parse(row.attachments).first
      expect(descriptor["kind"]).to eq("photo")
      expect(descriptor["filename"]).to eq("shot.png")
      expect(descriptor["url"]).to include("/uploads/")
      expect(row.relayed_at).to be_nil
    end

    it "serves the uploaded bytes back at its secret URL, with no invite token needed" do
      issued = issue!
      post "/g/#{issued.token}/upload", file: upload_file("PNGDATA")
      secret = JSON.parse(
        models.guest_message.where(direction: "out").first.attachments
      ).first["url"].split("/").last

      get "/uploads/#{secret}"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq("PNGDATA")
      expect(last_response.headers["Content-Type"]).to include("image/png")
      expect(last_response.headers["Content-Disposition"]).to start_with("inline")
    end

    # ObjectStore's cap is mid-stream and correct, but Rack has already written
    # the whole multipart body to a tempfile by the time any route runs.
    describe "the size cap before the bytes reach disk" do
      it "refuses an over-cap body without parsing it, so nothing is written" do
        issued = issue!
        oversize = "x" * (Rubotty::GuestPortal::App::MAX_UPLOAD_BYTES + 1)

        post "/g/#{issued.token}/upload",
             file: upload_file(oversize, filename: "big.bin", type: "application/octet-stream")

        expect(last_response.status).to eq(413)
        expect(models.guest_upload.count).to eq(0)
        expect(stored_objects(@root, "guest-upload")).to be_empty
      end

      it "does not read the body at all once the declared length is over the cap" do
        issued = issue!
        body = "x" * 64

        post "/g/#{issued.token}/upload", body,
             "CONTENT_TYPE" => "multipart/form-data; boundary=zzz",
             "CONTENT_LENGTH" => (Rubotty::GuestPortal::App::MAX_UPLOAD_BYTES * 4).to_s

        expect(last_response.status).to eq(413)
      end

      it "still accepts a file at the cap" do
        issued = issue!
        at_cap = "x" * (Rubotty::GuestPortal::App::MAX_UPLOAD_BYTES - 1024)

        post "/g/#{issued.token}/upload",
             file: upload_file(at_cap, filename: "big.bin", type: "application/octet-stream")

        expect(last_response.status).to eq(201)
      end
    end

    # The GCM tag is only checked once the last ciphertext byte is read, so a
    # streaming serve has already sent 200 by the time it finds out.
    describe "an object whose bytes no longer authenticate" do
      it "refuses rather than answering 200 and stopping short" do
        issued = issue!
        post "/g/#{issued.token}/upload", file: upload_file("PNGDATA" * 100)
        secret = JSON.parse(
          models.guest_message.where(direction: "out").first.attachments
        ).first["url"].split("/").last
        corrupt_last_byte(models.guest_upload.first.object_key)

        get "/uploads/#{secret}"

        expect(last_response.status).to eq(500)
        expect(last_response.body).not_to include("PNGDATA")
      end
    end

    # The path segment of the relayed URL is the object's one-time secret, which
    # is the HKDF input for its AES key, so whoever the URL names gets the key
    # from anything that fetches it.
    describe "the host the relayed URL names" do
      it "builds it from GUEST_PORTAL_URL, not from the request" do
        issued = issue!

        post "/g/#{issued.token}/upload", { file: upload_file("PNGDATA") }, "HTTP_HOST" => "attacker.example"

        expect(last_response.status).to eq(201)
        url = JSON.parse(models.guest_message.where(direction: "out").first.attachments).first["url"]
        expect(url).to start_with("#{portal_url}/uploads/")
        expect(url).not_to include("attacker.example")
      end

      context "with GUEST_PORTAL_URL unset" do
        let(:portal_url) { "" }

        it "refuses the upload rather than trusting the Host header" do
          issued = issue!

          post "/g/#{issued.token}/upload", { file: upload_file("PNGDATA") }, "HTTP_HOST" => "attacker.example"

          expect(last_response.status).to eq(503)
          expect(models.guest_upload.count).to eq(0)
          expect(models.guest_message.where(direction: "out").count).to eq(0)
        end
      end

      context "with GUEST_PORTAL_URL set to something that is not an http base" do
        let(:portal_url) { "attacker.example" }

        it "refuses the upload, since a relative base is no base at all" do
          issued = issue!

          post "/g/#{issued.token}/upload", file: upload_file("PNGDATA")

          expect(last_response.status).to eq(503)
          expect(models.guest_upload.count).to eq(0)
        end
      end
    end

    # The portal and the dashboard share a hostname and the dashboard's cookie is
    # issued path=/, so a guest's HTML rendered here would run against that origin.
    describe "a type the browser must not render" do
      def upload_secret
        JSON.parse(models.guest_message.where(direction: "out").first.attachments).first["url"].split("/").last
      end

      it "stores an HTML upload as bytes rather than as the type the guest named" do
        issued = issue!
        post "/g/#{issued.token}/upload",
             file: upload_file("<script>alert(1)</script>", filename: "note.html", type: "text/html")
        expect(last_response.status).to eq(201)

        expect(models.guest_upload.first.content_type).to eq("application/octet-stream")
      end

      it "serves it as a download, not inline, and never as HTML" do
        issued = issue!
        post "/g/#{issued.token}/upload",
             file: upload_file("<script>alert(1)</script>", filename: "note.html", type: "text/html")

        get "/uploads/#{upload_secret}"

        expect(last_response.status).to eq(200)
        expect(last_response.headers["Content-Type"]).not_to include("text/html")
        expect(last_response.headers["Content-Disposition"]).to start_with("attachment")
        expect(last_response.headers["Content-Security-Policy"]).to include("sandbox")
        expect(last_response.headers["X-Content-Type-Options"]).to eq("nosniff")
      end

      it "does the same for an SVG, which scripts just as happily" do
        issued = issue!
        post "/g/#{issued.token}/upload",
             file: upload_file("<svg xmlns='http://www.w3.org/2000/svg'/>", filename: "x.svg",
                               type: "image/svg+xml")

        get "/uploads/#{upload_secret}"

        expect(last_response.headers["Content-Type"]).not_to include("svg")
        expect(last_response.headers["Content-Disposition"]).to start_with("attachment")
      end

      # A row written before the allow list existed still carries the old type.
      it "refuses to render a text/html row already in the table" do
        issued = issue!
        post "/g/#{issued.token}/upload", file: upload_file("<script>alert(1)</script>")
        models.guest_upload.first.update(content_type: "text/html")

        get "/uploads/#{upload_secret}"

        expect(last_response.headers["Content-Type"]).not_to include("text/html")
        expect(last_response.headers["Content-Disposition"]).to start_with("attachment")
      end
    end

    # The bytes are sealed with a key derived from the URL secret, so a
    # payload far bigger than one buffer proves the streaming path both ways.
    it "round-trips a file large enough to cross the store's chunk boundary" do
      issued = issue!
      payload = "guest bytes. " * 30_000
      post "/g/#{issued.token}/upload", file: upload_file(payload, filename: "big.bin",
                                                          type: "application/octet-stream")

      get JSON.parse(
        models.guest_message.where(direction: "out").first.attachments
      ).first["url"].sub(portal_url, "")

      expect(last_response.body).to eq(payload)
    end

    # The row holds only the digest of the serve secret, so a copy of the
    # database cannot open the file even with the disk beside it.
    it "keeps the serve secret out of the row" do
      issued = issue!
      post "/g/#{issued.token}/upload", file: upload_file("PNGDATA")
      secret = JSON.parse(
        models.guest_message.where(direction: "out").first.attachments
      ).first["url"].split("/").last

      row = models.guest_upload.first
      expect(row.token_hash).to eq(Rubotty::Storage::ObjectStore.digest(secret))
      expect(row.values.values.map(&:to_s)).not_to include(secret)
      # And the file really is on this example's own store, which is what makes
      # the "left nothing behind" assertions below mean something.
      expect(stored_objects(@root, "guest-upload").size).to eq(1)
    end

    it "404s an unknown upload secret, revealing nothing" do
      get "/uploads/#{SecureRandom.uuid}"
      expect(last_response.status).to eq(404)
    end

    it "refuses an empty file, storing nothing" do
      issued = issue!
      post "/g/#{issued.token}/upload", file: upload_file("")
      expect(last_response.status).to eq(422)
      expect(models.guest_upload.count).to eq(0)
    end

    it "refuses a file over the size cap, recording nothing and keeping nothing" do
      issued = issue!
      oversize = "x" * (Rubotty::GuestPortal::App::MAX_UPLOAD_BYTES + 1)
      expect { post "/g/#{issued.token}/upload", file: upload_file(oversize, filename: "big.bin", type: "application/octet-stream") }
        .not_to change { models.guest_message.where(direction: "out").count }
      expect(last_response.status).to eq(413)
      expect(models.guest_upload.count).to eq(0)
      expect(stored_objects(@root, "guest-upload")).to be_empty
    end

    it "refuses an upload on an ended session" do
      issued = issue!
      issued.invite.update(expires_at: Time.now - 60)
      post "/g/#{issued.token}/upload", file: upload_file("PNGDATA")
      expect(last_response.status).to eq(410)
    end

    describe "rate limiting an upload" do
      let(:rate_max) { 1 }

      it "counts an upload against the per-session send limit" do
        issued = issue!
        post "/g/#{issued.token}/upload", file: upload_file("one")
        expect(last_response.status).to eq(201)

        expect { post "/g/#{issued.token}/upload", file: upload_file("two") }
          .not_to change { models.guest_message.where(direction: "out").count }
        expect(last_response.status).to eq(429)
      end
    end
  end
end
