# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"
require "rack/test"
require "tmpdir"
require "fileutils"

# The wiring between the compiled theme runtime and the pages that
# carry it. The head script must be inline and above every stylesheet,
# since stamping data-theme any later shows a frame of the wrong theme.
# And the router's route table must name paths the internal surface answers.
RSpec.describe "the theme runtime's wiring", :control_plane do
  include Rack::Test::Methods

  RUNTIME_SOURCE = File.expand_path("../../assets/themes/runtime/index.civet", __dir__)
  SCREENS_SOURCE = File.expand_path("../../assets/themes/runtime/screens.civet", __dir__)
  APP_SOURCE = File.expand_path("../../lib/rubotty/dashboard/app.rb", __dir__)

  # Strips // line comments before a source is scanned, so a sentence of prose
  # naming a tag does not fail the check that no tag is written by hand.
  def without_line_comments(text)
    text.lines.map { |line| line.sub(%r{//.*}, "") }.join
  end

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:secret) { "open-sesame" }
  let(:env) { { "DASHBOARD_SECRET" => secret } }
  let(:deps) { Rubotty::Dashboard::Deps.new(db: db, logger: Rubotty::Log.null) }

  # A throwaway stand-in for what npm run build writes. The real output is
  # gitignored and CI never installs npm, so the page is exercised against a
  # file of known contents rather than against whatever happens to be on disk.
  let(:assets) { Dir.mktmpdir("rubotty-theme-assets") }
  let(:head_script) { %(document.documentElement.setAttribute("data-theme","dark");) }

  let(:app) do
    Rubotty::Dashboard::App.assemble(deps: deps, env: env).tap do |built|
      built.set :public_folder, assets
    end
  end

  WIDE_TABLE_PATHS = %w[
    /audit
    /communities/sample/audit
    /communities/sample/endpoints
    /communities/sample/scripts
    /communities/sample/redirections
    /communities/sample/webhooks
    /communities/sample/features
    /communities/sample/participation
    /communities/sample/alerts
    /communities/sample/files
    /operator-tokens
  ].freeze

  after { FileUtils.remove_entry(assets, true) }

  def admin!
    post "/login", secret: secret
  end

  describe "the blocking head script" do
    before do
      File.write(File.join(assets, "theme-head.js"), head_script)
      admin!
      get "/"
    end

    it "inlines the compiled script rather than fetching it" do
      expect(last_response.body).to include("<script>#{head_script}</script>")
    end

    # The whole reason it is inline: nothing on the page can paint before a
    # blocking script in the head has run, so the attribute is already there
    # when the first stylesheet is applied. A script placed after one of them
    # would be racing the paint instead.
    it "runs above every stylesheet on the page" do
      body = last_response.body
      stamp = body.index("<script>#{head_script}</script>")

      expect(stamp).not_to be_nil
      expect(body.index(%(<link rel="stylesheet"))).to be > stamp
    end

    it "ships the Clay palette, and the runtime itself" do
      expect(last_response.body).to include(%(<link rel="stylesheet" data-rb-swatch="clay"))
      expect(last_response.body).to include("/theme-runtime.js")
    end
  end

  # A fresh checkout has no built assets at all, which is the same arrangement
  # the script editor bundle has always had. It must read as a missing asset
  # rather than as a 500.
  it "renders the page with nothing to inline when the assets were never built" do
    expect(Rubotty::Dashboard::App.theme_head_script(assets)).to eq("")

    admin!
    get "/"

    expect(last_response.status).to eq(200)
  end

  it "opens every primary table screen in the broad outer frame" do
    admin!

    WIDE_TABLE_PATHS.each do |path|
      get path

      expect(last_response.status).to eq(200), path
      expect(last_response.body).to include("<div id=\"rb-content\" class=\"wide\">")
    end
  end

  describe "the router's route table" do
    # Every :param a page path might carry, substituted with a value the
    # seeded control plane actually answers for. Only :slug existed when this
    # table was one entry; :feature names bridge (a real feature_name with a
    # config_schema, so both the internal read and the page GET succeed)
    # rather than being left as the literal string ":feature".
    ROUTE_PARAMS = { ":slug" => "sample", ":feature" => "bridge", ":id" => "1",
                     ":room_key" => "general" }.freeze

    # :id has to name a real row for every template carrying one, and the
    # endpoint and script editors are the two the seed does not already
    # provide. The first row created in each table takes id 1, which is the
    # channel that template's own :id already means.
    before do
      community = deps.models.community.where(slug: "sample").first
      deps.script_endpoints.save(
        community: community, name: "weather", url: "https://api.example.com/forecast",
        http_method: "GET", timeout_seconds: 5, enabled: true, created_by: "administrator"
      )
      deps.scripts.save(
        community: community, name: "greeter", kind: "processor", source: 'return { action = "allow" }',
        trigger_type: "always", trigger_config: {}, created_by: "administrator"
      )
    end

    let(:routes) do
      source = File.read(RUNTIME_SOURCE)
      table = source[/ROUTES := \[(.*?)\n\]/m, 1].to_s
      table.scan(/template: "([^"]+)", source: "([^"]+)"/).map do |template, data|
        { template: template, data: data }
      end
    end

    def filled(path)
      ROUTE_PARAMS.reduce(path) { |filled_path, (param, value)| filled_path.gsub(param, value) }
    end

    it "reads a table rather than nothing, so the examples below mean something" do
      expect(routes.length).to be >= 2
    end

    it "names a data path the internal surface answers for every section" do
      admin!

      routes.each do |route|
        get "/internal#{filled(route[:data])}"
        expect(last_response.status).to eq(200), "/internal#{route[:data]} answered #{last_response.status}"
      end
    end

    # A themed link points at the page path, and a server-rendered section still
    # has to land somewhere real: the router hands anything it does not recognise
    # back to the browser, so a template naming a page the panel does not serve
    # would take somebody to a 404.
    it "names a page the panel serves for every section" do
      admin!

      routes.each do |route|
        get filled(route[:template])
        expect(last_response.status).to eq(200), "#{route[:template]} answered #{last_response.status}"
      end
    end
  end

  # The screens: one composition of the shared emitters per section,
  # hoisted out of the four themes that each carried their own copy.
  # Held to text checks like the rest of this file; the real compile
  # lives in themed_rendered_vocabulary_spec.rb.
  describe "the shared screens" do
    let(:source) { File.read(SCREENS_SOURCE, encoding: "UTF-8") }

    let(:themed_sections) do
      File.read(APP_SOURCE, encoding: "UTF-8").scan(/@themed_section = "([a-z_]+)"/).flatten.uniq
    end

    let(:drawn_sections) do
      source[/SCREENS := \{(.*?)\n\}/m, 1].to_s.scan(/^\s*([a-z_]+):/).flatten
    end

    it "exists as one module" do
      expect(File).to exist(SCREENS_SOURCE)
    end

    # The reason every theme used to carry every renderer: app.rb hands these
    # sections to the themed path, and one with nothing behind it is a page the
    # router takes over and then cannot fill. Nothing checked the two lists
    # against each other, and three themes shipped drawing five of them.
    it "draws every section app.rb hands to the themed path" do
      expect(themed_sections.length).to be >= 5
      expect(themed_sections - drawn_sections).to be_empty,
                                                  "themed section(s) with no renderer: #{(themed_sections - drawn_sections).join(', ')}"
    end

    # Composing the emitters is the whole job. Even a lone mutating button
    # travels through Form's action variant, so a screen writes no tags by
    # hand and each theme receives the same vocabulary.
    it "composes the shared emitters without hand-rolled tags" do
      expect(source).to match(%r{from "\./primitives\.civet"})

      tags = without_line_comments(source).scan(/<([a-zA-Z][a-zA-Z0-9]*)/).flatten.uniq.sort
      expect(tags).to be_empty, "hand-rolled tag(s): #{tags.join(', ')}"
    end

    # What the router reads to decide whether it may take a page over, so it
    # has to name what is really drawn rather than what was offered.
    it "declares the sections it draws off the renderers it actually has" do
      expect(source).to match(/sections := Object\.keys\(drawn\)\.filter/)
    end
  end

  # A themed section a theme cannot draw used to end one of two bad
  # ways: a fallback reloading the same address forever, or a guard
  # leaving the mount empty since teardown had cleared it. The router
  # now keeps off such a section entirely, leaving the rendered page.
  describe "a section the theme in hand does not draw" do
    let(:source) { File.read(RUNTIME_SOURCE, encoding: "UTF-8") }

    it "is checked before the router intercepts a click, starts, or navigates" do
      expect(source).to match(/function draws\(section/)
      expect(source.scan(/draws match\.section/).length).to be >= 3
    end

    it "never has the address already showing assigned back to it" do
      screens = File.read(SCREENS_SOURCE, encoding: "UTF-8")

      expect(screens).to include("unless window.location.pathname is target")
    end
  end
end
