# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"
require "rack/test"
require "json"

# the dashboard's own source files: the wiring that hands every ported
# section to the themed path, and a static proof that this theme draws
# no markup of its own any more. Held to text checks rather than a
# compile; the real compile lives in client_rendered_vocabulary_spec.rb.
RSpec.describe "the dashboard presentation's source", :control_plane do
  include Rack::Test::Methods

  ASSETS_ROOT = File.expand_path("../../assets/dashboard", __dir__)
  RUNTIME_ROOT = File.expand_path("../../assets/dashboard/runtime", __dir__)
  STYLE_SOURCE = File.join(ASSETS_ROOT, "style.scss")
  SHELL_STYLE_SOURCE = File.join(ASSETS_ROOT, "_shell.scss")
  CIVET_SOURCE = File.join(RUNTIME_ROOT, "index.civet")
  SHELL_CIVET_SOURCE = File.join(RUNTIME_ROOT, "chrome.civet")
  PRIMITIVES_SOURCE = File.join(RUNTIME_ROOT, "primitives.civet")

  # The classes the shared emitters (assets/dashboard/runtime/primitives.civet)
  # draw for every primitive the dashboard's ported screens use, matching
  # screens_spec.rb's SCREENS manifest. Copied rather than derived, since
  # Primitives::CLASSES holds all fifteen in one flat list with no
  # per-primitive grouping; checked below against that constant so a
  # rename there fails this instead of drifting quietly.
  PRESENTATION_CLASSES = %w[
    rb-page rb-page--default rb-page--wide rb-page-title rb-page-lede rb-page-body
    rb-section rb-section--default rb-section--plain rb-section--collapsible
    rb-section-title rb-section-body
    rb-notice rb-notice--info rb-notice--success rb-notice--warning rb-notice--danger
    rb-notice--empty rb-notice-mark
    rb-button rb-button--primary rb-button--secondary rb-button--destructive rb-button--small
    rb-button--flat rb-button-mark
    rb-stats rb-stat rb-stat-value rb-stat-label rb-stat-detail
    rb-table rb-table-scroll rb-table-actions rb-align-end
    rb-code rb-code--inline
    rb-form rb-form--edit rb-form--filter rb-form-fields rb-form-submit
    rb-field rb-field--short rb-field--medium rb-field--full rb-field-label
    rb-field-required rb-field-hint rb-field-control rb-field-options rb-field-option
    rb-status rb-status--good rb-status--bad rb-status--warn rb-status--neutral
    rb-status--unknown rb-status-mark
    rb-kv rb-kv--inline rb-kv--stacked rb-kv-key rb-kv-value
    rb-tag rb-tags
    rb-prose rb-prose-toc
  ].freeze

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:secret) { "open-sesame" }
  let(:deps) { Rubotty::Dashboard::Deps.new(db: db, logger: Rubotty::Log.null) }

  def admin!
    post "/login", secret: secret
  end

  # Strips SASS's // line comments and Civet's matching // comments before a
  # source is scanned, so a sentence of prose explaining the rule ("no hex, no
  # rgb()") does not fail the very check it is describing.
  def without_line_comments(text)
    text.lines.map { |line| line.sub(%r{//.*}, "") }.join
  end

  def color_literals(text)
    without_line_comments(text).scan(/#[0-9a-fA-F]{3,8}\b|\brgba?\(|\bhsla?\(|\btransparent\b/)
  end

  describe "wired into the ported routes" do
    let(:env) { { "DASHBOARD_SECRET" => secret } }
    let(:app) { Rubotty::Dashboard::App.assemble(deps: deps, env: env) }

    before { admin! }

    it "loads the dashboard runtime and stylesheet" do
      get "/communities/sample"

      expect(last_response.body).to include(%(<script src="/dashboard-runtime.js" defer></script>))
      expect(last_response.body).to include(%(<link rel="stylesheet" href="/dashboard.css">))
    end

    it "links its stylesheet after the floor, so it wins wherever the two meet" do
      get "/communities/sample"
      body = last_response.body

      expect(body.index("@layer rubotty-fallback"))
        .to be < body.index(%(<link rel="stylesheet" href="/dashboard.css">))
    end

    it "gives the dashboard a stable mount point around the view, outside the flash slots" do
      get "/communities/sample"

      expect(last_response.body).to match(%r{<div id="rb-staging" hidden>.*<div id="rb-view">.*</div>\s*</div>}m)
    end

    def expect_dashboard_boot(sections: true)
      expect(last_response.body).to include(%(<script src="/dashboard-boot.js" defer></script>))
      expect(last_response.body).to include(%(data-rb-client-section="#{sections}"))
      expect(last_response.body).not_to include("rubottyDashboard.start(")
    end

    it "starts the dashboard on Overview" do
      get "/communities/sample"

      expect_dashboard_boot
    end

    it "starts the dashboard on Endpoints too" do
      get "/communities/sample/endpoints"

      expect_dashboard_boot
    end

    it "starts the dashboard on Redirections too" do
      get "/communities/sample/redirections"

      expect_dashboard_boot
    end

    it "starts the dashboard on Scripts too" do
      get "/communities/sample/scripts"

      expect_dashboard_boot
    end

    it "starts the dashboard on Webhooks too" do
      get "/communities/sample/webhooks"

      expect_dashboard_boot
    end

    it "starts the dashboard on Features too" do
      get "/communities/sample/features"

      expect_dashboard_boot
    end

    it "starts the dashboard on a feature's config editor too" do
      get "/communities/sample/features/bridge/config"

      expect_dashboard_boot
    end

    it "starts the dashboard on Room games too" do
      get "/communities/sample/participation"

      expect_dashboard_boot
    end

    it "starts the dashboard on Alerts too" do
      get "/communities/sample/alerts"

      expect_dashboard_boot
    end

    it "starts the dashboard on Files too" do
      get "/communities/sample/files"

      expect_dashboard_boot
    end

    it "starts the dashboard on Backfill proposals too" do
      get "/backfill-proposals"

      expect_dashboard_boot
    end

    it "starts the dashboard on Documentation too" do
      get "/documentation"

      expect_dashboard_boot
    end

    # Signed out, which is the case that needs saying: the section read behind
    # this page is open for the same reason the page is, and a 401 there would
    # send the runtime into a reload loop rather than showing anybody the
    # terms they are being asked to agree to.
    it "starts the dashboard on the licence with no session at all" do
      offsession = Rack::Test::Session.new(Rack::MockSession.new(app))
      offsession.get "/licence"

      expect(offsession.last_response.status).to eq(200)
      expect(offsession.last_response.body).to include(%(data-rb-client-section="true"))
      expect(offsession.last_response.body).to include(%(<script src="/dashboard-boot.js" defer></script>))

      offsession.get "/internal/licence"
      expect(offsession.last_response.status).to eq(200)
    end

    # A community this session may not read: ViewData#overview answers
    # 404 for it, so there is no themed data to draw from and it stays
    # on the ERB renderer rather than looping on itself. Also the page
    # these two examples stand on, now that the panel proper is fully themed.
    let(:walled_off) do
      Rubotty::ControlPlane.models(db).community.create(
        slug: "walled-off", name: "Walled Off", status: "active",
        created_at: Time.now, updated_at: Time.now
      )
    end

    def get_walled_off
      get "/communities/#{walled_off.slug}", {}, "rack.session" => dashboard_session(role: "operator", operator_communities: [])
    end

    # The chrome is theme-owned, so it mounts everywhere. A theme that only
    # mounted on the sections it draws would swap the whole shell out from
    # under an operator on every link into one that is still ERB.
    it "starts the dashboard on a section it does not draw, for the chrome alone" do
      get_walled_off

      expect_dashboard_boot(sections: false)
    end

    it "keeps server-rendered content on the request-access branch of the same route" do
      get_walled_off

      expect(last_response.body).to include("Request access")
      expect(last_response.body).to include(%(data-rb-client-section="false"))
    end

    it "starts the dashboard with no opt-in setting" do
      default_app = Rubotty::Dashboard::App.assemble(deps: deps, env: { "DASHBOARD_SECRET" => secret })
      session = Rack::Test::Session.new(Rack::MockSession.new(default_app))
      session.post "/login", secret: secret
      session.get "/communities/sample"

      expect(session.last_response.body).to include("dashboard.css")
      expect(session.last_response.body).to include(%(<div id="rb-view">))
    end
  end

  describe "the stylesheet" do
    # Two files, one compiled sheet: the primitive rules and the chrome this
    # theme draws around them. Scanned together, so a bespoke rule cannot hide
    # in the half the checks do not read.
    let(:source) { [STYLE_SOURCE, SHELL_STYLE_SOURCE].map { |f| File.read(f, encoding: "UTF-8") }.join("\n") }

    it "exists as one file, compiled to one stylesheet" do
      expect(File).to exist(STYLE_SOURCE)
      expect(File).to exist(SHELL_STYLE_SOURCE)
      expect(File.read(STYLE_SOURCE, encoding: "UTF-8")).to include(%(@use "shell"))
    end

    it "carries no colour literal, only swatch custom properties" do
      expect(color_literals(source)).to be_empty
    end

    it "keeps the identity row in view while a long navigation scrolls on its own" do
      sidebar = source[/^\.rb-shell-side\s*\{\n(.*?)^\}/m, 1].to_s
      navigation = source[/^\.rb-shell-nav\s*\{\n(.*?)^\}/m, 1].to_s
      identity = source[/^\.rb-shell-identity\s*\{\n(.*?)^\}/m, 1].to_s

      expect(sidebar).to include("overflow: hidden")
      expect(navigation).to include("flex: 1 1 auto")
      expect(navigation).to include("min-height: 0")
      expect(navigation).to include("overflow-y: auto")
      expect(identity).to include("flex: 0 0 auto")
    end

    it "gives the sidebar the mockup's wider desktop measure" do
      wide_sidebar = source[/@media \(min-width: 1700px\) \{\n  \.rb-shell-side \{\n(.*?)  \}\n\}/m, 1]

      expect(source).to include("$sidebar-wide-width: 280px")
      expect(wide_sidebar).to include("flex: 0 0 $sidebar-wide-width")
      expect(wide_sidebar).to include("width: $sidebar-wide-width")
    end

    # Against the classes the dashboard's own chrome draws rather than the whole
    # shared vocabulary: the vocabulary now carries pieces built for a
    # structurally different shell (Command Centre's list pane) that the dashboard
    # has no use for, the same latitude it already gives rb-shell-side.
    it "styles every piece of chrome its own shell draws" do
      shell_source = File.read(SHELL_CIVET_SOURCE, encoding: "UTF-8")
      drawn = shell_source.scan(/rb-shell-[a-zA-Z0-9-]+/).uniq & Rubotty::Dashboard::Primitives::Shell::CLASSES
      undrawn = drawn.reject { |name| source.include?(".#{name}") }

      expect(undrawn).to be_empty, lambda {
        "shell class(es) with no rule in #{SHELL_STYLE_SOURCE}: #{undrawn.join(", ")}"
      }
    end

    it "styles a class for every primitive the ported screens declare" do
      PRESENTATION_CLASSES.each do |css_class|
        expect(source).to include(".#{css_class}"),
                          "#{STYLE_SOURCE} has no rule for .#{css_class}"
      end
    end

    # Looser than "exactly PRESENTATION_CLASSES and nothing else": checking
    # against the real fifteen-primitive vocabulary is the invariant
    # that holds forever, rather than one edited per screen ported. A
    # bespoke, non-primitive class is still caught; an unused primitive is not.
    it "draws no rb-* rule outside the real primitive vocabulary" do
      drawn = source.scan(/\.(rb-[a-zA-Z0-9-]+)/).flatten.uniq
      outside = drawn - Rubotty::Dashboard::Primitives::CLASSES

      expect(outside).to be_empty, lambda {
        "bespoke rb-* rule(s) outside Primitives::CLASSES: #{outside.join(", ")}"
      }
    end

    it "keeps PRESENTATION_CLASSES itself true to the primitive vocabulary" do
      expect(PRESENTATION_CLASSES - Rubotty::Dashboard::Primitives::CLASSES).to be_empty
    end
  end

  describe "the shared emitters" do
    let(:source) { File.read(PRIMITIVES_SOURCE, encoding: "UTF-8") }

    it "exist as one runtime module" do
      expect(File).to exist(PRIMITIVES_SOURCE)
    end

    it "escape every value they interpolate, the same five characters Primitives.escape covers" do
      expect(source).to match(/["']&["']:\s*["']&amp;["']/)
      expect(source).to match(/["']<["']:\s*["']&lt;["']/)
      expect(source).to match(/["']>["']:\s*["']&gt;["']/)
    end

    it "carry no colour literal either" do
      expect(color_literals(source)).to be_empty
    end

    it "are reached off the runtime's own exports, through the dashboard bundle" do
      expect(source).to match(/export\s*\{[^}]*\bpage\b/m)
      expect(source).to match(/export\s*\{[^}]*\bsection\b/m)
      expect(source).to match(/export\s*\{[^}]*\bnotice\b/m)
      expect(source).to match(/export\s*\{[^}]*\btable\b/m)
      expect(source).to match(/export\s*\{[^}]*\bform\b/m)
      expect(source).to match(/export\s*\{[^}]*\bfield\b/m)
      expect(source).to match(/export\s*\{[^}]*\bbutton\b/m)
      expect(source).to match(/export\s*\{[^}]*\bstate\b/m)
      expect(source).to match(/export\s*\{[^}]*\bkeyValues\b/m)
      expect(source).to match(/export\s*\{[^}]*\bstatRow\b/m)
      expect(source).to match(/export\s*\{[^}]*\bcode\b/m)
      expect(source).to match(/export\s*\{[^}]*\btabLinks\b/m)
    end
  end

  describe "dashboard navigation" do
    it "loads the fixed shell and screen renderers directly" do
      source = File.read(CIVET_SOURCE, encoding: "UTF-8")

      expect(source).to include(%(import { shell } from "./chrome.civet"))
      expect(source).to include(%(import { SCREENS } from "./screens.civet"))
    end
  end

  describe "the shell module" do
    let(:source) { File.read(SHELL_CIVET_SOURCE, encoding: "UTF-8") }

    it "exists as its own module" do
      expect(File).to exist(SHELL_CIVET_SOURCE)
    end

    it "carries no colour literal either" do
      expect(color_literals(source)).to be_empty
    end

    it "declares the content slot the runtime moves the page into" do
      expect(source).to match(/slots:\s*\{\s*content:/)
      expect(source).to include(Rubotty::Dashboard::Primitives::Shell::CONTENT_SLOT)
    end

    # The chrome is drawn from the shell document, so a section, a label or a
    # destination written down here would be this theme deciding navigation
    # that belongs to every theme at once.
    it "renders the catalogue rather than keeping sections of its own" do
      expect(source).to include("scope.groups")
      expect(source).to include("entry.items")

      hardcoded = Rubotty::Dashboard::Nav::COMMUNITY_GROUPS.flat_map(&:items)
                                                           .map(&:label)
                                                           .select { |label| source.include?(%("#{label}")) }

      expect(hardcoded).to be_empty, "section label(s) written into the theme: #{hardcoded.join(', ')}"
    end

    it "redraws the sidebar when a community switch changes its link destinations" do
      update = source[/function update\(context: any\): boolean\n(.*?)\nfunction updateBadge/m, 1]

      expect(update).to include("wantedPaths")
      expect(update).to include("drawnPaths")
      expect(update).to include("return false unless wantedPaths is drawnPaths")
    end

    it "escapes every value it interpolates" do
      expect(source).to include("escapeHtml")
    end
  end

  describe "the build" do
    let(:package) { JSON.parse(File.read(File.expand_path("../../package.json", __dir__))) }
    let(:scripts) { package.fetch("scripts") }

    it "compiles the stylesheet, the Civet module, and bundles the module, each its own step" do
      expect(scripts["build:dashboard-style"]).to include("assets/dashboard/style.scss")
    end

    it "builds the fixed styles and runtime from the top level build script" do
      %w[build:dashboard-style build:civet build:dashboard-runtime].each do |step|
        expect(scripts.fetch("build")).to include("npm run #{step}")
      end
    end

    it "compiles the shared runtime primitives alongside the rest of the runtime's Civet" do
      expect(scripts["build:civet"]).to include("assets/dashboard/runtime/*.civet")
    end
  end
end
