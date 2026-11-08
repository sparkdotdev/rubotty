# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"
require "rack/test"
require "yamlcamel"
require "json"
require "open3"
require "tmpdir"
require "fileutils"

# The shell contract: the chrome around a page, held to three things.
# Navigation is DATA, read from one catalogue (Rubotty::Dashboard::Nav)
# by every theme; themes are required, so the body stays hidden until
# the theme adopts it; and the chrome itself has one class vocabulary.
module ThemeShellSupport
end

RSpec.describe "the dashboard shell contract", :control_plane do
  include Rack::Test::Methods

  ThemeShellSupport::SHELL_ROOT = File.expand_path("../..", __dir__)
  ThemeShellSupport::SHELL_SUPPORT_DIR = File.expand_path("../support", __dir__)
  ThemeShellSupport::SHELL_TOOLS = %w[node civet esbuild].freeze
  ThemeShellSupport::SHELL_NODE = ThemeToolchain.path("node")
  ThemeShellSupport::SHELL_CIVET = ThemeToolchain.path("civet")
  ThemeShellSupport::SHELL_ESBUILD = ThemeToolchain.path("esbuild")

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:secret) { "open-sesame" }
  let(:env) { { "DASHBOARD_SECRET" => secret } }
  let(:deps) { Rubotty::Dashboard::Deps.new(db: db, logger: Rubotty::Log.null) }
  let(:app) { Rubotty::Dashboard::App.assemble(deps: deps, env: env) }
  let(:community) { models.community.where(slug: "sample").first }

  def body = YAMLCamel.load(last_response.body)

  def admin!
    post "/login", secret: secret
  end

  def entries(document)
    document.fetch("scopes").flat_map { |scope| scope.fetch("groups") }
            .flat_map { |group| group.fetch("items") }
  end

  describe "the catalogue" do
    let(:administrator) { Rubotty::Dashboard::Role.administrator }

    it "is written down once, as data, rather than as markup anywhere" do
      catalogue = Rubotty::Dashboard::Nav::COMMUNITY_GROUPS +
                  Rubotty::Dashboard::Nav::DEPLOYMENT_GROUPS

      expect(catalogue.length).to be >= 8
      expect(catalogue.flat_map(&:items)).to all(be_a(Rubotty::Dashboard::Nav::Item))
      expect(catalogue.flat_map(&:items).map(&:label)).to all(satisfy { |l| l.to_s.length.positive? })
    end

    it "gives every entry a destination the panel actually serves" do
      served = Rubotty::Dashboard::App.routes.fetch("GET").map { |pattern| pattern[0].to_s }
      community_paths = Rubotty::Dashboard::Nav.community_groups(community, role: administrator)
                                               .flat_map { |group| group["items"] }
                                               .map { |item| item["path"].sub("/sample", "/:slug") }
      deployment_paths = Rubotty::Dashboard::Nav.deployment_groups(role: administrator)
                                                .flat_map { |group| group["items"] }
                                                .map { |item| item["path"] }

      expect(community_paths + deployment_paths - served).to be_empty
    end

    # A link to a page its reader would be refused is worse than no link: it
    # reads as a way in, and it is a 403.
    it "offers an entry only to a role the route behind it would let in" do
      operator = Rubotty::Dashboard::Role.operator(community_ids: [community.id])
      as_admin = Rubotty::Dashboard::Nav.community_groups(community, role: administrator)
                                        .flat_map { |group| group["items"] }.map { |item| item["key"] }
      as_operator = Rubotty::Dashboard::Nav.community_groups(community, role: operator)
                                           .flat_map { |group| group["items"] }.map { |item| item["key"] }

      expect(as_admin).to include("files")
      expect(as_operator).not_to include("files")
      expect(as_operator).to include("overview")
      expect(as_admin - as_operator).not_to be_empty
    end

    it "marks a section current for its own sub-pages, and a landing entry only for itself" do
      groups = Rubotty::Dashboard::Nav.community_groups(
        community, role: administrator, path: "/communities/sample/endpoints/new"
      )
      current = groups.flat_map { |group| group["items"] }.select { |item| item["current"] }

      expect(current.map { |item| item["key"] }).to eq(["endpoints"])
    end

    it "puts the mount prefix on every path, so the nav resolves under one" do
      groups = Rubotty::Dashboard::Nav.deployment_groups(role: administrator, prefix: "/admin-panel")
      paths = groups.flat_map { |group| group["items"] }.map { |item| item["path"] }

      expect(paths).to all(start_with("/admin-panel"))
    end
  end

  describe "the shell document" do
    before { admin! }

    it "answers for a community page with both scopes, the community's first" do
      get "/internal/shell", path: "/communities/sample"

      expect(last_response.status).to eq(200)
      expect(body.fetch("scopes").map { |scope| scope["key"] }).to eq(%w[community deployment])
      expect(body.dig("scopes", 0, "current")).to be(true)
      expect(body.dig("scopes", 0, "slug")).to eq("sample")
    end

    it "answers for a deployment page with the deployment scope alone" do
      get "/internal/shell", path: "/accounts"

      expect(body.fetch("scopes").map { |scope| scope["key"] }).to eq(["deployment"])
      expect(entries(body).find { |item| item["key"] == "accounts" }["current"]).to be(true)
    end

    it "carries the breadcrumb, the switcher, the operator and the way out" do
      get "/internal/shell", path: "/communities/sample/endpoints"

      expect(body.fetch("crumbs").map { |crumb| crumb["label"] })
        .to eq(["Communities", community.name, "Script endpoints"])
      expect(body.fetch("crumbs").last["path"]).to be_nil
      expect(body.fetch("communities").map { |row| row["slug"] }).to include("sample")
      expect(body.dig("operator", "administrator")).to be(true)
      expect(body.fetch("logout_path")).to eq("/logout")
      expect(body.dig("search", "path")).to eq("/search.json")
    end

    it "attaches a count to the entries that declare one, and drops a zero" do
      deps.models.operator_request.create(
        community_id: community.id, adapter: "web", requester_native_id: "someone",
        requester_display: "someone", state: "pending", requested_at: Time.now
      )
      get "/internal/shell", path: "/communities/sample"
      operators = entries(body).find { |item| item["key"] == "operators" }

      expect(operators.fetch("badge")).to eq(1)
      expect(entries(body).find { |item| item["key"] == "alerts" }).not_to have_key("badge")
    end

    it "attaches an ordinary count to the entries that carry one, real zero included" do
      get "/internal/shell", path: "/communities/sample"
      before = entries(body).find { |item| item["key"] == "endpoints" }.fetch("count")

      deps.script_endpoints.save(
        community: community, name: "weather", url: "https://api.example.com/forecast",
        http_method: "GET", timeout_seconds: 5, enabled: true, created_by: "administrator"
      )
      get "/internal/shell", path: "/communities/sample"
      after = entries(body).find { |item| item["key"] == "endpoints" }.fetch("count")

      expect(after).to eq(before + 1)
      expect(entries(body).find { |item| item["key"] == "overview" }).not_to have_key("count")
    end

    it "carries the current community's own stats and the lifecycle grant" do
      get "/internal/shell", path: "/communities/sample"

      expect(body.dig("stats", "channels")).to be_a(Integer)
      expect(body.dig("stats", "platforms")).to be_a(Integer)
      expect(body.dig("may", "manage_lifecycle")).to be(true)
    end

    it "carries no stats and refuses the lifecycle grant outside a community" do
      get "/internal/shell", path: "/accounts"

      expect(body.fetch("stats")).to eq({})
      expect(body.dig("may", "manage_lifecycle")).to be(false)
    end

    it "attaches the failed webhook count and leaves quiet webhooks unbadged" do
      get "/internal/shell", path: "/communities/sample"
      expect(entries(body).find { |item| item["key"] == "webhooks" }).not_to have_key("badge")

      deps.webhooks.create(
        community_id: community.id, url: "https://example.invalid/hook",
        event_types: [Rubotty::ControlPlane::Webhooks::MESSAGE_RELAYED]
      )
      deps.webhooks.emit(
        community_id: community.id, event_type: Rubotty::ControlPlane::Webhooks::MESSAGE_RELAYED,
        room_key: "general", data: { "body" => "hi" }
      )
      delivery = deps.models.webhook_delivery.order(:id).last
      Rubotty::ControlPlane::Webhooks::MAX_ATTEMPTS.times do
        deps.webhooks.failed(delivery.refresh, error: "HTTP 500: down", response_status: 500)
      end

      get "/internal/shell", path: "/communities/sample"
      expect(entries(body).find { |item| item["key"] == "webhooks" }.fetch("badge")).to eq(1)
    end

    it "is answered for a page no theme draws, so the chrome survives the migration" do
      get "/internal/shell", path: "/communities/sample/word-filter"

      expect(last_response.status).to eq(200)
      expect(entries(body).map { |item| item["key"] }).to include("features")
    end

    # The same non-disclosure rule every other section follows: a community
    # outside this session's reach is chrome with no community in it, never a
    # name the reader may not read.
    it "says nothing about a community this session may not open" do
      other = models.community.create(slug: "walled-off", name: "Walled Off", status: "active",
                                      created_at: Time.now, updated_at: Time.now)
      get "/internal/shell", { path: "/communities/#{other.slug}" }, "rack.session" =>
        dashboard_session(role: "operator", operator_communities: [community.id])

      expect(last_response.status).to eq(200)
      expect(last_response.body).not_to include("Walled Off")
      expect(body.fetch("scopes").map { |scope| scope["key"] }).to eq(["deployment"])
    end

    it "narrows the switcher to the communities this session may open" do
      models.community.create(slug: "walled-off", name: "Walled Off", status: "active",
                              created_at: Time.now, updated_at: Time.now)
      get "/internal/shell", { path: "/communities/sample" }, "rack.session" =>
        dashboard_session(role: "operator", operator_communities: [community.id])

      expect(body.fetch("communities").map { |row| row["slug"] }).to eq(["sample"])
    end

    it "is available with no opt-in setting" do
      default_app = Rubotty::Dashboard::App.assemble(deps: deps, env: { "DASHBOARD_SECRET" => secret })
      session = Rack::Test::Session.new(Rack::MockSession.new(default_app))
      session.post "/login", secret: secret
      session.get "/internal/shell", path: "/"

      expect(session.last_response.status).to eq(200)
    end

    it "refuses a signed-out read in YAML rather than redirecting to a login form" do
      clear_cookies
      get "/internal/shell", path: "/"

      expect(last_response.status).to eq(401)
    end
  end

  describe "the required theme mount" do
    before { admin! }

    def shell_payload(page)
      JSON.parse(page[/<script id="rb-shell-data" type="application\/json">(.*?)<\/script>/m, 1])
    end

    it "keeps the server body staged until the theme owns the whole panel" do
      get "/communities/sample"
      page = last_response.body

      expect(page).to include(%(<div id="rb-shell" hidden></div>))
      expect(page).to include(%(<div id="rb-staging" hidden>))
      expect(page).to match(%r{<div id="rb-content">.*<div id="rb-view">}m)
      expect(page).not_to include(%(<div id="rb-chrome">))
      expect(page).not_to include(%(<header class="top">))
    end

    it "starts from the server's shell document without an inline boot script" do
      get "/communities/sample"
      page = last_response.body

      expect(page).to include("/theme-boot.js")
      expect(page).not_to include("rubottyTheme.start(")
      expect(shell_payload(page).dig("scopes", 0, "slug")).to eq("sample")
      expect(entries(shell_payload(page)).map { |item| item["key"] }).to include("endpoints", "rooms")
    end

    it "stamps the selected theme and section before the deferred boot runs" do
      get "/communities/sample"

      expect(last_response.body).to include(%(data-rb-theme="series-a"))
      expect(last_response.body).to include(%(data-rb-themed-section="true"))
    end

    it "serializes only the operator's permitted navigation" do
      operator = dashboard_session(role: "operator", operator_communities: [community.id])
      get "/communities/sample", {}, "rack.session" => operator

      names = entries(shell_payload(last_response.body)).map { |item| item["key"] }
      expect(names).not_to include("files", "rooms")
      expect(names).to include("features")
    end
  end

  # The Civet half, compiled and executed the same way a browser runs
  # it. Checked: the chrome renders FROM the document rather than a
  # list this theme keeps of its own, stays inside the shell vocabulary,
  # and a shell that cannot be drawn leaves the fallback alone.
  if ThemeToolchain.ready?(ThemeShellSupport::SHELL_TOOLS)
    describe "a theme's own chrome, compiled and driven" do
      def run!(*cmd)
        out, status = Open3.capture2e(*cmd)
        raise "#{cmd.join(' ')} failed:\n#{out}" unless status.success?

        out
      end

      # Compiled fresh under the project's own tmp/, the same two steps
      # package.json runs: esbuild resolves a bare import by walking up for a
      # node_modules, and a system temp directory has none of this project's
      # above it.
      def build
        @build ||= begin
          FileUtils.mkdir_p(File.join(ThemeShellSupport::SHELL_ROOT, "tmp"))
          dir = Dir.mktmpdir("shell-spec", File.join(ThemeShellSupport::SHELL_ROOT, "tmp"))
          %w[runtime series-a].each do |part|
            out = File.join(dir, part)
            FileUtils.mkdir_p(out)
            run!(ThemeShellSupport::SHELL_CIVET, "--js", "-c",
                 *Dir.glob(File.join(ThemeShellSupport::SHELL_ROOT, "assets/themes/#{part}/*.civet")), "-o", "#{out}/.js")
          end
          run!(ThemeShellSupport::SHELL_ESBUILD, File.join(dir, "runtime", "index.js"), "--bundle", "--format=iife",
               "--global-name=rubottyTheme", "--outfile=#{File.join(dir, "runtime.js")}")
          run!(ThemeShellSupport::SHELL_ESBUILD, File.join(dir, "runtime", "boot.js"), "--bundle", "--format=iife",
               "--outfile=#{File.join(dir, "boot.js")}")
          { dir: dir, runtime: File.join(dir, "runtime.js"),
            boot: File.join(dir, "boot.js") }
        end
      end

      after { FileUtils.remove_entry(@build[:dir], true) if @build }

      let(:document) do
        Rubotty::Dashboard::ViewData
          .new(deps: deps, role: Rubotty::Dashboard::Role.administrator)
          .shell(path: "/communities/sample")
          .merge("brand" => { "product" => "rubotty", "version" => Rubotty::VERSION,
                              "commit" => "a3f9c2e", "drift" => ["a deploy that never went out"] })
      end

      let(:result) do
        nav_path = File.join(build[:dir], "nav.json")
        File.write(nav_path, JSON.generate(document))
        JSON.parse(run!(ThemeShellSupport::SHELL_NODE, File.join(ThemeShellSupport::SHELL_SUPPORT_DIR, "theme_shell_checks.js"),
                        build[:runtime], nav_path))
      end

      def classes_in(html) = html.scan(/\bclass="([^"]*)"/).flatten.flat_map(&:split).uniq

      it "runs a real battery, so nothing here passes vacuously" do
        expect(result.fetch("checks").length).to be >= 15
        expect(result.fetch("html").length).to be > 2000
      end

      it "holds every one of them" do
        failed = result.fetch("checks").reject { |check| check["ok"] }

        expect(failed).to be_empty, lambda {
          failed.map { |check| "#{check['name']}: #{check['detail']}" }.join("\n")
        }
      end

      # The reported case: three crumbs, and the tail slice that drew the last
      # two took the only link back out of the community with it.
      it "keeps the way back to the deployment index on a route nested inside a community" do
        deep = Rubotty::Dashboard::ViewData
               .new(deps: deps, role: Rubotty::Dashboard::Role.administrator)
               .shell(path: "/communities/sample/features/bridge/config")
        nav_path = File.join(build[:dir], "deep-nav.json")
        File.write(nav_path, JSON.generate(deep))
        drawn = JSON.parse(run!(ThemeShellSupport::SHELL_NODE, File.join(ThemeShellSupport::SHELL_SUPPORT_DIR, "theme_shell_checks.js"),
                                build[:runtime], nav_path)).fetch("html")

        expect(deep.fetch("crumbs").map { |crumb| crumb["label"] })
          .to eq(["Communities", community.name, "Features"])
        expect(drawn).to include(%(<a class="rb-shell-crumb" href="/">Communities</a>))
        expect(drawn).to include(%(<a class="rb-shell-crumb" href="/communities/sample">))
      end

      it "draws chrome inside the shell vocabulary and nothing else" do
        bespoke = classes_in(result.fetch("html")) - Rubotty::Dashboard::Primitives::CLASSES

        expect(bespoke).to be_empty, "class(es) outside Primitives::CLASSES: #{bespoke.join(', ')}"
      end

      it "has a rule in the theme's stylesheet for every piece of chrome it draws" do
        sheet = File.read(File.expand_path("../../assets/themes/series-a/_shell.scss", __dir__),
                          encoding: "UTF-8")
        unstyled = classes_in(result.fetch("html")).reject { |name| sheet.include?(".#{name}") }

        expect(unstyled).to be_empty, "chrome drawn with no rule: #{unstyled.join(', ')}"
      end

      # The other half of staging the body, driven through the real compiled
      # boot script: a theme that mounts leaves it hidden and empty, and every
      # way of failing to mount puts it back on screen. A panel that hides
      # itself waiting for chrome that never comes is a blank browser window.
      describe "the page the theme was going to take over" do
        let(:booted) do
          nav_path = File.join(build[:dir], "boot-nav.json")
          File.write(nav_path, JSON.generate(document))
          JSON.parse(run!(ThemeShellSupport::SHELL_NODE, File.join(ThemeShellSupport::SHELL_SUPPORT_DIR, "theme_boot_checks.js"),
                          build[:runtime], build[:boot], nav_path))
                    .to_h { |one| [one.fetch("case"), one] }
        end

        it "is moved into the theme's own slot, and stays staged and hidden, when the chrome mounts" do
          mounted = booted.fetch("the theme mounts its chrome")

          expect(mounted.fetch("intoDeclaredSlot")).to be(true), mounted.fetch("adoptedBy").inspect
          expect(mounted.fetch("revealed")).to be(false)
        end

        it "is revealed by every way a theme has of not taking it over" do
          failures = booted.reject do |name, one|
            name == "the theme mounts its chrome" || one.key?("flashScrolledWith")
          end

          expect(failures.length).to eq(3)
          expect(failures.values.map { |one| one.fetch("adoptedBy") }).to all(be_nil)
          expect(failures.reject { |_, one| one.fetch("revealed") }.keys)
            .to be_empty, "left the panel hidden with nothing drawn"
        end

        # A save on a phone looked like nothing happened: the notice was drawn
        # under panes stacked above the content, out of sight.
        it "scrolls the notice a save redirected with into view when the layout left it off screen" do
          expect(booted.fetch("a notice the layout left below the fold").fetch("flashScrolledWith"))
            .to eq("block" => "center")
        end

        it "leaves the page where it is when the notice is already on screen" do
          expect(booted.fetch("a notice already on screen").fetch("flashScrolledWith")).to be_nil
        end
      end
    end
  else
    it "has no toolchain installed to render the shell with" do
      ThemeToolchain.report_gap!(self, ThemeShellSupport::SHELL_TOOLS, "the shell render checks")
    end
  end
end
