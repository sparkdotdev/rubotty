# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"
require "rack/test"
require "json"

# The route guards on top of the password login: current_role,
# require_admin! and authorize!(action, community:), as wired into every
# Sinatra route. Role#can? itself is exercised directly in role_spec.rb.
RSpec.describe "Rubotty::Dashboard::App authorization", :control_plane do
  include Rack::Test::Methods

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:secret) { "open-sesame" }
  let(:env) { { "DASHBOARD_SECRET" => secret } }
  let(:deps) { Rubotty::Dashboard::Deps.new(db: db, logger: Rubotty::Log.null) }
  let(:community) { models.community.where(slug: "sample").first }

  # A second community on the same control-plane db, so read-all has something to
  # read outside the operator's community_ids and write-own has something to be
  # denied against.
  let(:other_community_id) do
    Rubotty::ControlPlane::Seed.from_model(sample_model, models: models, slug: "other-co")
  end
  let(:other_community) { models.community[other_community_id] }

  def feature_row(comm, feature:)
    # feature_settings is room-scoped, so the community-wide default row that
    # selector "all" writes is the one with a NULL room_id.
    models.feature_setting.where(community_id: comm.id, room_id: nil, feature: feature).first
  end

  def enabled?(row)
    [true, 1, "1", "t", "true"].include?(row&.enabled)
  end

  def shell_navigation_labels(body = last_response.body)
    source = body[%r{<script id="rb-shell-data" type="application/json">(.*?)</script>}m, 1]
    JSON.parse(source).fetch("scopes").flat_map do |scope|
      scope.fetch("groups").flat_map { |group| group.fetch("items") }.map { |item| item.fetch("label") }
    end
  end

  describe "an administrator session (the existing password login)" do
    let(:app) { Rubotty::Dashboard::App.assemble(deps: deps, env: env) }

    before { post "/login", secret: secret }

    it "reaches an admin-only route (require_admin!)" do
      get "/communities/sample/platforms"
      expect(last_response.status).to eq(200)
    end

    it "reaches the accounts page (require_admin!)" do
      get "/accounts"
      expect(last_response.status).to eq(200)
    end

    it "reaches the Rooms redirect (require_admin!)" do
      get "/communities/sample/discovered"
      expect(last_response.status).to eq(302)
      expect(last_response.headers["Location"]).to end_with("/communities/sample/rooms?state=unroomed")
    end

    it "reaches the onboarding queue (require_admin!)" do
      get "/onboarding"
      expect(last_response.status).to eq(200)
    end

    it "reaches an authorize!-gated route" do
      get "/communities/sample/word-filter"
      expect(last_response.status).to eq(200)
    end

    it "reaches the cross-community index" do
      get "/"
      expect(last_response.status).to eq(200)
    end
  end

  describe "an operator-role stub (standing in for #161's not-yet-built session)" do
    # This subclass changes current_role and authenticated? only; deps still has to
    # be wired for real, since community! resolves the slug through it before any
    # guard runs. The operator is granted sample only.
    let(:app) do
      operator_deps = deps
      operator_community_id = community.id
      Class.new(Rubotty::Dashboard::App) do
        set :deps, operator_deps
        helpers do
          define_method(:authenticated?) { true }
          define_method(:current_role) do
            # An operator holds no write grants by default, so the ones these
            # examples exercise are handed over explicitly.
            Rubotty::Dashboard::Role.operator(
              community_ids: [operator_community_id],
              write_actions: %i[configure_word_filter configure_faq moderate_user configure_events
                                toggle_word_filter toggle_faq]
            )
          end
        end
      end
    end

    # Admin-only routes: denied regardless of community, matrix or not.

    it "is denied an admin-only route (require_admin!) inside its own community" do
      get "/communities/sample/platforms"
      expect(last_response.status).to eq(403)
    end

    # A pending space belongs to no community, so there is no scope an operator
    # could be granted it in.
    it "is denied the onboarding queue" do
      get "/onboarding"
      expect(last_response.status).to eq(403)
    end

    # An operator reads their own community's features freely, since each switch is
    # its own grant and the page itself gives nothing away.
    it "reads the features of a community it operates" do
      get "/communities/sample/features"
      expect(last_response.status).to eq(200)
    end

    it "cannot toggle a feature it has no grant for" do
      post "/communities/sample/features", selector: "all", feature: "anti_spam", op: "enable"
      expect(last_response.status).to eq(403)
    end

    it "cannot toggle a feature in a community it does not operate, even when granted" do
      deps.action_permissions.update({ "toggle_word_filter" => "1" })

      post "/communities/#{other_community.slug}/features", selector: "all",
                                                            feature: "word_filter", op: "enable"
      expect(last_response.status).to eq(403)
    end

    # An op outside enable/disable/set checks no grant at all, so it must be
    # refused outright rather than falling through unauthorised, even for an
    # operator holding both the toggle_ and configure_ grants for the feature.
    it "is denied a garbage feature operation regardless of its grants" do
      post "/communities/sample/features", selector: "all", feature: "word_filter", op: "reset"
      expect(last_response.status).to eq(403)
    end

    it "is denied creating a room without the manage_rooms grant" do
      post "/communities/sample/rooms", name: "general-2", platforms: ["telegram/tg"]
      expect(last_response.status).to eq(403)
    end

    it "is denied deleting a room without the manage_rooms grant" do
      room = models.room.where(community_id: community.id).first
      post "/communities/sample/rooms/#{room.id}/delete", confirm_name: room.room_key
      expect(last_response.status).to eq(403)
    end

    # #1559: manage_rooms is a SECTION_ACTIONS entry like every other
    # operator-grantable write, not an admin-only route, so an administrator
    # handing it out reaches these routes past authorize! the same as any
    # other grant, whether or not channel_management happens to be on.
    describe "with the manage_rooms grant" do
      let(:app) do
        operator_deps = deps
        operator_community_id = community.id
        Class.new(Rubotty::Dashboard::App) do
          set :deps, operator_deps
          helpers do
            define_method(:authenticated?) { true }
            define_method(:current_role) do
              Rubotty::Dashboard::Role.operator(
                community_ids: [operator_community_id], write_actions: %i[manage_rooms]
              )
            end
          end
        end
      end

      it "reaches room creation past authorize!, stopped only by channel_management being off" do
        post "/communities/sample/rooms", name: "general-2", platforms: ["telegram/tg"]
        expect(last_response.status).to eq(302)
        follow_redirect!
        expect(last_response.body).to include("Channel management is not enabled")
      end

      it "reaches room deletion past authorize!, stopped only by channel_management being off" do
        room = models.room.where(community_id: community.id).first
        post "/communities/sample/rooms/#{room.id}/delete", confirm_name: room.room_key
        expect(last_response.status).to eq(302)
        follow_redirect!
        expect(last_response.body).to include("Channel management is not enabled")
      end
    end

    # #1572: op=set writes an arbitrary config key, the heavier configure_
    # capability, so it must not run under the lighter toggle_ grant alone.
    describe "with only the toggle_ grant for a feature, not configure_" do
      let(:app) do
        operator_deps = deps
        operator_community_id = community.id
        Class.new(Rubotty::Dashboard::App) do
          set :deps, operator_deps
          helpers do
            define_method(:authenticated?) { true }
            define_method(:current_role) do
              Rubotty::Dashboard::Role.operator(
                community_ids: [operator_community_id], write_actions: %i[toggle_word_filter]
              )
            end
          end
        end
      end

      it "enables the feature through the generic route" do
        post "/communities/sample/features", selector: "all", feature: "word_filter", op: "enable"
        expect(last_response.status).to eq(302)
        expect(enabled?(feature_row(community, feature: "word_filter"))).to be(true)
      end

      it "is denied op=set, which spends the heavier configure_ grant" do
        post "/communities/sample/features", selector: "all", feature: "word_filter", op: "set",
                                            key: "mode", value: "off"
        expect(last_response.status).to eq(403)
        expect(feature_row(community, feature: "word_filter")).to be_nil
      end
    end

    # #1572, the other half of the split: enabling and disabling spend the
    # lighter toggle_ grant, not configure_, so a configure-only operator
    # (the config editor's own grant) cannot flip the switch the Set button
    # leaves alone.
    describe "with only the configure_ grant for a feature, not toggle_" do
      let(:app) do
        operator_deps = deps
        operator_community_id = community.id
        Class.new(Rubotty::Dashboard::App) do
          set :deps, operator_deps
          helpers do
            define_method(:authenticated?) { true }
            define_method(:current_role) do
              Rubotty::Dashboard::Role.operator(
                community_ids: [operator_community_id], write_actions: %i[configure_word_filter]
              )
            end
          end
        end
      end

      it "sets a config key through the generic route" do
        post "/communities/sample/features", selector: "all", feature: "word_filter", op: "set",
                                            key: "mode", value: "off"
        expect(last_response.status).to eq(302)
        expect(feature_row(community, feature: "word_filter").json_value(:config)).to include("mode" => "off")
      end

      it "is denied enabling the feature, which spends the lighter toggle_ grant" do
        post "/communities/sample/features", selector: "all", feature: "word_filter", op: "enable"
        expect(last_response.status).to eq(403)
        expect(feature_row(community, feature: "word_filter")).to be_nil
      end
    end

    it "is denied starting or stopping a community it operates" do
      post "/communities/sample/start"
      expect(last_response.status).to eq(403)
    end

    it "is denied guest invites, even inside its own community" do
      get "/communities/sample/guests"
      expect(last_response.status).to eq(403)
    end

    # Who else runs the community they run is theirs to see, and the form for
    # handing out that community's viewer lives on this page.
    it "reads the operators of a community it operates" do
      get "/communities/sample/operators"
      expect(last_response.status).to eq(200)
    end

    it "is denied the operators of a community it does not operate" do
      get "/communities/#{other_community.slug}/operators"
      expect(last_response.status).to eq(403)
    end

    # Each of those switches applies in every community, so the section carrying
    # them is not part of what opening one community's page shows.
    it "is not shown the deployment-wide permission switches on that page" do
      get "/communities/sample/operators"

      expect(last_response.body).not_to include("What operators may change")
      expect(last_response.body).not_to include("Save permissions")
    end

    # The deployment-wide viewer reads every OTHER community too, so nothing
    # about it is offered here.
    it "is offered no deployment-wide viewer control on that page" do
      get "/communities/sample/operators"

      expect(last_response.body).to include("Viewers of this community")
      expect(last_response.body).not_to include(%(action="/viewers"))
    end

    it "is denied the deployment-wide viewer grant itself" do
      post "/viewers", adapter: "telegram", handle: "mole"
      expect(last_response.status).to eq(403)
    end

    # The operator-editable permission switches decide who else gets to write, so
    # flipping one is administrator-only.
    it "is denied saving the operator-editable permission switches" do
      post "/operator-permissions", permissions: { "edit_faq" => "1" }
      expect(last_response.status).to eq(403)
    end

    # Mapping a channel is a topology change, so it sits behind require_admin!
    # rather than the operator-reachable authorize! matrix.
    it "is denied the discovered-channels list, even inside its own community" do
      get "/communities/sample/discovered"
      expect(last_response.status).to eq(403)
    end

    it "is denied mapping a discovered channel, even inside its own community" do
      post "/communities/sample/discovered/1/map", room_key: "general"
      expect(last_response.status).to eq(403)
    end

    # Accounts decide which credentials the whole deployment connects with and are
    # not scoped to a community at all, so there is no "own" to write.
    it "is denied the accounts page" do
      get "/accounts"
      expect(last_response.status).to eq(403)
    end

    it "is denied adding an account" do
      post "/accounts", adapter: "telegram", name: "tg", token_env: "TG_TOKEN"
      expect(last_response.status).to eq(403)
    end

    it "is denied removing an account" do
      post "/accounts/1/delete"
      expect(last_response.status).to eq(403)
    end

    # read-all: allowed against ANY community, including one never granted.

    it "reaches view_community for the community it operates" do
      get "/communities/sample"
      expect(last_response.status).to eq(200)
    end

    # A community this operator does not run shows the request-access page instead
    # of its contents, rather than a 403.
    it "records a request an administrator can act on, and says so on a second press" do
      post "/communities/#{other_community.slug}/request-access"
      expect(last_response.body).to include("Asked.")
      expect(last_response.body).to include('class="flash notice"')

      rows = models.operator_request.where(community_id: other_community.id, state: "pending").all
      expect(rows.length).to eq(1)
      expect(rows.first.adapter).to eq("web")

      post "/communities/#{other_community.slug}/request-access"
      expect(last_response.body).to include("already asked")
      expect(models.operator_request.where(community_id: other_community.id, state: "pending").count).to eq(1)
    end

    it "styles a failed request distinctly from a successful one, not identical grey" do
      allow(deps.models.operator_request).to receive(:create).and_raise(RuntimeError, "db unavailable")

      post "/communities/#{other_community.slug}/request-access"

      expect(last_response.body).to include("Something went wrong")
      expect(last_response.body).to include('class="flash error"')
      expect(last_response.body).not_to include('class="flash notice"')
    end

    it "offers request access, and no contents, for a community it does NOT operate" do
      get "/communities/#{other_community.slug}"

      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("Request access")
      expect(last_response.body).to include("not an operator of this community")
    end

    it "reaches the audit log, a cross-community read" do
      get "/audit"
      expect(last_response.status).to eq(200)
    end

    # edit_word_filter is write-own end to end, so even its GET is scoped to a
    # granted community.
    it "is denied even the read (GET) half of an edit_word_filter route for a community it does not operate" do
      get "/communities/#{other_community.slug}/word-filter"
      expect(last_response.status).to eq(403)
    end

    # An operator's own community list is where the /web-login link lands them, so
    # list_communities must be read-all or a freshly redeemed session 403s.
    it "reaches the cross-community index, a read-all action" do
      get "/"
      expect(last_response.status).to eq(200)
    end

    # view_analytics is read-all too: it only totals numbers an operator can already
    # see per community.
    it "reaches the analytics page, a read-all action" do
      get "/analytics"
      expect(last_response.status).to eq(200)
    end

    # write-own: allowed only against a granted community.

    it "performs a write behind an authorize!-gated route inside its own community" do
      post "/communities/sample/word-filter", selector: "all", op: "enable"
      expect(last_response.status).to eq(302)
      expect(enabled?(feature_row(community, feature: "word_filter"))).to be(true)
    end

    it "is denied a write behind an authorize!-gated route for a community it does not operate" do
      post "/communities/#{other_community.slug}/word-filter", selector: "all", op: "enable"
      expect(last_response.status).to eq(403)
      expect(enabled?(feature_row(other_community, feature: "word_filter"))).to be(false)
    end

    it "performs an FAQ write inside its own community" do
      post "/communities/sample/faq", selector: "all", op: "enable"
      expect(last_response.status).to eq(302)
      expect(enabled?(feature_row(community, feature: "faq"))).to be(true)
    end

    it "is denied an FAQ write for a community it does not operate" do
      post "/communities/#{other_community.slug}/faq", selector: "all", op: "enable"
      expect(last_response.status).to eq(403)
      expect(enabled?(feature_row(other_community, feature: "faq"))).to be(false)
    end

    # Nobody but an administrator may see a join link or a secret token
    # value, even where the route lets them onto the page: the view is a
    # second independent guard. This drives a real viewer session rather
    # than stubbing the guard open, since the guard being open is the point.

    describe "redaction, on the administration screens a viewer reads" do
      let(:app) do
        viewer_deps = deps
        Class.new(Rubotty::Dashboard::App) do
          set :deps, viewer_deps
          helpers do
            define_method(:authenticated?) { true }
            define_method(:current_role) { Rubotty::Dashboard::Role.viewer }
          end
        end
      end

      it "redacts a platform join link on the platforms screen" do
        deps.feature_controls.set(community: community, selector: "all", feature: "utility_commands",
                                  key: "platforms",
                                  value: JSON.generate([{ "platform" => "discord",
                                                           "label" => "Our Discord",
                                                           "url" => "https://discord.gg/super-secret-invite" }]))

        get "/communities/sample/platforms"

        expect(last_response.status).to eq(200)
        expect(last_response.body).not_to include("super-secret-invite")
        expect(last_response.body).to include("[redacted]")
      end

      it "redacts a freshly issued guest link on the guests screen" do
        get "/communities/sample/guests",
            {}, "rack.session" => { guest_link: "https://rubotty.example.org/g/super-secret-token",
                                     guest_nickname: "Reviewer" }

        expect(last_response.status).to eq(200)
        expect(last_response.body).not_to include("super-secret-token")
        expect(last_response.body).to include("[redacted]")
      end

      it "still shows an administrator the real values (the guard is role-based, not a blanket blank)" do
        admin_deps = deps
        admin_app = Class.new(Rubotty::Dashboard::App) do
          set :deps, admin_deps
          helpers do
            define_method(:authenticated?) { true }
            define_method(:current_role) { Rubotty::Dashboard::Role.administrator }
          end
        end
        deps.feature_controls.set(community: community, selector: "all", feature: "utility_commands",
                                  key: "platforms",
                                  value: JSON.generate([{ "platform" => "discord",
                                                           "label" => "Our Discord",
                                                           "url" => "https://discord.gg/super-secret-invite" }]))

        browser = Rack::Test::Session.new(Rack::MockSession.new(admin_app))
        browser.get "/communities/sample/platforms"

        expect(browser.last_response.status).to eq(200)
        expect(browser.last_response.body).to include("super-secret-invite")
      end
    end
  end

  # Fixture sessions carry an issued web-login id through Rack::Test's env, so
  # app.rb resolves real server-side grants rather than a stubbed role.
  describe "a real operator session (session[:role] and session[:operator_communities])" do
    it "rejects a legacy cookie that carries a role without a verifiable login" do
      get "/communities/sample", {}, "rack.session" => { role: "operator", operator_communities: [community.id] }

      expect(last_response.status).to eq(302)
      expect(last_response.location).to end_with("/login")
      expect(last_request.env["rack.session"][:role]).to be_nil
    end

    let(:app) { Rubotty::Dashboard::App.assemble(deps: deps, env: env) }
    let(:operator_session) { dashboard_session(role: "operator", operator_communities: [community.id]) }

    it "current_role resolves to an operator scoped to the session's community ids" do
      get "/communities/sample", {}, "rack.session" => operator_session
      expect(last_response.status).to eq(200)

      get "/communities/#{other_community.slug}", {}, "rack.session" => operator_session
      expect(last_response.status).to eq(200) # read-all: view_community works for any community

      post "/communities/#{other_community.slug}/word-filter", { selector: "all", op: "enable" },
           "rack.session" => operator_session
      expect(last_response.status).to eq(403) # write-own: not this operator's community

      # Being scoped to a community is not enough on its own: an operator starts with
      # no write grants at all until an administrator hands one over.
      post "/communities/sample/word-filter", { selector: "all", op: "enable" },
           "rack.session" => operator_session
      expect(last_response.status).to eq(403)
      expect(enabled?(feature_row(community, feature: "word_filter"))).to be(false)

      # Editing what the filter does is a different grant from switching it on.
      deps.action_permissions.update({ "configure_word_filter" => "1" })

      post "/communities/sample/word-filter", { selector: "all", op: "enable" },
           "rack.session" => operator_session
      expect(last_response.status).to eq(403)
      expect(enabled?(feature_row(community, feature: "word_filter"))).to be(false)

      deps.action_permissions.update({ "configure_word_filter" => "1", "toggle_word_filter" => "1" })

      post "/communities/sample/word-filter", { selector: "all", op: "enable" },
           "rack.session" => operator_session
      expect(last_response.status).to eq(302) # granted, and this IS their community
      expect(enabled?(feature_row(community, feature: "word_filter"))).to be(true)
    end

    # The path a freshly redeemed /web-login token takes. Root has to link the
    # community as well as return 200, or the operator lands with nowhere to go.
    it "loads the root and navigates from there into a community it operates" do
      get "/", {}, "rack.session" => operator_session
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("/communities/sample")

      get "/communities/sample", {}, "rack.session" => operator_session
      expect(last_response.status).to eq(200)
    end

    it "defaults to an empty community scope when the login claims no communities" do
      get "/communities/sample", {}, "rack.session" => dashboard_session(role: "operator")
      expect(last_response.status).to eq(200) # still read-all, no granted communities needed

      post "/communities/sample/word-filter", { selector: "all", op: "enable" },
           "rack.session" => dashboard_session(role: "operator")
      expect(last_response.status).to eq(403) # no granted communities at all
      expect(enabled?(feature_row(community, feature: "word_filter"))).to be(false)
    end

    it "refuses administrator pages to an unscoped signed-in operator" do
      get "/communities/sample/platforms", {}, "rack.session" => dashboard_session(role: "operator")
      expect(last_response.status).to eq(403)
    end

    # An administrator logging in over an operator's session inherited that
    # operator's community scope, since /login never cleared it.
    it "clears a prior operator session on an administrator login" do
      get "/communities/sample", {}, "rack.session" => operator_session
      post "/login", { secret: secret }, "rack.session" => operator_session

      get "/analytics"

      expect(last_request.env["rack.session"][:operator_communities]).to be_nil
      expect(last_request.env["rack.session"][:role]).to eq("administrator")
    end

    # Sinatra's `to` returns an absolute URL unchanged once it carries a scheme,
    # so an unchecked ?back= is a redirect off the admin origin.
    describe "the operator-permissions return path" do
      before { post "/login", secret: secret }

      it "refuses an absolute URL and lands on the dashboard root" do
        post "/operator-permissions", permissions: {}, back: "https://evil.example/steal"

        expect(last_response.status).to eq(302)
        expect(last_response.headers["Location"]).not_to include("evil.example")
        expect(last_response.headers["Location"]).to end_with("/")
      end

      it "refuses a scheme-relative URL, which is an absolute one in a browser" do
        post "/operator-permissions", permissions: {}, back: "//evil.example/steal"

        expect(last_response.headers["Location"]).not_to include("evil.example")
      end

      it "keeps a path on this dashboard" do
        post "/operator-permissions", permissions: {}, back: "/communities/sample/operators"

        expect(last_response.headers["Location"]).to end_with("/communities/sample/operators")
      end
    end

    # view_analytics is a scoped read, and a scoped read with no community named
    # passes, so the landing table has to narrow itself the way /audit does.
    describe "the cross-community analytics landing" do
      it "names no community to an operator scoped to nothing" do
        other_community # seeded

        get "/analytics", {}, "rack.session" => dashboard_session(role: "operator")

        expect(last_response.status).to eq(200)
        expect(last_response.body).not_to include("other-co")
        expect(last_response.body).not_to include("sample")
      end

      it "names only the communities the operator runs" do
        other_community

        get "/analytics", {}, "rack.session" => operator_session

        expect(last_response.status).to eq(200)
        expect(last_response.body).to include("sample")
        expect(last_response.body).not_to include("other-co")
      end

      it "still names every community to an administrator" do
        other_community
        post "/login", secret: secret

        get "/analytics"

        expect(last_response.body).to include("sample")
        expect(last_response.body).to include("other-co")
      end
    end

    # Operator management is on the always-deny list, so removing an operator is
    # administrator-only however the session is scoped.
    describe "removing an operator" do
      # A fresh person, since the seeded operators are all deployment-configured protected
      # and remove refuses those whoever asks.
      let(:target) do
        now = Time.now
        person = models.person.create(
          community_id: other_community.id, name: "removable-target", created_at: now, updated_at: now
        )
        models.operator.create(
          community_id: other_community.id, person_id: person.id,
          actions: '"all"', scope: '"all"', granted_at: now, granted_by: "spec"
        )
      end

      it "denies an operator scoped to nothing" do
        id = target.id

        post "/communities/#{other_community.slug}/operators/#{id}/delete", {},
             "rack.session" => dashboard_session(role: "operator")

        expect(last_response.status).to eq(403)
        expect(models.operator[id]).not_to be_nil
      end

      it "denies an operator scoped to a different community" do
        id = target.id

        post "/communities/#{other_community.slug}/operators/#{id}/delete", {},
             "rack.session" => operator_session

        expect(last_response.status).to eq(403)
        expect(models.operator[id]).not_to be_nil
      end

      it "allows an administrator" do
        id = target.id

        post "/login", secret: secret
        post "/communities/#{other_community.slug}/operators/#{id}/delete"

        expect(last_response.status).to eq(302)
        expect(models.operator[id]).to be_nil
      end
    end
  end

  # Viewer is a second dimension on the same Role: session[:viewer] sits
  # alongside session[:operator_communities], reads answer from the viewer
  # half, writes stay on the operator rules. Driven through a real session
  # rather than stubbed, since both halves must reach the same Role.
  describe "a viewer session (session[:viewer])" do
    let(:app) { Rubotty::Dashboard::App.assemble(deps: deps, env: env) }

    # A viewer who operates nothing: reads everywhere, writes nowhere.
    let(:viewer_session) { dashboard_session(role: "operator", viewer: true) }

    # The same person, also an operator of sample and of nothing else.
    let(:viewer_operator_session) do
      dashboard_session(role: "operator", viewer: true, operator_communities: [community.id])
    end

    # A grant an operator of sample can hold, so the overlap has something real
    # to be decided by. An operator starts with no write grants at all.
    def grant_word_filter!
      deps.action_permissions.update({ "toggle_word_filter" => "1", "configure_word_filter" => "1" })
    end

    describe "reading" do
      # The whole point of the dimension: oversight of the deployment, not of a
      # list somebody was named on. other-co is a community this session was
      # never given, and it reads the contents rather than the request-access
      # dead end an ordinary operator gets.
      it "reads every community, including one it was never named in" do
        other_community # seeded lazily, and the index has to have it to list it

        get "/", {}, "rack.session" => viewer_session
        expect(last_response.status).to eq(200)
        expect(last_response.body).to include("/communities/#{other_community.slug}")

        get "/communities/#{other_community.slug}", {}, "rack.session" => viewer_session
        expect(last_response.status).to eq(200)
        expect(last_response.body).not_to include("not an operator of this community")
      end

      %w[features word-filter faq moderation events people alerts webhooks redirections
         analytics audit].each do |section|
        it "reads #{section} in a community it does not operate" do
          get "/communities/#{other_community.slug}/#{section}", {}, "rack.session" => viewer_session
          expect(last_response.status).to eq(200)
        end
      end

      # The administration screens: an operator is refused these outright, and a
      # viewer is not, because seeing how a community is wired up is oversight.
      %w[platforms rooms scripts endpoints guests].each do |section|
        it "reads the #{section} screen, which an operator is refused" do
          get "/communities/#{other_community.slug}/#{section}", {}, "rack.session" => viewer_session
          expect(last_response.status).to eq(200)

          # The cookie from the request above would otherwise outrank the
          # session handed to the next one, and both would run as the viewer.
          clear_cookies
          get "/communities/#{other_community.slug}/#{section}", {}, "rack.session" => dashboard_session(role: "operator")
          expect(last_response.status).to eq(403)
        end
      end

      # Operators is the one screen of that shape an operator of the community
      # does reach, so the refusal to check is an operator of another one.
      it "reads the operators screen of a community it does not operate" do
        get "/communities/#{other_community.slug}/operators", {}, "rack.session" => viewer_session
        expect(last_response.status).to eq(200)

        clear_cookies
        get "/communities/#{other_community.slug}/operators", {},
            "rack.session" => dashboard_session(role: "operator", operator_communities: [community.id])
        expect(last_response.status).to eq(403)
      end

      it "reads the audit log, both the cross-community one and a community's own" do
        get "/audit", {}, "rack.session" => viewer_session
        expect(last_response.status).to eq(200)

        get "/communities/#{other_community.slug}/audit", {}, "rack.session" => viewer_session
        expect(last_response.status).to eq(200)
      end

      # Accounts and API keys list credential names and key labels, which is
      # reconnaissance rather than oversight. Operator login links are the same
      # family: a live way INTO this dashboard. Integrations and Viewers sit in
      # the same administrator-only block; Onboarding is guarded separately.
      %w[/accounts /api-keys /operator-tokens /integrations /viewers /administrators
         /onboarding].each do |path|
        it "is refused #{path}, which stays administrator-only" do
          get path, {}, "rack.session" => viewer_session
          expect(last_response.status).to eq(403)
        end
      end

      # The important test: the top bar offers none of the administrator-only
      # entries to a non-administrator, viewer or plain operator alike, while an
      # administrator sees every one of them.
      let(:admin_only_nav_labels) do
        ["Accounts", "API keys", "Operator logins", "Integrations", "Viewers", "Administrators",
         "Onboarding"]
      end

      it "is offered no navigation to the administrator-only pages, as a viewer" do
        get "/", {}, "rack.session" => viewer_session

        admin_only_nav_labels.each do |label|
          expect(last_response.body).not_to include(">#{label}<")
        end
      end

      it "is offered no navigation to the administrator-only pages, as a plain operator" do
        get "/", {}, "rack.session" => dashboard_session(role: "operator", operator_communities: [community.id])

        admin_only_nav_labels.each do |label|
          expect(shell_navigation_labels).not_to include(label)
        end
      end

      it "offers every administrator-only entry to an administrator" do
        post "/login", secret: secret

        get "/"

        admin_only_nav_labels.each do |label|
          expect(shell_navigation_labels).to include(label)
        end
      end
    end

    describe "writing" do
      # Asserted by POSTing the real write routes rather than by looking for a
      # button: the button is presentation, the refusal is the permission.
      it "is refused a feature toggle, a config edit and a moderation action" do
        grant_word_filter!

        post "/communities/sample/word-filter", { selector: "all", op: "enable" },
             "rack.session" => viewer_session
        expect(last_response.status).to eq(403)
        expect(enabled?(feature_row(community, feature: "word_filter"))).to be(false)

        post "/communities/sample/features", { selector: "all", feature: "word_filter", op: "enable" },
             "rack.session" => viewer_session
        expect(last_response.status).to eq(403)

        post "/communities/sample/moderation/mute", { adapter: "telegram", native_id: "1" },
             "rack.session" => viewer_session
        expect(last_response.status).to eq(403)
      end

      it "is refused the administrator writes on the screens it can now read" do
        post "/communities/sample/platforms", { selector: "all" }, "rack.session" => viewer_session
        expect(last_response.status).to eq(403)

        post "/communities/sample/rooms", { room_key: "new-room" }, "rack.session" => viewer_session
        expect(last_response.status).to eq(403)
        expect(models.room.where(community_id: community.id, room_key: "new-room").first).to be_nil

        post "/accounts", { adapter: "telegram", name: "tg", token_env: "TG_TOKEN" },
             "rack.session" => viewer_session
        expect(last_response.status).to eq(403)
      end

      # The property that matters: no write route may answer a viewer with
      # anything but a refusal, enumerated straight from Sinatra's route
      # table so a route added later is covered automatically. Exceptions:
      # request-access (records the ask) and operator-login (builds a session).
      describe "every POST route Sinatra knows about" do
        skipped = ["/login", "/logout", "/operator-login", "/communities/:slug/request-access"]

        Rubotty::Dashboard::App.routes.fetch("POST").map { |route| route[0].to_s }.uniq.each do |pattern|
          next if skipped.include?(pattern)

          it "refuses a viewer at #{pattern}" do
            path = pattern.gsub(":slug", community.slug.to_s)
                          .gsub(":feature", "word_filter")
                          .gsub(/:[a-z_]+/, "1")

            post path, {}, "rack.session" => viewer_session

            expect(last_response.status).to eq(403)
          end
        end
      end
    end

    # Viewer and operator on one person. Reads answer from the viewer half, so
    # they cover the deployment; writes answer from the operator half, so they
    # stop at the community they operate.
    describe "a viewer who also operates one community" do
      before { grant_word_filter! }

      it "writes in the community it operates" do
        post "/communities/sample/word-filter", { selector: "all", op: "enable" },
             "rack.session" => viewer_operator_session

        expect(last_response.status).to eq(302)
        expect(enabled?(feature_row(community, feature: "word_filter"))).to be(true)
      end

      it "is refused the same write in a community it only reads" do
        post "/communities/#{other_community.slug}/word-filter", { selector: "all", op: "enable" },
             "rack.session" => viewer_operator_session

        expect(last_response.status).to eq(403)
        expect(enabled?(feature_row(other_community, feature: "word_filter"))).to be(false)
      end

      # The overlap. Being a viewer of sample does not narrow what an operator of
      # sample may do, and being an operator of sample does not narrow what a viewer
      # reads elsewhere.
      it "keeps the operator answer on writes and the viewer answer on reads" do
        get "/communities/#{other_community.slug}/platforms", {}, "rack.session" => viewer_operator_session
        expect(last_response.status).to eq(200)

        post "/communities/sample/word-filter", { selector: "all", op: "enable" },
             "rack.session" => viewer_operator_session
        expect(last_response.status).to eq(302)

        # Still nothing an ordinary operator of sample could not do: the grants
        # are the operator's, and they end at sample.
        post "/communities/sample/platforms", { selector: "all" }, "rack.session" => viewer_operator_session
        expect(last_response.status).to eq(403)
      end
    end

    # The greyed-out button. A viewer should be able to see what they would be
    # changing if they had the rights here, so the control stays where it is and
    # goes flat rather than disappearing.
    describe "what the page draws" do
      before { grant_word_filter! }

      it "draws a flat, disabled save button for a viewer" do
        get "/communities/sample/word-filter", {}, "rack.session" => viewer_session

        expect(last_response.status).to eq(200)
        expect(last_response.body).to include(
          %(<button type="submit" class="secondary disabled" disabled ) +
          %(title="Read only: you cannot change this here." data-grant="configure_word_filter">Save</button>)
        )
      end

      it "draws the live button on the same page when the reader may act" do
        get "/communities/sample/word-filter", {}, "rack.session" => viewer_operator_session

        expect(last_response.status).to eq(200)
        expect(last_response.body).to include(%(<button type="submit" class="secondary" data-grant="configure_word_filter">Save</button>))
        expect(last_response.body).not_to include("Read only: you cannot change this here.")
      end
    end

    # Nothing but a literal true is viewer status, so a stray value left in a
    # session store cannot widen a plain operator into one.
    it "reads the viewer claim strictly, so a truthy value is not viewer status" do
      get "/communities/#{other_community.slug}/platforms", {}, "rack.session" => dashboard_session(role: "operator", viewer: "1")

      expect(last_response.status).to eq(403)
    end

    # A token carries the claim, but a live viewer grant has to back it when
    # it is redeemed.
    it "comes off the redeemed web-login token rather than anything the browser sends" do
      deps.dashboard_viewers.grant(adapter: "telegram", handle: "vera", native_id: "99", granted_by: "seeded")
      issued = deps.web_login.issue(
        identity_key: "telegram:main:99", operator: { adapter: "telegram", native_id: "99", username: "vera" },
        communities: [], viewer: true
      )

      post "/operator-login", token: issued.token

      expect(last_request.env["rack.session"][:viewer]).to be(true)

      get "/communities/#{other_community.slug}/platforms"
      expect(last_response.status).to eq(200)
    end

    it "leaves a plain operator token with no viewer status" do
      issued = deps.web_login.issue(
        identity_key: "telegram:main:98", operator: { adapter: "telegram", native_id: "98" },
        communities: [{ id: community.id, slug: community.slug, name: community.name }]
      )

      post "/operator-login", token: issued.token

      expect(last_request.env["rack.session"][:viewer]).to be(false)

      get "/communities/#{other_community.slug}/platforms"
      expect(last_response.status).to eq(403)
    end
  end
end
