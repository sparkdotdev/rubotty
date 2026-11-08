# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"
require "rack/test"

# The moderation page (mute and unmute a user per community) and the
# operator-scoped extension of the audit log. Both are gated by
# authorize! on :moderate_user and :view_audit_log, and these examples
# assert the routes call it with the right action and community.
RSpec.describe "Rubotty::Dashboard::App moderation and mod-log", :control_plane do
  include Rack::Test::Methods

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:secret) { "open-sesame" }
  let(:env) { { "DASHBOARD_SECRET" => secret } }
  let(:deps) { Rubotty::Dashboard::Deps.new(db: db, logger: Rubotty::Log.null) }
  let(:community) { models.community.where(slug: "sample").first }

  def login!
    post "/login", secret: secret
  end

  def active_sanction_row(native_id:)
    db[:active_sanctions].where(community: "sample", subject_native_id: native_id).first
  end

  # A stub role independent of Rubotty::Dashboard::Role, told only which actions to
  # allow and which community to scope them to, so the routes can be checked apart
  # from whatever the real matrix decides.
  let(:stub_role_class) do
    Struct.new(:allowed_actions, :scoped_community_id) do
      def administrator? = false

      def operator? = true

      def kind = :operator

      def readable_community_ids = [scoped_community_id]

      def write_actions = allowed_actions

      def can?(action, community:)
        return false unless allowed_actions.include?(action)
        return true if community == Rubotty::Dashboard::Role::DEPLOYMENT

        !community.nil? && community.id == scoped_community_id
      end
    end
  end

  def app_as(role)
    operator_deps = deps
    Class.new(Rubotty::Dashboard::App) do
      set :deps, operator_deps
      helpers do
        define_method(:authenticated?) { true }
        define_method(:current_role) { role }
      end
    end
  end

  describe "an administrator session" do
    let(:app) { Rubotty::Dashboard::App.assemble(deps: deps, env: env) }

    before { login! }

    describe "GET /communities/:slug/moderation" do
      it "renders" do
        get "/communities/sample/moderation"
        expect(last_response.status).to eq(200)
      end

      it "lists currently active mutes" do
        deps.moderation.mute(community: community, adapter: "telegram", native_id: "u1",
                             username: "troll", duration: "1h")
        get "/communities/sample/moderation"
        expect(last_response.body).to include("troll")
      end

      it "shows a permanent mute (a nil until_at, as the warnings ladder can now issue) as such rather than blank" do
        db[:active_sanctions].insert(
          community: "sample", adapter: "telegram", subject_native_id: "u1", subject_username: "troll",
          action: "mute", endpoints: "[]", until_at: nil, active: true, created_at: Time.now
        )
        get "/communities/sample/moderation"
        expect(last_response.status).to eq(200)
        expect(last_response.body).to include("permanent")
      end

      it "finds a search match from the identity directory, with a ready-to-submit mute form" do
        deps.identities.record(community_id: community.id, adapter: :telegram, native_id: "u5",
                               username: "ada", display: "Ada Lovelace")
        get "/communities/sample/moderation", q: "ada"
        expect(last_response.status).to eq(200)
        expect(last_response.body).to include("Ada Lovelace")
        expect(last_response.body).to include('value="u5"')
      end
    end

    describe "POST /communities/:slug/moderation/mute" do
      it "records an active sanction and flashes a confirmation" do
        post "/communities/sample/moderation/mute",
             adapter: "telegram", native_id: "u1", username: "troll", duration: "1h", reason: "spam"
        expect(last_response.status).to eq(302)

        row = active_sanction_row(native_id: "u1")
        expect(row).not_to be_nil
        expect(row[:action]).to eq("mute")

        follow_redirect!
        expect(last_response.body).to include("Muted")
      end

      it "schedules an expiry job a running bot's own scheduler would pick up" do
        post "/communities/sample/moderation/mute", adapter: "telegram", native_id: "u1", duration: "1h"
        expect(db[:scheduled_jobs].where(kind: "expire_sanction").count).to eq(1)
      end

      it "flashes ModerationActions::Invalid rather than 500ing on a missing user id" do
        post "/communities/sample/moderation/mute", adapter: "telegram", native_id: ""
        expect(last_response.status).to eq(302)
        expect(active_sanction_row(native_id: "")).to be_nil

        follow_redirect!
        expect(last_response.body).to include("platform and a user id")
      end

      it "flashes an unreadable duration rather than recording a bad sanction" do
        post "/communities/sample/moderation/mute", adapter: "telegram", native_id: "u1", duration: "banana"
        expect(active_sanction_row(native_id: "u1")).to be_nil
      end

      it "records a durable audit event through the same dashboard source other writes use" do
        post "/communities/sample/moderation/mute", adapter: "telegram", native_id: "u1", reason: "spam"
        event = deps.audit.query(community: "sample", action: "mute").first
        expect(event.source).to eq("dashboard")
        expect(event.reason).to eq("spam")
      end
    end

    describe "POST /communities/:slug/moderation/:id/unmute" do
      it "lifts an active mute" do
        deps.moderation.mute(community: community, adapter: "telegram", native_id: "u1", duration: "1h")
        row = active_sanction_row(native_id: "u1")

        post "/communities/sample/moderation/#{row[:id]}/unmute"
        expect(last_response.status).to eq(302)
        expect(active_sanction_row(native_id: "u1")[:active]).to satisfy { |v| [false, 0].include?(v) }
      end

      it "flashes an error for an id that is not an active mute in this community" do
        post "/communities/sample/moderation/999999/unmute"
        expect(last_response.status).to eq(302)
        follow_redirect!
        expect(last_response.body).to include("No such active mute")
      end
    end

    describe "GET /communities/:slug/audit (the operator-scoped mod-log extension, issue #165)" do
      it "renders this community's events" do
        deps.audit.record(community: "sample", source: "moderation", action: "delete", reason: "spam")
        get "/communities/sample/audit"
        expect(last_response.status).to eq(200)
        expect(last_response.body).to include("delete")
        expect(last_response.body).to include("spam")
      end

      it "never shows another community's audit events" do
        other = models.community.create(slug: "other", name: "Other", status: "active",
                                        settings: "{}", created_at: Time.now, updated_at: Time.now)
        deps.audit.record(community: other.slug, source: "moderation", action: "ban", reason: "raid")
        get "/communities/sample/audit"
        expect(last_response.body).not_to include("raid")
      end

      it "filters by source and action, like the cross-community picker does" do
        deps.audit.record(community: "sample", source: "moderation", action: "delete")
        deps.audit.record(community: "sample", source: "dashboard", action: "mute")
        get "/communities/sample/audit", action: "mute"
        expect(last_response.body).to include("mute")
        expect(last_response.body).not_to include(">delete<")
      end
    end
  end

  describe "an operator whose grant covers this community" do
    let(:app) { app_as(stub_role_class.new(%i[moderate_user view_audit_log view_community], community.id)) }

    it "reaches the moderation page and can mute and unmute" do
      get "/communities/sample/moderation"
      expect(last_response.status).to eq(200)

      post "/communities/sample/moderation/mute", adapter: "telegram", native_id: "u1", duration: "1h"
      expect(last_response.status).to eq(302)
      row = active_sanction_row(native_id: "u1")
      expect(row).not_to be_nil

      post "/communities/sample/moderation/#{row[:id]}/unmute"
      expect(last_response.status).to eq(302)
      expect(active_sanction_row(native_id: "u1")[:active]).to satisfy { |v| [false, 0].include?(v) }
    end

    it "reaches its own community's mod-log" do
      get "/communities/sample/audit"
      expect(last_response.status).to eq(200)
    end

    it "is still denied an admin-only route in the same community (the stub only grants the two new actions)" do
      get "/communities/sample/platforms"
      expect(last_response.status).to eq(403)
    end
  end

  describe "an operator whose grant does NOT cover this community" do
    let(:other_community) do
      models.community.create(slug: "other", name: "Other", status: "active",
                              settings: "{}", created_at: Time.now, updated_at: Time.now)
    end
    let(:app) { app_as(stub_role_class.new(%i[moderate_user view_audit_log view_community], other_community.id)) }

    it "is denied the moderation page" do
      get "/communities/sample/moderation"
      expect(last_response.status).to eq(403)
    end

    it "is denied muting, and nothing is recorded" do
      post "/communities/sample/moderation/mute", adapter: "telegram", native_id: "u1"
      expect(last_response.status).to eq(403)
      expect(active_sanction_row(native_id: "u1")).to be_nil
    end

    it "is denied unmuting an existing sanction" do
      deps.moderation.mute(community: community, adapter: "telegram", native_id: "u1", duration: "1h")
      row = active_sanction_row(native_id: "u1")

      post "/communities/sample/moderation/#{row[:id]}/unmute"
      expect(last_response.status).to eq(403)
      expect(active_sanction_row(native_id: "u1")[:active]).to satisfy { |v| [true, 1].include?(v) }
    end

    it "is denied this community's mod-log" do
      get "/communities/sample/audit"
      expect(last_response.status).to eq(403)
    end
  end
end
