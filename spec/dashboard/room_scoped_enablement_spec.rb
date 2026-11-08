# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"
require "rack/test"

# Per-room enablement for word filter and link filter: whether a feature is
# independently on for one room, distinct from the community-wide "all" default.
# Covers the tri-state Enabled control on each scope's own row, the Rooms page
# link into a room's scoped Features view, and the Config link back and forth.
RSpec.describe "Rubotty::Dashboard::App room-scoped feature enablement", :control_plane do
  include Rack::Test::Methods

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:secret) { "open-sesame" }
  let(:env) { { "DASHBOARD_SECRET" => secret } }
  let(:deps) { Rubotty::Dashboard::Deps.new(db: db, logger: Rubotty::Log.null) }
  let(:app) { Rubotty::Dashboard::App.assemble(deps: deps, env: env) }
  let(:community) { models.community.where(slug: "sample").first }

  def login!
    post "/login", secret: secret
  end

  def room_setting(feature:, room_key: "general")
    room = models.room.where(community_id: community.id, room_key: room_key).first
    models.feature_setting.where(community_id: community.id, room_id: room.id, feature: feature).first
  end

  before do
    login!
    @room_count = models.room.where(community_id: community.id).count
  end

  describe "the word filter's per-scope writes" do
    # A row per scope, so every room's row carries all three choices and the
    # community-wide row carries two: "all" has no broader scope to follow.
    it "offers on / off / follows all on a room row, and no follows-all on the community row" do
      post "/communities/sample/word-filter", selector: "all", op: "enable"

      get "/communities/sample/word-filter"
      body = last_response.body

      expect(body.scan(%(<option value="inherit">follows all</option>)).length).to eq(@room_count)
      # Every room follows an enabled "all", so each reads on without a row of its own.
      expect(body.scan(%(<option value="on" selected>on</option>)).length).to eq(@room_count + 1)
    end

    it "inherits the community's on state for a new room scope when left on Inherit" do
      post "/communities/sample/word-filter", selector: "all", op: "enable"

      post "/communities/sample/word-filter", selector: "general", op: "save", mode: "slurs_profanity"

      expect(room_setting(feature: "word_filter").enabled).to be(true)
    end

    it "forces a new room scope on in the same request when Force on is picked" do
      post "/communities/sample/word-filter", selector: "general", op: "save",
                                             mode: "slurs_profanity", enabled: "on"

      expect(room_setting(feature: "word_filter").enabled).to be(true)
      follow_redirect!
      expect(last_response.body).to include("forced on")
    end

    it "forces a new room scope off even if the community default is already on" do
      post "/communities/sample/word-filter", selector: "all", op: "enable"

      post "/communities/sample/word-filter", selector: "general", op: "save",
                                             mode: "slurs_profanity", enabled: "off"

      expect(room_setting(feature: "word_filter").enabled).to be(false)
    end

    it "shows a room its real state without it having a row of its own" do
      post "/communities/sample/word-filter", selector: "all", op: "enable"

      get "/communities/sample/word-filter"

      expect(last_response.body).to include("follows <code>all</code>")
      expect(room_setting(feature: "word_filter")).to be_nil
    end

    it "sets a room's mode from its own row without touching its custom words" do
      post "/communities/sample/word-filter", selector: "general", op: "save",
                                            mode: "slurs", custom: "housephrase"

      post "/communities/sample/word-filter", selector: "general", op: "scope",
                                            mode: "slurs_profanity", action: "flag", enabled: "on"

      config = JSON.parse(room_setting(feature: "word_filter").config)
      expect(config["mode"]).to eq("slurs_profanity")
      expect(config["action"]).to eq("flag")
      # The matrix row has no textarea, so a blank custom list is an absent field
      # rather than an instruction to wipe one.
      expect(config["custom"]).to eq(["housephrase"])
    end

    it "puts a room back on the community-wide setting when follows-all is picked" do
      post "/communities/sample/word-filter", selector: "general", op: "save", mode: "slurs"
      expect(room_setting(feature: "word_filter")).not_to be_nil

      post "/communities/sample/word-filter", selector: "general", op: "scope", enabled: "inherit"

      expect(room_setting(feature: "word_filter")).to be_nil
    end

    it "refuses to drop the community-wide row, which has nothing to fall back to" do
      post "/communities/sample/word-filter", selector: "all", op: "enable"

      post "/communities/sample/word-filter", selector: "all", op: "scope", enabled: "inherit"
      follow_redirect!

      expect(last_response.body).to include("no broader scope")
      expect(models.feature_setting.where(community_id: community.id, room_id: nil,
                                          feature: "word_filter").first).not_to be_nil
    end

    # Operators are exempt by default, so an admin testing the filter on themselves
    # sees nothing happen and concludes it is broken.
    it "shows the operator exemption on the page, ticked by default" do
      get "/communities/sample/word-filter"

      expect(last_response.body).to include("exempt operators")
      expect(last_response.body).to include("Operators are exempt by default")
      expect(last_response.body.scan(%r{name="exempt\[[^\]]+\]" value="on"\s+checked}).length).to be >= 1
    end

    it "includes operators once the box is unticked" do
      post "/communities/sample/word-filter", selector: "all", op: "scope", mode: "slurs",
                                            enabled: "on", exempt: { "all" => "off" }

      config = JSON.parse(models.feature_setting.where(community_id: community.id, room_id: nil,
                                                       feature: "word_filter").first.config)
      expect(config["exempt_operators"]).to be(false)
    end

    it "puts the exemption back when the box is ticked again" do
      post "/communities/sample/word-filter", selector: "all", op: "scope", mode: "slurs",
                                            enabled: "on", exempt: { "all" => "off" }
      post "/communities/sample/word-filter", selector: "all", op: "scope", mode: "slurs",
                                            enabled: "on", exempt: { "all" => "on" }

      config = JSON.parse(models.feature_setting.where(community_id: community.id, room_id: nil,
                                                       feature: "word_filter").first.config)
      expect(config["exempt_operators"]).to be(true)
    end
  end

  describe "the FAQ's per-scope writes" do
    it "offers the same three choices on a room row" do
      get "/communities/sample/faq"
      body = last_response.body

      expect(body.scan(%(<option value="inherit">follows all</option>)).length).to eq(@room_count)
    end

    it "puts a room back on the community-wide setting when follows-all is picked" do
      post "/communities/sample/faq", selector: "all", op: "enable"
      post "/communities/sample/faq", selector: "general", op: "scope", enabled: "off"
      expect(room_setting(feature: "faq").enabled).to be(false)

      post "/communities/sample/faq", selector: "general", op: "scope", enabled: "inherit"

      expect(room_setting(feature: "faq")).to be_nil
    end

    it "inherits the community's on state for a new room's first entry" do
      post "/communities/sample/faq", selector: "all", op: "enable"

      post "/communities/sample/faq", selector: "general", op: "add",
                                     trigger_type: "command", trigger: "rules", response: "Be kind."

      expect(room_setting(feature: "faq").enabled).to be(true)
    end
  end

  describe "GET /communities/:slug/rooms" do
    it "lists rooms and links each to its own scoped Features view, even with channel management off" do
      get "/communities/sample/rooms"
      body = last_response.body

      expect(body).to include("Channel management is off")
      expect(body).to include("general")
      expect(body).to include(%(/communities/sample/features?scope=general))
      expect(body).to include("Configure features for this room")
    end
  end

  describe "GET /communities/:slug/features Config link" do
    it "renders as a styled button, not a bare text link" do
      get "/communities/sample/features"
      expect(last_response.body).to match(%r{<a class="button secondary" href="[^"]*word-filter">Config</a>})
    end
  end

  describe "GET /communities/:slug/features/:feature/config" do
    it "links back to the Features page for the same scope, for enable/disable" do
      get "/communities/sample/features/link_filter/config", scope: "general"
      expect(last_response.body).to include(%(/communities/sample/features?scope=general))
    end
  end
end
