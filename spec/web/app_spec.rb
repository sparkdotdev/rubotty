# frozen_string_literal: true

require "spec_helper"
require "rubotty/web"
require "rack/test"
require "tempfile"
require "stringio"

# The unified web surface, driven in-process with rack-test over the seeded SAMPLE
# control plane. The standalone dashboard and guest specs cover each surface on its
# own; this covers the mount, so the assertions are about prefixes and base URLs.
RSpec.describe Rubotty::Web, :control_plane do
  include Rack::Test::Methods

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }
  # A room guests are allowed in (enabled below), for the guest-portal tests.
  let(:room) { models.room.where(community_id: community.id, room_key: "general").first }

  let(:secret) { "open-sesame" }
  # The dashboard's issued invite links and the portal's upload URLs are both built
  # from GUEST_PORTAL_URL. A rehosted file's own download link has no relationship
  # to either and is built from RUBOTTY_FILE_STORAGE_URL instead.
  let(:guest_base) { "https://rubotty.example.org/guest-chat" }
  let(:files_base) { "https://rubotty.example.org" }
  let(:env) do
    { "DASHBOARD_SECRET" => secret, "GUEST_PORTAL_URL" => guest_base, "RUBOTTY_FILE_STORAGE_URL" => files_base }
  end

  let(:dashboard_deps) { Rubotty::Dashboard::Deps.new(db: db, logger: Rubotty::Log.null) }
  let(:guest_deps) { Rubotty::GuestPortal::Deps.new(db: db, logger: Rubotty::Log.null, rate_max: 100) }
  let(:api_deps) { Rubotty::Api::Deps.new(db: db, logger: Rubotty::Log.null, rate_max: 100) }
  let(:app) do
    Rubotty::Web.assemble(dashboard_deps: dashboard_deps, guest_deps: guest_deps, api_deps: api_deps, env: env)
  end

  # Guest access is off by default; turn it on for the room these tests use.
  before do
    controls = Rubotty::ControlPlane::FeatureControls.new(models: models)
    controls.enable(community: community, selector: "general", feature: "guest_portal")
  end

  def issue_invite(nickname: "Sam", ttl: 3600, on: room)
    guest_deps.invites.issue(community: community, room: on, nickname: nickname, ttl_seconds: ttl)
  end

  def login!
    post "/admin-panel/login", secret: secret
  end

  def shell_paths(body = last_response.body)
    source = body[%r{<script id="rb-shell-data" type="application/json">(.*?)</script>}m, 1]
    shell = JSON.parse(source)
    navigation = shell.fetch("scopes").flat_map do |scope|
      scope.fetch("groups").flat_map { |group| group.fetch("items") }.map { |item| item.fetch("path") }
    end
    navigation + shell.fetch("communities").map { |community| community.fetch("path") }
  end

  describe "the landing page at /" do
    it "renders and links to both surfaces" do
      get "/"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include('href="/guest-chat"')
      expect(last_response.body).to include('href="/admin-panel"')
      expect(last_response.body).to include("Guest Access")
      expect(last_response.body).to include("Admin Portal")
    end

    it "answers a liveness probe at the root" do
      get "/healthz"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("ok")
    end
  end

  describe "the dashboard under /admin-panel" do
    it "gates an unauthenticated request, redirecting to the prefixed login" do
      get "/admin-panel/"
      expect(last_response.status).to eq(302)
      expect(last_response.headers["location"]).to end_with("/admin-panel/login")
    end

    it "serves the login form with a prefixed action" do
      get "/admin-panel/login"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("Dashboard secret")
      expect(last_response.body).to include('action="/admin-panel/login"')
    end

    it "logs in and serves the index with prefix-carrying navigation" do
      login!
      expect(last_response.status).to eq(302)
      expect(last_response.headers["location"]).to end_with("/admin-panel/")

      get "/admin-panel/"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("sample")
      # Both carry the mount prefix, so they resolve to the dashboard and not the
      # landing page at the host root.
      expect(shell_paths).to include("/admin-panel/analytics", "/admin-panel/communities/sample")
    end

    it "resolves a community sub-nav link under the prefix" do
      login!
      get "/admin-panel/communities/sample"
      expect(last_response.status).to eq(200)
      expect(shell_paths).to include("/admin-panel/communities/sample/features")
    end

    it "performs a write through the mounted dashboard, landing a control-plane row" do
      login!
      post "/admin-panel/communities/sample/features", selector: "all", feature: "faq", op: "enable"
      expect(last_response.status).to eq(302)
      expect(last_response.headers["location"]).to end_with("/admin-panel/communities/sample/features")

      row = models.feature_setting.where(community_id: community.id, room_id: nil, feature: "faq").first
      expect(row).not_to be_nil
    end

    it "logs out through the prefixed action" do
      login!
      post "/admin-panel/logout"
      expect(last_response.status).to eq(302)
      expect(last_response.headers["location"]).to end_with("/admin-panel/login")

      get "/admin-panel/"
      expect(last_response.status).to eq(302)
    end
  end

  describe "the guest portal under /guest-chat" do
    it "serves the bare landing without a token" do
      get "/guest-chat/"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("guest portal")
    end

    it "serves the chat window at the prefixed invite path, handing its client the mount base" do
      token = issue_invite.token
      get "/guest-chat/g/#{token}"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("Sam")
      # The client builds every fetch and the SSE stream from this base.
      expect(last_response.body).to include('data-base="/guest-chat"')
    end

    it "polls messages under the prefix" do
      issued = issue_invite
      get "/guest-chat/g/#{issued.token}/messages.json", since: 0
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["ended"]).to be(false)
    end

    it "builds an upload's absolute serve URL on the /guest-chat base" do
      issued = issue_invite
      file = Tempfile.new(["guest-upload", ".png"])
      file.binmode
      file.write("PNGDATA")
      file.rewind
      upload = Rack::Test::UploadedFile.new(file.path, "image/png", original_filename: "shot.png")

      post "/guest-chat/g/#{issued.token}/upload", file: upload
      expect(last_response.status).to eq(201)

      row = models.guest_message.where(direction: "out", invite_id: issued.invite.id).first
      descriptor = JSON.parse(row.attachments).first
      expect(descriptor["url"]).to start_with("#{guest_base}/uploads/")
    end
  end

  describe "the REST admin API under /api" do
    it "answers a liveness probe under the prefix" do
      get "/api/healthz"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("ok")
    end

    it "serves an authenticated read under the mount prefix" do
      issued = Rubotty::ControlPlane::ApiKeys.new(models: models)
                                              .issue(scope: "developer", community: community, label: "mount test")
      get "/api/communities/sample", {}, { "HTTP_AUTHORIZATION" => "Bearer #{issued.token}" }
      expect(last_response.status).to eq(200)
      expect(last_response.content_type).to start_with("application/yaml")
    end
  end

  describe "a rehosted file's download route under /filestorage (and /f)" do
    it "serves a stored file at its own mount, unconnected to the guest portal's" do
      stored = guest_deps.rehosted_files.store_file(
        community_id: community.id, room_key: "general", source: StringIO.new("bytes"),
        filename: "note.txt", content_type: "text/plain"
      )

      get "/filestorage/#{stored.secret}.txt"

      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq("bytes")
    end

    it "still resolves the pre-extension shape at /f" do
      stored = guest_deps.rehosted_files.store_file(
        community_id: community.id, room_key: "general", source: StringIO.new("bytes"),
        filename: "note.txt", content_type: "text/plain"
      )

      get "/f/#{stored.secret}"

      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq("bytes")
    end
  end

  describe "a guest link issued from the mounted dashboard" do
    it "is built on the /guest-chat base from GUEST_PORTAL_URL" do
      login!
      post "/admin-panel/communities/sample/guests", room: "general", nickname: "Reviewer", ttl_hours: "24"
      expect(last_response.status).to eq(302)

      get "/admin-panel/communities/sample/guests"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("#{guest_base}/g/")
    end
  end

  # Behind Cloudflare Tunnel and Traefik the browser's https Origin disagreed
  # with the http URL the app reconstructs, and Sinatra's Rack::Protection::HttpOrigin
  # reacts with :drop_session, so every dashboard POST silently lost its
  # session and bounced to login; GET is safe since HttpOrigin never checks it.
  describe "a same-origin admin POST behind the TLS-terminating proxy" do
    # A multi-hop X-Forwarded-Proto carries the real client scheme first, then the
    # inner http hop Rack resolves the scheme from.
    let(:proxy) do
      { "HTTP_HOST" => "rubotty.example.org",
        "HTTP_X_FORWARDED_PROTO" => "https,http",
        "HTTP_ORIGIN" => "https://rubotty.example.org" }
    end

    def room_id
      models.room.where(community_id: community.id, room_key: "general").first.id
    end

    it "keeps the session on the guest-access POST rather than bouncing to /login" do
      post "/admin-panel/login", { secret: secret }, proxy
      expect(last_response.status).to eq(302)

      # Browsing (a GET) keeps working either way; asserted to mirror the report.
      get "/admin-panel/communities/sample/guests", {}, proxy.reject { |key, _| key == "HTTP_ORIGIN" }
      expect(last_response.status).to eq(200)

      post "/admin-panel/communities/sample/guests/access",
           { room: "general", allowed: "on", who_can_invite: "everyone" }, proxy

      # The bug redirected this POST to the login, its session dropped.
      expect(last_response.status).to eq(302)
      expect(last_response.headers["location"]).not_to end_with("/admin-panel/login")
      expect(last_response.headers["location"]).to end_with("/admin-panel/communities/sample/guests")

      # The before hook only enables the feature, so who_can_invite proves the write
      # ran under the surviving session.
      controls = Rubotty::ControlPlane::FeatureControls.new(models: models)
      entry = controls.list(community, selector: "general").find { |row| row[:feature] == "guest_portal" }
      expect(entry[:config]["who_can_invite"]).to eq("everyone")
    end

    it "keeps the session on a general dashboard POST too (not guest-specific)" do
      post "/admin-panel/login", { secret: secret }, proxy
      post "/admin-panel/communities/sample/features",
           { selector: "all", feature: "faq", op: "enable" }, proxy
      expect(last_response.headers["location"]).not_to end_with("/admin-panel/login")
      expect(last_response.headers["location"]).to end_with("/admin-panel/communities/sample/features")
    end

    it "still DROPS a genuinely cross-site POST (CSRF from a foreign Origin)" do
      post "/admin-panel/login", { secret: secret }, proxy
      cross = proxy.merge("HTTP_ORIGIN" => "https://evil.example.com")
      post "/admin-panel/communities/sample/guests/access",
           { room: "general", allowed: "on", who_can_invite: "everyone" }, cross
      # A foreign Origin host still drops the session, so CSRF protection is intact.
      expect(last_response.headers["location"]).to end_with("/admin-panel/login")
    end
  end
end
