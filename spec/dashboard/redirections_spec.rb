# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"
require "rack/test"

# The Redirections page: what has been moved out of this community's rooms and
# into which others, plus the one control that changes anything, stopping a move
# that is still reposting. The page rides :view_community, so an operator who runs
# the community can read it; the stop button is its own grant.
RSpec.describe "Rubotty::Dashboard::App redirections", :control_plane do
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

  def move(community_row, operator: "sample_owner", source: "tg-general", target: "right-room",
           count: 3, status: Rubotty::ControlPlane::Redirections::POSTING)
    now = Time.now
    models.redirection.create(
      community_id: community_row.id, source_endpoint_id: source, target_room_id: target,
      operator: operator, message_count: count, status: status, step_index: 0,
      plan: "[]", created_at: now, updated_at: now
    )
  end

  # The same stub role the moderation specs use, so the routes can be checked apart
  # from whatever the permission matrix decides.
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

    it "renders, with a link in the community's own nav" do
      get "/communities/sample/redirections"

      expect(last_response.status).to eq(200)
      expect(community_navigation_paths).to include("/communities/sample/redirections")
    end

    it "shows who moved what, out of where and into where" do
      move(community)
      get "/communities/sample/redirections"

      expect(last_response.body).to include("sample_owner")
      expect(last_response.body).to include("tg-general")
      expect(last_response.body).to include("right-room")
    end

    it "never shows another community's moves" do
      other = models.community.create(slug: "other", name: "Other", status: "active", settings: "{}",
                                      created_at: Time.now, updated_at: Time.now)
      move(other, operator: "somebody-else")
      get "/communities/sample/redirections"

      expect(last_response.body).not_to include("somebody-else")
    end

    it "says so plainly when nothing has been moved" do
      get "/communities/sample/redirections"

      expect(last_response.body).to include("Nothing has been moved")
    end

    it "stops a move that is still reposting" do
      row = move(community)
      post "/communities/sample/redirections/#{row.id}/stop"

      expect(models.redirection[row.id].status).to eq("cancelled")
      expect(models.redirection[row.id].plan).to be_nil
    end

    # The half that must not be stoppable: once the reposts are all in, the run
    # exists in both rooms and stopping leaves it there.
    it "refuses to stop a move that has started clearing the original" do
      row = move(community, status: Rubotty::ControlPlane::Redirections::DELETING)
      post "/communities/sample/redirections/#{row.id}/stop"

      expect(models.redirection[row.id].status).to eq("deleting")
    end

    it "never stops a move belonging to another community" do
      other = models.community.create(slug: "other", name: "Other", status: "active", settings: "{}",
                                      created_at: Time.now, updated_at: Time.now)
      row = move(other)
      post "/communities/sample/redirections/#{row.id}/stop"

      expect(models.redirection[row.id].status).to eq("posting")
    end
  end

  describe "an operator who runs this community" do
    let(:role) { stub_role_class.new([:view_community], community.id) }
    let(:app) { app_as(role) }

    it "may read the log without any grant of its own" do
      move(community)
      get "/communities/sample/redirections"

      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("sample_owner")
    end

    # Flat rather than missing, so a reader can see that stopping a move is
    # something an operator here can do.
    it "is offered a flat, disabled stop button without the grant" do
      move(community)
      get "/communities/sample/redirections"

      expect(last_response.body).to include("Stop</button>")
      expect(last_response.body).to include(%(class="disabled" disabled title="Read only))
    end

    it "may not stop a move without the grant" do
      row = move(community)
      post "/communities/sample/redirections/#{row.id}/stop"

      expect(last_response.status).to eq(403)
      expect(models.redirection[row.id].status).to eq("posting")
    end
  end

  describe "an operator holding the redirection grant" do
    let(:role) { stub_role_class.new(%i[view_community manage_redirection], community.id) }
    let(:app) { app_as(role) }

    it "is offered the stop button, live" do
      move(community)
      get "/communities/sample/redirections"

      expect(last_response.body).to include(%(<button type="submit" data-grant="manage_redirection">Stop</button>))
    end

    it "may stop a move" do
      row = move(community)
      post "/communities/sample/redirections/#{row.id}/stop"

      expect(models.redirection[row.id].status).to eq("cancelled")
    end
  end

  describe "an operator whose grant does not cover this community" do
    let(:role) { stub_role_class.new(%i[view_community manage_redirection], community.id + 999) }
    let(:app) { app_as(role) }

    it "cannot open the page at all" do
      get "/communities/sample/redirections"

      expect(last_response.status).to eq(403)
    end
  end
end
