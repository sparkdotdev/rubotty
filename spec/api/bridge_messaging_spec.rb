# frozen_string_literal: true

require "spec_helper"
require "rubotty/api"
require "rack/test"

# The api_wrapper platform adapter's own inbound surface, driven in-process
# with rack-test over the seeded SAMPLE control plane. Every route
# needs an API key scoped to one platform_account, never an ordinary
# developer or administrator key, which is what most of this holds to account.
RSpec.describe "the REST API's bridge messaging surface", :control_plane do
  include Rack::Test::Methods

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }
  let(:deps) { Rubotty::Api::Deps.new(db: db, logger: Rubotty::Log.null, rate_max: 200) }
  let(:app) { Rubotty::Api::App.assemble(deps: deps, env: {}) }
  let(:keys) { Rubotty::ControlPlane::ApiKeys.new(models: models) }
  let(:events) { Rubotty::ControlPlane::ApiWrapperEvents.new(models: models) }

  def bearer(token) = { "HTTP_AUTHORIZATION" => "Bearer #{token}" }

  def bridge_token(account: "acme-bridge", on: community)
    keys.issue(scope: "developer", community: on, platform_account: account, label: "acme bridge key").token
  end

  def plain_developer_token(on: community)
    keys.issue(scope: "developer", community: on, label: "plain developer key").token
  end

  def channel!(account: "acme-bridge", route_key: "support-42")
    now = Time.now
    models.channel.create(
      community_id: community.id, platform_connection_id: models.platform_connection.first.id,
      adapter: "api_wrapper", account: account, route_key: route_key,
      endpoint_key: "api_wrapper:#{account}:#{route_key}", label: "acme support",
      receives: true, sends: true, relay: "{}", display_name: "{}", settings: "{}",
      created_at: now, updated_at: now
    )
  end

  describe "POST /communities/:slug/bridge/channels/:channel_id/messages" do
    it "queues the message and answers 201 with a message_id" do
      channel!
      post "/communities/sample/bridge/channels/support-42/messages",
           { "body" => "hi from acme", "author" => { "id" => "u1", "name" => "Remote Ada" } },
           bearer(bridge_token)

      expect(last_response.status).to eq(201)
      answer = YAMLCamel.load(last_response.body)
      expect(answer["status"]).to eq("queued")
      expect(answer["message_id"]).to be_a(String)
    end

    it "writes a row carrying the real remote author, tagged to the right account and channel" do
      channel!
      post "/communities/sample/bridge/channels/support-42/messages",
           { "body" => "hi from acme", "author" => { "id" => "u1", "name" => "Remote Ada" } },
           bearer(bridge_token)

      row = models.api_wrapper_pending_event.order(:id).last
      expect(row.account).to eq("acme-bridge")
      expect(row.channel_id).to eq("support-42")
      expect(row.kind).to eq(Rubotty::ControlPlane::ApiWrapperEvents::KIND_MESSAGE)
      expect(row.body).to eq("hi from acme")
      expect(row.author_native_id).to eq("u1")
      expect(row.author_display_name).to eq("Remote Ada")
    end

    it "carries attachments and a reply_to through onto the row" do
      channel!
      post "/communities/sample/bridge/channels/support-42/messages",
           { "body" => "see attached", "reply_to" => "17",
             "author" => { "id" => "u1" },
             "attachments" => [{ "url" => "https://example.invalid/cat.png", "kind" => "photo" }] },
           bearer(bridge_token)

      row = models.api_wrapper_pending_event.order(:id).last
      expect(row.reply_to_native_id).to eq("17")
      expect(events.attachments_of(row)).to eq([{ "url" => "https://example.invalid/cat.png", "kind" => "photo" }])
    end

    it "accepts an attachment-only post with no text" do
      channel!
      post "/communities/sample/bridge/channels/support-42/messages",
           { "author" => { "id" => "u1" }, "attachments" => [{ "url" => "https://example.invalid/cat.png" }] },
           bearer(bridge_token)

      expect(last_response.status).to eq(201)
    end

    # A YAML 1.2 client (yamlcamel, the Swift client library) writes a plain
    # scalar like "On" unquoted, which is spec-correct for it. Written as a
    # raw string rather than through the dumper, which quotes an ambiguous
    # word defensively and would hide what this spec is about.
    it "keeps a body given as an unquoted On, which YAML 1.2 reads as the word" do
      channel!
      post "/communities/sample/bridge/channels/support-42/messages",
           "body: On\nauthor:\n  id: u1\n",
           bearer(bridge_token).merge("CONTENT_TYPE" => "application/yaml")

      expect(last_response.status).to eq(201)
    end

    it "400s a body given as a real YAML boolean rather than stringifying it" do
      channel!
      post "/communities/sample/bridge/channels/support-42/messages",
           "body: true\nauthor:\n  id: u1\n",
           bearer(bridge_token).merge("CONTENT_TYPE" => "application/yaml")

      expect(last_response.status).to eq(400)
      expect(YAMLCamel.load(last_response.body)["error"]).to include("YAML boolean")
      expect(models.api_wrapper_pending_event.count).to eq(0)
    end

    it "rejects a post with neither a body nor an attachment" do
      channel!
      post "/communities/sample/bridge/channels/support-42/messages", { "author" => { "id" => "u1" } },
           bearer(bridge_token)

      expect(last_response.status).to eq(422)
      expect(models.api_wrapper_pending_event.count).to eq(0)
    end

    it "rejects a body past the length cap" do
      channel!
      oversize = "x" * (Rubotty::ControlPlane::ApiWrapperEvents::MAX_BODY + 1)
      post "/communities/sample/bridge/channels/support-42/messages",
           { "body" => oversize, "author" => { "id" => "u1" } }, bearer(bridge_token)

      expect(last_response.status).to eq(422)
      expect(models.api_wrapper_pending_event.count).to eq(0)
    end

    it "404s an ordinary developer key with no platform_account, never a 403" do
      channel!
      post "/communities/sample/bridge/channels/support-42/messages",
           { "body" => "hi", "author" => { "id" => "u1" } }, bearer(plain_developer_token)

      expect(last_response.status).to eq(404)
      expect(models.api_wrapper_pending_event.count).to eq(0)
    end

    it "404s a channel_id this account has no mapping for" do
      channel!(route_key: "some-other-channel")
      post "/communities/sample/bridge/channels/support-42/messages",
           { "body" => "hi", "author" => { "id" => "u1" } }, bearer(bridge_token)

      expect(last_response.status).to eq(404)
    end

    it "404s a channel belonging to a different platform_account" do
      channel!(account: "someone-elses-bridge")
      post "/communities/sample/bridge/channels/support-42/messages",
           { "body" => "hi", "author" => { "id" => "u1" } }, bearer(bridge_token)

      expect(last_response.status).to eq(404)
    end

    it "404s identically for another community's slug as for a channel that does not exist, never a 403" do
      channel!
      now = Time.now
      other = models.community.create(slug: "other-co", name: "Other Co", status: "active", settings: "{}",
                                      created_at: now, updated_at: now)

      wrong_community = begin
        post "/communities/#{other.slug}/bridge/channels/support-42/messages",
             { "body" => "hi", "author" => { "id" => "u1" } }, bearer(bridge_token)
        [last_response.status, last_response.body]
      end
      no_such_channel = begin
        post "/communities/sample/bridge/channels/no-such-channel/messages",
             { "body" => "hi", "author" => { "id" => "u1" } }, bearer(bridge_token)
        [last_response.status, last_response.body]
      end

      expect(wrong_community).to eq(no_such_channel)
    end

    it "rejects an unauthenticated caller" do
      channel!
      post "/communities/sample/bridge/channels/support-42/messages", { "body" => "hi" }

      expect(last_response.status).to eq(401)
    end
  end

  describe "PATCH /communities/:slug/bridge/channels/:channel_id/messages/:message_id" do
    it "queues the edit and answers 202" do
      channel!
      patch "/communities/sample/bridge/channels/support-42/messages/900",
            { "body" => "edited", "author" => { "id" => "u1" } }, bearer(bridge_token)

      expect(last_response.status).to eq(202)
      row = models.api_wrapper_pending_event.order(:id).last
      expect(row.kind).to eq(Rubotty::ControlPlane::ApiWrapperEvents::KIND_EDIT)
      expect(row.target_native_id).to eq("900")
      expect(row.body).to eq("edited")
    end

    it "rejects an empty body" do
      channel!
      patch "/communities/sample/bridge/channels/support-42/messages/900",
            { "body" => "  ", "author" => { "id" => "u1" } }, bearer(bridge_token)

      expect(last_response.status).to eq(422)
    end
  end

  describe "DELETE /communities/:slug/bridge/channels/:channel_id/messages/:message_id" do
    it "queues the delete and answers 202" do
      channel!
      delete "/communities/sample/bridge/channels/support-42/messages/900", { "author" => { "id" => "u1" } },
             bearer(bridge_token)

      expect(last_response.status).to eq(202)
      row = models.api_wrapper_pending_event.order(:id).last
      expect(row.kind).to eq(Rubotty::ControlPlane::ApiWrapperEvents::KIND_DELETE)
      expect(row.target_native_id).to eq("900")
    end
  end

  describe "reactions" do
    it "PUT queues a reaction add and answers 202" do
      channel!
      put "/communities/sample/bridge/channels/support-42/messages/900/reactions",
          { "author" => { "id" => "u1" }, "reaction" => { "emoji" => "\u{1F44D}" } }, bearer(bridge_token)

      expect(last_response.status).to eq(202)
      row = models.api_wrapper_pending_event.order(:id).last
      expect(row.kind).to eq(Rubotty::ControlPlane::ApiWrapperEvents::KIND_REACTION_ADD)
      expect(row.reaction_emoji).to eq("\u{1F44D}")
    end

    it "DELETE queues a reaction remove and answers 202" do
      channel!
      delete "/communities/sample/bridge/channels/support-42/messages/900/reactions",
             { "author" => { "id" => "u1" }, "reaction" => { "emoji" => "\u{1F44D}" } }, bearer(bridge_token)

      expect(last_response.status).to eq(202)
      row = models.api_wrapper_pending_event.order(:id).last
      expect(row.kind).to eq(Rubotty::ControlPlane::ApiWrapperEvents::KIND_REACTION_REMOVE)
    end

    it "supports a custom emoji instead of a unicode one" do
      channel!
      put "/communities/sample/bridge/channels/support-42/messages/900/reactions",
          { "author" => { "id" => "u1" }, "reaction" => { "custom_id" => "party_blob", "custom_name" => "party" } },
          bearer(bridge_token)

      expect(last_response.status).to eq(202)
      row = models.api_wrapper_pending_event.order(:id).last
      expect(row.reaction_custom_id).to eq("party_blob")
      expect(row.reaction_custom_name).to eq("party")
    end

    it "rejects a reaction with neither emoji nor custom_id" do
      channel!
      put "/communities/sample/bridge/channels/support-42/messages/900/reactions",
          { "author" => { "id" => "u1" }, "reaction" => {} }, bearer(bridge_token)

      expect(last_response.status).to eq(422)
      expect(models.api_wrapper_pending_event.count).to eq(0)
    end
  end

  # A member arriving or going, which a game server's stream is mostly made of,
  # queued as its own kind rather than as a chat line saying somebody joined.
  describe "the channel members routes" do
    it "queues a join" do
      channel!
      post "/communities/sample/bridge/channels/support-42/members",
           { "author" => { "id" => "u1", "name" => "Remote Ada" } }, bearer(bridge_token)

      expect(last_response.status).to eq(202)
      row = models.api_wrapper_pending_event.order(:id).last
      expect(row.kind).to eq(Rubotty::ControlPlane::ApiWrapperEvents::KIND_JOIN)
      expect(row.author_native_id).to eq("u1")
      expect(row.author_display_name).to eq("Remote Ada")
    end

    it "queues a leave" do
      channel!
      delete "/communities/sample/bridge/channels/support-42/members",
             { "author" => { "id" => "u1" } }, bearer(bridge_token)

      expect(last_response.status).to eq(202)
      expect(models.api_wrapper_pending_event.order(:id).last.kind)
        .to eq(Rubotty::ControlPlane::ApiWrapperEvents::KIND_LEAVE)
    end

    # Unlike a message, where an anonymous actor still leaves something worth
    # relaying, a membership event naming nobody says only that somebody
    # somewhere came or went.
    it "rejects a membership event that names nobody" do
      channel!
      post "/communities/sample/bridge/channels/support-42/members", { "author" => {} }, bearer(bridge_token)

      expect(last_response.status).to eq(422)
      expect(models.api_wrapper_pending_event.count).to eq(0)
    end

    it "refuses a plain developer key, the same as every other route here" do
      channel!
      post "/communities/sample/bridge/channels/support-42/members",
           { "author" => { "id" => "u1" } }, bearer(plain_developer_token)

      expect(last_response.status).to eq(404)
      expect(models.api_wrapper_pending_event.count).to eq(0)
    end
  end
end
