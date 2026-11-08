# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"
require "rack/test"

# The Alerts page: what this community's scripts have raised, newest first, plus
# the two controls that change anything. The page rides :view_community, so an
# operator who runs the community can read it; marking an alert seen is its own
# grant, since it hides work from the next operator to look.
RSpec.describe "Rubotty::Dashboard::App alerts", :control_plane do
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

  def community_navigation_paths(body = last_response.body)
    source = body[%r{<script id="rb-shell-data" type="application/json">(.*?)</script>}m, 1]
    document = JSON.parse(source)
    scope = document.fetch("scopes").find { |entry| entry.fetch("key") == "community" }
    scope.fetch("groups").flat_map { |group| group.fetch("items") }.map { |item| item.fetch("path") }
  end

  def alert(community_row, text: "ada used a slur in general.", mode: "quiet",
            script: "slur_alert", room_key: "general", delivered_to: 0, seen_at: nil)
    models.alert.create(
      community_id: community_row.id, text: text, mode: mode, script: script,
      room_key: room_key, delivered_to: delivered_to, seen_at: seen_at, created_at: Time.now
    )
  end

  # The same stub role the redirections specs use, so the routes can be checked
  # apart from whatever the permission matrix decides.
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

  describe "unauthenticated" do
    let(:app) { Rubotty::Dashboard::App.assemble(deps: deps, env: env) }

    it "gates the alerts page behind a session" do
      get "/communities/sample/alerts"

      expect(last_response.status).to eq(302)
      expect(last_response.headers["location"]).to end_with("/login")
    end
  end

  describe "an administrator session" do
    let(:app) { Rubotty::Dashboard::App.assemble(deps: deps, env: env) }

    before { login! }

    it "renders, with a link in the community's own nav" do
      get "/communities/sample/alerts"

      expect(last_response.status).to eq(200)
      expect(community_navigation_paths).to include("/communities/sample/alerts")
    end

    it "shows what was raised, in which room, by which script" do
      alert(community)
      get "/communities/sample/alerts"

      expect(last_response.body).to include("ada used a slur in general.")
      expect(last_response.body).to include("slur_alert")
      expect(last_response.body).to include("general")
    end

    it "lists them newest first" do
      alert(community, text: "older")
      alert(community, text: "newer")
      get "/communities/sample/alerts"

      expect(last_response.body.index("newer")).to be < last_response.body.index("older")
    end

    it "never shows another community's alerts" do
      other = models.community.create(slug: "other", name: "Other", status: "active", settings: "{}",
                                      created_at: Time.now, updated_at: Time.now)
      alert(other, text: "somebody else's problem")
      get "/communities/sample/alerts"

      expect(last_response.body).not_to include("somebody else's problem")
    end

    it "says so plainly when nothing has been raised" do
      get "/communities/sample/alerts"

      expect(last_response.body).to include("No script in this community has raised an alert")
    end

    it "says how many operators a loud alert reached" do
      alert(community, mode: "loud", delivered_to: 2)
      get "/communities/sample/alerts"

      expect(last_response.body).to include("loud, DMed 2")
    end

    # It went out loud and landed nowhere, because nobody is reachable by DM.
    it "says when a loud alert reached nobody" do
      alert(community, mode: "loud", delivered_to: 0)
      get "/communities/sample/alerts"

      expect(last_response.body).to include("loud, reached nobody")
    end

    it "marks one seen" do
      row = alert(community)
      post "/communities/sample/alerts/#{row.id}/seen"

      expect(models.alert[row.id].seen_at).not_to be_nil
    end

    it "marks everything outstanding seen at once" do
      2.times { alert(community) }
      post "/communities/sample/alerts/seen"

      expect(models.alert.where(seen_at: nil).count).to eq(0)
      follow_redirect!
      expect(last_response.body).to include("Marked 2 alerts seen")
    end

    it "never marks an alert belonging to another community" do
      other = models.community.create(slug: "other", name: "Other", status: "active", settings: "{}",
                                      created_at: Time.now, updated_at: Time.now)
      row = alert(other)
      post "/communities/sample/alerts/#{row.id}/seen"

      expect(models.alert[row.id].seen_at).to be_nil
    end

    it "marks nothing outstanding in another community" do
      other = models.community.create(slug: "other", name: "Other", status: "active", settings: "{}",
                                      created_at: Time.now, updated_at: Time.now)
      row = alert(other)
      post "/communities/sample/alerts/seen"

      expect(models.alert[row.id].seen_at).to be_nil
    end

    it "says so for an id that is not an alert" do
      post "/communities/sample/alerts/9999/seen"
      follow_redirect!

      expect(last_response.body).to include("No such alert")
    end
  end

  describe "an operator who runs this community" do
    let(:role) { stub_role_class.new([:view_community], community.id) }
    let(:app) { app_as(role) }

    it "may read the page without any grant of its own" do
      alert(community)
      get "/communities/sample/alerts"

      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("ada used a slur in general.")
    end

    # A reader who cannot clear an alert should still see that clearing it is
    # a thing an operator here can do, rather than wondering whether the
    # page has the control at all.
    it "is offered both buttons flat and disabled without the grant" do
      alert(community)
      get "/communities/sample/alerts"

      expect(last_response.body).to include("Mark seen</button>")
      expect(last_response.body).to include("Mark all")
      expect(last_response.body).to include(%(class="secondary disabled" disabled))
      expect(last_response.body).to include(%(class="disabled" disabled title="Read only))
    end

    it "may not mark one seen without the grant" do
      row = alert(community)
      post "/communities/sample/alerts/#{row.id}/seen"

      expect(last_response.status).to eq(403)
      expect(models.alert[row.id].seen_at).to be_nil
    end

    it "may not mark everything seen without the grant" do
      row = alert(community)
      post "/communities/sample/alerts/seen"

      expect(last_response.status).to eq(403)
      expect(models.alert[row.id].seen_at).to be_nil
    end
  end

  describe "an operator holding the alerts grant" do
    let(:role) { stub_role_class.new(%i[view_community manage_alerts], community.id) }
    let(:app) { app_as(role) }

    it "is offered both buttons, live" do
      alert(community)
      get "/communities/sample/alerts"

      expect(last_response.body).to include("Mark seen</button>")
      expect(last_response.body).to include("Mark all 1 seen")
      expect(last_response.body).not_to include("Read only")
    end

    it "is offered no mark-all button once nothing is outstanding" do
      alert(community, seen_at: Time.now)
      get "/communities/sample/alerts"

      expect(last_response.body).not_to include("Mark all")
    end

    it "may mark one seen" do
      row = alert(community)
      post "/communities/sample/alerts/#{row.id}/seen"

      expect(models.alert[row.id].seen_at).not_to be_nil
    end

    it "may mark everything seen" do
      2.times { alert(community) }
      post "/communities/sample/alerts/seen"

      expect(models.alert.where(seen_at: nil).count).to eq(0)
    end
  end

  describe "an operator whose grant does not cover this community" do
    let(:role) { stub_role_class.new(%i[view_community manage_alerts], community.id + 999) }
    let(:app) { app_as(role) }

    it "cannot open the page at all" do
      get "/communities/sample/alerts"

      expect(last_response.status).to eq(403)
    end

    it "cannot mark anything seen" do
      row = alert(community)
      post "/communities/sample/alerts/#{row.id}/seen"

      expect(last_response.status).to eq(403)
      expect(models.alert[row.id].seen_at).to be_nil
    end
  end
end
