# frozen_string_literal: true

require "spec_helper"
require "rubotty/api"
require "rack/test"

# A webhook created over form encoding keeps its room_key. write_body_params
# skips room_key when copying form params, since the room-scoped feature
# routes carry it as a path segment, but this route reads it as a real field,
# so it arrived as "", which the store reads as every room, not just one.
RSpec.describe "a webhook's room scope over form encoding (#403)", :control_plane do
  include Rack::Test::Methods

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }
  let(:deps) { Rubotty::Api::Deps.new(db: db, logger: Rubotty::Log.null, rate_max: 200) }
  let(:app) { Rubotty::Api::App.assemble(deps: deps, env: {}) }
  let(:keys) { Rubotty::ControlPlane::ApiKeys.new(models: models) }

  def admin
    { "HTTP_AUTHORIZATION" => "Bearer #{keys.issue(scope: 'administrator', label: 'admin').token}" }
  end

  def created_row = models.webhook_subscription.order(:id).last

  it "stores the room_key a form-encoded create asked for" do
    post "/admin/communities/sample/webhooks",
         { url: "https://example.invalid/events", event_types: "message.relayed", room_key: "general" },
         admin

    expect(last_response.status).to eq(201)
    expect(created_row.room_key).to eq("general")
  end

  # The YAML path always worked, and the two have to agree or the wire-format
  # promise is only half true.
  it "stores the same room_key a YAML create asks for" do
    post "/admin/communities/sample/webhooks",
         YAMLCamel.dump({ "url" => "https://example.invalid/events",
                          "event_types" => "message.relayed", "room_key" => "general" }),
         admin.merge("CONTENT_TYPE" => "application/yaml")

    expect(last_response.status).to eq(201)
    expect(created_row.room_key).to eq("general")
  end

  it "still subscribes to every room when no room_key is given" do
    post "/admin/communities/sample/webhooks",
         { url: "https://example.invalid/events", event_types: "message.relayed" }, admin

    expect(last_response.status).to eq(201)
    expect(created_row.room_key.to_s).to eq("")
  end

  # The reason room_key was on the skip list in the first place. A room-scoped
  # feature route takes it from the path, and a form field of the same name must
  # not be able to redirect the write to another room.
  it "still refuses to let a form field shadow a room_key in the path" do
    patch "/communities/sample/rooms/general/features/word_filter",
          { enabled: "true", room_key: "somewhere-else" }, admin

    expect(last_response.status).to eq(200)
    rows = models.feature_setting.where(community_id: community.id, feature: "word_filter").all
    expect(rows.map { |row| row.room_id }.compact).not_to be_empty
    general = models.room.where(community_id: community.id, room_key: "general").first
    expect(rows.map(&:room_id)).to include(general.id)
  end

  # Same shape one level up: slug is a path segment on every one of these.
  it "still refuses to let a form field shadow the slug in the path" do
    post "/admin/communities/sample/webhooks",
         { url: "https://example.invalid/events", event_types: "message.relayed",
           slug: "other-co" }, admin

    expect(last_response.status).to eq(201)
    expect(created_row.community_id).to eq(community.id)
  end
end
