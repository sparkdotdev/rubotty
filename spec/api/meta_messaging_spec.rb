# frozen_string_literal: true

require "spec_helper"
require "rubotty/api"
require "rack/test"

# The room-level react/edit/delete surface: a developer or administrator key
# acting on a message POST .../rooms/:room_key/messages minted, addressed by
# room and that same id, never by a bridge channel_id. Driven in-process with
# rack-test, with the message map seeded directly since no bot relays here.
RSpec.describe "the REST API's room-level message actions", :control_plane do
  include Rack::Test::Methods

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }
  let(:room) { models.room.where(community_id: community.id, room_key: "general").first }
  let(:storage) { Rubotty::Storage::SequelStore.new(db: db, logger: Rubotty::Log.null).tap(&:migrate!) }
  let(:deps) { Rubotty::Api::Deps.new(db: db, logger: Rubotty::Log.null, rate_max: 200, storage: storage) }
  let(:app) { Rubotty::Api::App.assemble(deps: deps, env: {}) }
  let(:keys) { Rubotty::ControlPlane::ApiKeys.new(models: models) }

  def bearer(token) = { "HTTP_AUTHORIZATION" => "Bearer #{token}" }

  def developer_token(on: community)
    keys.issue(scope: "developer", community: on, label: "test developer key").token
  end

  def administrator_token
    keys.issue(scope: "administrator", label: "test admin key").token
  end

  # A second tenant with a room called "general" too, so a lookup that forgot
  # to scope by community would serve the wrong one, matching
  # live_messaging_spec's own fixture for the identical reason.
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

  # What {Features::Bridge} leaves in the message map once it has actually
  # relayed a room-level post: one row per channel the post landed in, source
  # the room's own synthetic API ref. Seeded directly, standing in for the bot
  # process this suite does not run.
  def seed_meta_message!(message_id: "42", on: room, destinations: [%w[tg-general 900]])
    source = Rubotty::Core::MessageRef.new(Rubotty::Adapters::Api.endpoint_key_for(on.id), message_id)
    destinations.each do |endpoint_id, native_id|
      storage.record(source: source, destination: Rubotty::Core::MessageRef.new(endpoint_id, native_id),
                     room_id: on.id)
    end
  end

  shared_examples "a meta-level route" do
    it "404s, not 403, when a developer key addresses another community's room" do
      other_community
      seed_meta_message!

      request.call("/communities/other-co/rooms/general", "42", bearer(developer_token))

      expect(last_response.status).to eq(404)
    end

    it "404s identically for a room that does not exist at all" do
      other_community
      seed_meta_message!

      real = begin
        request.call("/communities/other-co/rooms/general", "42", bearer(developer_token))
        [last_response.status, last_response.body]
      end
      imaginary = begin
        request.call("/communities/sample/rooms/no-such-room", "42", bearer(developer_token))
        [last_response.status, last_response.body]
      end

      expect(real).to eq(imaginary)
    end

    it "404s a message id the map holds nothing for, honestly, rather than queuing a no-op" do
      request.call("/communities/sample/rooms/general", "no-such-id", bearer(developer_token))

      expect(last_response.status).to eq(404)
      expect(models.api_pending_message_action.count).to eq(0)
    end

    it "404s a message id that belongs to a different room" do
      other = models.room.create(
        community_id: community.id, room_key: "other-room", label: "Other Room",
        display_name: "{}", created_at: Time.now, updated_at: Time.now
      )
      seed_meta_message!(on: other)

      request.call("/communities/sample/rooms/general", "42", bearer(developer_token))

      expect(last_response.status).to eq(404)
    end

    it "rejects an unauthenticated caller" do
      seed_meta_message!

      request.call("/communities/sample/rooms/general", "42", {})

      expect(last_response.status).to eq(401)
    end

    it "lets an administrator key act on any community's room" do
      other = other_community
      other_room = other.rooms_dataset.where(room_key: "general").first
      seed_meta_message!(on: other_room)

      request.call("/communities/other-co/rooms/general", "42", bearer(administrator_token))

      expect(last_response.status).to eq(success_status)
    end
  end

  describe "PUT /communities/:slug/rooms/:room_key/messages/:message_id/reactions" do
    let(:success_status) { 202 }
    let(:request) do
      lambda do |base, message_id, headers|
        put "#{base}/messages/#{message_id}/reactions", { "reaction" => { "emoji" => "\u{1F44D}" } }, headers
      end
    end

    include_examples "a meta-level route"

    it "queues a reaction add and answers 202" do
      seed_meta_message!

      put "/communities/sample/rooms/general/messages/42/reactions",
          { "reaction" => { "emoji" => "\u{1F44D}" } }, bearer(developer_token)

      expect(last_response.status).to eq(202)
      answer = YAMLCamel.load(last_response.body)
      expect(answer["status"]).to eq("queued")

      row = models.api_pending_message_action.order(:id).last
      expect(row.room_id).to eq(room.id)
      expect(row.message_id).to eq("42")
      expect(row.kind).to eq(Rubotty::ControlPlane::ApiMessageActions::KIND_REACTION_ADD)
      expect(row.reaction_emoji).to eq("\u{1F44D}")
      expect(row.author_label).to eq("test developer key@api-client")
    end

    it "supports a custom emoji instead of a unicode one" do
      seed_meta_message!

      put "/communities/sample/rooms/general/messages/42/reactions",
          { "reaction" => { "custom_id" => "party_blob", "custom_name" => "party" } }, bearer(developer_token)

      expect(last_response.status).to eq(202)
      row = models.api_pending_message_action.order(:id).last
      expect(row.reaction_custom_id).to eq("party_blob")
      expect(row.reaction_custom_name).to eq("party")
    end

    it "rejects a reaction with neither emoji nor custom_id" do
      seed_meta_message!

      put "/communities/sample/rooms/general/messages/42/reactions", { "reaction" => {} }, bearer(developer_token)

      expect(last_response.status).to eq(422)
      expect(models.api_pending_message_action.count).to eq(0)
    end
  end

  describe "DELETE /communities/:slug/rooms/:room_key/messages/:message_id/reactions" do
    let(:success_status) { 202 }
    let(:request) do
      lambda do |base, message_id, headers|
        delete "#{base}/messages/#{message_id}/reactions", { "reaction" => { "emoji" => "\u{1F44D}" } }, headers
      end
    end

    include_examples "a meta-level route"

    it "queues a reaction remove and answers 202" do
      seed_meta_message!

      delete "/communities/sample/rooms/general/messages/42/reactions",
             { "reaction" => { "emoji" => "\u{1F44D}" } }, bearer(developer_token)

      expect(last_response.status).to eq(202)
      row = models.api_pending_message_action.order(:id).last
      expect(row.kind).to eq(Rubotty::ControlPlane::ApiMessageActions::KIND_REACTION_REMOVE)
    end
  end

  describe "PATCH /communities/:slug/rooms/:room_key/messages/:message_id" do
    let(:success_status) { 202 }
    let(:request) do
      lambda do |base, message_id, headers|
        patch "#{base}/messages/#{message_id}", { "body" => "edited" }, headers
      end
    end

    include_examples "a meta-level route"

    it "queues the edit and answers 202" do
      seed_meta_message!

      patch "/communities/sample/rooms/general/messages/42", { "body" => "edited text" }, bearer(developer_token)

      expect(last_response.status).to eq(202)
      answer = YAMLCamel.load(last_response.body)
      expect(answer["status"]).to eq("queued")

      row = models.api_pending_message_action.order(:id).last
      expect(row.kind).to eq(Rubotty::ControlPlane::ApiMessageActions::KIND_EDIT)
      expect(row.message_id).to eq("42")
      expect(row.body).to eq("edited text")
    end

    it "rejects an empty body" do
      seed_meta_message!

      patch "/communities/sample/rooms/general/messages/42", { "body" => "   " }, bearer(developer_token)

      expect(last_response.status).to eq(422)
      expect(models.api_pending_message_action.count).to eq(0)
    end

    it "rejects a body past the length cap" do
      seed_meta_message!
      oversize = "x" * (Rubotty::ControlPlane::ApiMessageActions::MAX_BODY + 1)

      patch "/communities/sample/rooms/general/messages/42", { "body" => oversize }, bearer(developer_token)

      expect(last_response.status).to eq(422)
      expect(models.api_pending_message_action.count).to eq(0)
    end
  end

  describe "DELETE /communities/:slug/rooms/:room_key/messages/:message_id" do
    let(:success_status) { 202 }
    let(:request) do
      lambda do |base, message_id, headers|
        delete "#{base}/messages/#{message_id}", {}, headers
      end
    end

    include_examples "a meta-level route"

    it "queues the delete and answers 202" do
      seed_meta_message!

      delete "/communities/sample/rooms/general/messages/42", {}, bearer(developer_token)

      expect(last_response.status).to eq(202)
      row = models.api_pending_message_action.order(:id).last
      expect(row.kind).to eq(Rubotty::ControlPlane::ApiMessageActions::KIND_DELETE)
      expect(row.message_id).to eq("42")
    end
  end

  # meta_message! fails closed with no message map wired at all, rather than
  # queuing an action nothing could ever have confirmed exists.
  describe "with no message map configured" do
    let(:deps) { Rubotty::Api::Deps.new(db: db, logger: Rubotty::Log.null, rate_max: 200) }

    it "404s rather than queuing an action" do
      delete "/communities/sample/rooms/general/messages/42", {}, bearer(developer_token)

      expect(last_response.status).to eq(404)
      expect(models.api_pending_message_action.count).to eq(0)
    end
  end
end
