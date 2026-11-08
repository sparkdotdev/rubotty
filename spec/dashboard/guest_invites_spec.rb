# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"
require "rack/test"
require "stringio"

# The operator issuance surface for guest invites, driven with rack-test over the
# seeded SAMPLE control plane. It issues, lists and revokes room-scoped guest links
# through the same GuestInvites service the guest surface and the bot's relay read.
RSpec.describe "Rubotty::Dashboard::App guest invites", :control_plane do
  include Rack::Test::Methods

  # Revoking unlinks objects from the store as well as deleting rows, so the
  # dashboard is given a real store under a tmpdir.
  around do |example|
    with_object_store_root do |root|
      @root = root
      example.run
    end
  end

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:secret) { "open-sesame" }
  let(:env) { { "DASHBOARD_SECRET" => secret, "GUEST_PORTAL_URL" => "https://guest.example" } }
  let(:deps) do
    Rubotty::Dashboard::Deps.new(db: db, logger: Rubotty::Log.null, file_store_path: @root)
  end
  let(:app) { Rubotty::Dashboard::App.assemble(deps: deps, env: env) }
  let(:community) { models.community.where(slug: "sample").first }

  def login! = post("/login", secret: secret)

  it "gates the guests page behind the operator session" do
    get "/communities/sample/guests"
    expect(last_response.status).to eq(302)
    expect(last_response.headers["location"]).to end_with("/login")
  end

  # Guest access starts off everywhere, so turn it on for the "general" room.
  def allow_general!
    Rubotty::ControlPlane::FeatureControls.new(models: models)
                                          .enable(community: community, selector: "general", feature: "guest_portal")
  end

  context "when signed in" do
    before { login! }

    it "renders the guests page with the community's rooms to scope access to" do
      get "/communities/sample/guests"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("general")
    end

    it "offers the general room to scope an invite to, once it allows guests" do
      allow_general!
      get "/communities/sample/guests"
      expect(last_response.body).to include("general")
      expect(last_response.body).to include('name="room"')
    end

    it "turns guest access on for a room and sets who can invite" do
      post "/communities/sample/guests/access", room: "general", allowed: "on", who_can_invite: "everyone"
      policy = deps.guest_invites.room_policy(
        community: community,
        room: models.room.where(community_id: community.id, room_key: "general").first
      )
      expect(policy[:allowed]).to be(true)
      expect(policy[:who_can_invite]).to eq("everyone")
    end

    it "refuses to issue for a room that does not allow guests" do
      expect do
        post "/communities/sample/guests", room: "general", nickname: "Reviewer", ttl_hours: "2"
      end.not_to change { models.guest_invite.count }
      follow_redirect!
      expect(last_response.body).to include("not allowed")
    end

    it "issues a room-scoped invite, storing only the token digest" do
      allow_general!
      expect do
        post "/communities/sample/guests", room: "general", nickname: "Reviewer", ttl_hours: "2"
      end.to change { models.guest_invite.where(community_id: community.id).count }.by(1)

      invite = models.guest_invite.where(community_id: community.id).order(:id).last
      room = models.room.where(community_id: community.id, room_key: "general").first
      expect(invite.room_id).to eq(room.id)
      expect(invite.nickname).to eq("Reviewer")
      expect(invite.token_hash.length).to eq(64)
      expect(invite.created_by).to eq("dashboard")
    end

    it "shows the full guest link once, built from GUEST_PORTAL_URL" do
      allow_general!
      post "/communities/sample/guests", room: "general", nickname: "Reviewer", ttl_hours: "2"
      follow_redirect!
      expect(last_response.body).to include("https://guest.example/g/")
    end

    it "turns a bad lifetime into a flash error and creates no invite" do
      allow_general!
      expect do
        post "/communities/sample/guests", room: "general", nickname: "Reviewer", ttl_hours: "0"
      end.not_to change { models.guest_invite.count }
      follow_redirect!
      expect(last_response.body).to include("positive lifetime")
    end

    it "revokes a live invite" do
      allow_general!
      issued = deps.guest_invites.issue(
        community: community,
        room: models.room.where(community_id: community.id, room_key: "general").first,
        nickname: "Reviewer", ttl_seconds: 3600
      )
      post "/communities/sample/guests/#{issued.invite.id}/revoke"
      expect(issued.invite.refresh.revoked_at).not_to be_nil
    end

    # Revoking ends the session now, so the messages the bot captured for that guest
    # go with it. The dashboard runs no scheduler worker, so this deletes in-process.
    it "reclaims the session's captured messages and uploads on revoke" do
      allow_general!
      room = models.room.where(community_id: community.id, room_key: "general").first
      issued = deps.guest_invites.issue(
        community: community, room: room, nickname: "Reviewer", ttl_seconds: 3600
      )
      Rubotty::ControlPlane::GuestFeed.new(models: models).record_in(
        community_id: community.id, room_id: room.id, author_label: "Ada@discord", body: "a member message"
      )
      store = Rubotty::Storage::ObjectStore.new(root: @root)
      Rubotty::ControlPlane::GuestUploads.new(models: models, store: store).store_file(
        invite: issued.invite, source: StringIO.new("a"), filename: "a.txt", content_type: "text/plain"
      )

      post "/communities/sample/guests/#{issued.invite.id}/revoke"

      expect(models.guest_message.where(room_id: room.id).count).to eq(0)
      expect(models.guest_upload.where(room_id: room.id).count).to eq(0)
      # The bytes go too, or a removed row leaves a file nothing points at.
      expect(stored_objects(@root, "guest-upload")).to be_empty
    end

    # Issuing writes a durable job the running bot process claims and runs, the
    # same cross-process split the dashboard's timed mutes already use.
    it "enqueues the expiry reclamation for whichever bot process is running" do
      allow_general!
      deps.guest_invites.issue(
        community: community,
        room: models.room.where(community_id: community.id, room_key: "general").first,
        nickname: "Reviewer", ttl_seconds: 3600
      )
      kind = Rubotty::ControlPlane::GuestRetention::KIND
      expect(db[:scheduled_jobs].where(kind: kind, status: "pending").count).to eq(1)
    end
  end
end
