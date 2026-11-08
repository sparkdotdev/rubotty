# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"
require "rack/test"
require "open3"
require "tmpdir"
require "fileutils"
require "set"

# What the un-themed stylesheet is allowed to decide once a theme is
# active, held over every theme at once. Checking a theme's compiled
# stylesheet alone misses a property the fallback above it already won,
# so these resolve the pair, in serve order, as a browser would.
RSpec.describe "the dashboard fallback stylesheet" do
  FALLBACK_ROOT = File.expand_path("../..", __dir__)
  FALLBACK_SASS = File.join(FALLBACK_ROOT, "node_modules", ".bin", "sass")

  # The primitive elements a screen is built out of, each as the chain the
  # shared emitters really draw (see assets/dashboard/runtime/primitives.civet and
  # lib/rubotty/dashboard/primitives.rb).
  FALLBACK_PAGE = [CssCascade.node("div", "rb-page", "rb-page--default")].freeze
  FALLBACK_BODY = (FALLBACK_PAGE + [CssCascade.node("div", "rb-page-body")]).freeze
  FALLBACK_SECTION = (FALLBACK_BODY + [CssCascade.node("section", "rb-section", "rb-section--default"),
                                       CssCascade.node("div", "rb-section-body")]).freeze
  FALLBACK_ROW = (FALLBACK_SECTION + [CssCascade.node("div", "rb-table-scroll"),
                                      CssCascade.node("table", "rb-table"),
                                      CssCascade.node("tbody"), CssCascade.node("tr")]).freeze
  FALLBACK_FIELD = (FALLBACK_SECTION + [CssCascade.node("form", "rb-form", "rb-form--edit"),
                                        CssCascade.node("div", "rb-form-fields"),
                                        CssCascade.node("div", "rb-field", "rb-field--medium")]).freeze
  FALLBACK_TAG = (FALLBACK_SECTION + [CssCascade.node("span", "rb-tag")]).freeze
  FALLBACK_TAG_RUN = (FALLBACK_SECTION + [CssCascade.node("span", "rb-tags")]).freeze

  FALLBACK_ELEMENTS = {
    "a page" => FALLBACK_PAGE,
    "a page title" => FALLBACK_PAGE + [CssCascade.node("h1", "rb-page-title")],
    "a section" => FALLBACK_BODY + [CssCascade.node("section", "rb-section", "rb-section--default")],
    "a table" => FALLBACK_SECTION + [CssCascade.node("div", "rb-table-scroll"),
                                     CssCascade.node("table", "rb-table")],
    "a header cell" => FALLBACK_ROW[0..-3] + [CssCascade.node("thead"), CssCascade.node("tr"),
                                              CssCascade.node("th")],
    "a table cell" => FALLBACK_ROW + [CssCascade.node("td")],
    "an actions cell" => FALLBACK_ROW + [CssCascade.node("td", "rb-table-actions")],
    "a text input" => FALLBACK_FIELD + [CssCascade.node("input", "rb-field-control",
                                                        attributes: { type: "text" })],
    "a password input" => FALLBACK_FIELD + [CssCascade.node("input", "rb-field-control",
                                                            attributes: { type: "password" })],
    "a select" => FALLBACK_FIELD + [CssCascade.node("select", "rb-field-control")],
    "a textarea" => FALLBACK_FIELD + [CssCascade.node("textarea", "rb-field-control")],
    "a field label" => FALLBACK_FIELD + [CssCascade.node("label", "rb-field-label")],
    "a primary button" => FALLBACK_SECTION + [CssCascade.node("button", "rb-button", "rb-button--primary")],
    # A control the reader may not press carries the disabled attribute as well
    # as the flat variant, which is what put it in reach of button:disabled.
    "a flat button" => FALLBACK_SECTION + [CssCascade.node("button", "rb-button", "rb-button--secondary",
                                                           "rb-button--flat",
                                                           attributes: { disabled: "" }, states: [:disabled])],
    "a good status" => FALLBACK_SECTION + [CssCascade.node("span", "rb-status", "rb-status--good")],
    "a stat" => FALLBACK_PAGE + [CssCascade.node("div", "rb-stats"), CssCascade.node("div", "rb-stat")],
    "an info notice" => FALLBACK_SECTION + [CssCascade.node("p", "rb-notice", "rb-notice--info")],
    "a code block" => FALLBACK_SECTION + [CssCascade.node("pre", "rb-code", "rb-code--block")],
    "a tag" => FALLBACK_SECTION + [CssCascade.node("span", "rb-tags"), CssCascade.node("span", "rb-tag")],
    "the shell's content well" => [CssCascade.node("main", "rb-shell-content")]
  }.freeze

  # The properties a theme owns. box-sizing and the [hidden] display are left
  # out on purpose: those two are the fallback's own resets and are meant to
  # reach everything on the page.
  FALLBACK_PROPERTIES = %w[background background-color color border border-color border-radius padding
                           margin font-size font-weight font-family text-align display box-shadow
                           max-width width min-height vertical-align line-height overflow overflow-x].freeze

  FALLBACK_TONES = %w[good bad warn neutral unknown].freeze

  # AA for text at this size. The tones that made the case resolved to exactly
  # 1.00, so the number this sits at matters less than that it is measured.
  FALLBACK_MINIMUM_CONTRAST = 4.5

  if File.executable?(FALLBACK_SASS)
    before(:context) do
      FileUtils.mkdir_p(File.join(FALLBACK_ROOT, "tmp"))
      @dir = Dir.mktmpdir("fallback-spec", File.join(FALLBACK_ROOT, "tmp"))
      assets = File.join(FALLBACK_ROOT, "assets/dashboard")
      @dashboard_css = compile(File.join(assets, "style.scss"))
      @combined_css = CssCascade.dashboard(@dashboard_css)
      @swatch = compile(File.join(assets, "swatches", "swatch-clay.scss"))
    end

    after(:context) { FileUtils.remove_entry(@dir, true) }

    def compile(source)
      out = File.join(@dir, "#{File.basename(source, '.scss')}.css")
      result, status = Open3.capture2e(FALLBACK_SASS, "--no-source-map", "--style=expanded",
                                       "--load-path=#{File.join(FALLBACK_ROOT, "assets/dashboard")}", source, out)
      raise "compiling #{source} failed:\n#{result}" unless status.success?

      File.read(out, encoding: "UTF-8")
    end

    # The fallback's rules, so a winner can be traced back to the stylesheet it
    # came from rather than to the layer it happens to sit in.
    def from_fallback?(rule, property)
      CssCascade.rules(CssCascade.fallback, property)
                .any? { |one| one.selector == rule.selector && one.value == rule.value }
    end

    def decided_by_fallback(property, chain)
      winner = CssCascade.candidates(@combined_css, property, chain)
                         .max_by { |rule| CssCascade.priority(rule) }
      winner if winner && from_fallback?(winner, property)
    end

    def definitions
      CssColour.definitions(@swatch)
               .merge(CssColour.definitions(CssCascade.fallback))
               .merge(CssColour.definitions(@dashboard_css))
    end

    it "compiles the dashboard styles and palette" do
      expect(@dashboard_css).to include(".rb-table")
      expect(@swatch).to include("--rb-surface")
    end

    it "reads the first selector without a byte order mark" do
      rules = CssCascade.rules(@dashboard_css, "display")

      expect(rules).not_to be_empty
      expect(rules.map(&:selector)).to all(satisfy { |selector| !selector.start_with?("\uFEFF") })
    end

    it "leaves primitive styling to the dashboard stylesheet" do
      offenders = FALLBACK_ELEMENTS.flat_map do |label, chain|
        FALLBACK_PROPERTIES.filter_map do |property|
          rule = decided_by_fallback(property, chain)
          "#{label} takes #{property} from #{rule.selector} (#{rule.value})" if rule
        end
      end

      expect(offenders).to be_empty, offenders.join("\n")
    end

    it "leaves the shell content width unconstrained" do
      width = CssCascade.value_of(@combined_css, "max-width", [CssCascade.node("main", "rb-shell-content")])

      expect(width).to be_nil
    end

    it "keeps a direct tag and a one-item tag run content-sized" do
      [FALLBACK_TAG, FALLBACK_TAG_RUN].each do |chain|
        expect(content_sized_in_section?(@combined_css, chain)).to be(true)
      end
    end

    it "styles a text input and a select consistently" do
      input = FALLBACK_ELEMENTS.fetch("a text input")
      select = FALLBACK_ELEMENTS.fetch("a select")
      %w[background border border-radius padding font-size color height].each do |property|
        expect(CssCascade.value_of(@combined_css, property, input))
          .to eq(CssCascade.value_of(@combined_css, property, select)), property
      end
    end

    it "keeps every status tone readable against its background" do
      colours = definitions
      FALLBACK_TONES.each do |tone|
        pill = FALLBACK_SECTION + [CssCascade.node("span", "rb-status", "rb-status--#{tone}")]
        ink = CssColour.resolve(CssCascade.value_of(@combined_css, "color", pill), colours)
        ratio = CssColour.contrast(ink, CssColour.ground(@combined_css, pill, colours))

        expect(ratio).to be >= FALLBACK_MINIMUM_CONTRAST
      end
    end

    it "defines every referenced custom property without a fallback value" do
      declared = declared_properties(@swatch) | declared_properties(CssCascade.fallback) |
                 declared_properties(CssCascade.fallback_vocabulary) | declared_properties(@dashboard_css)

      expect(referenced_properties(@dashboard_css) - declared).to be_empty
    end

    def declared_properties(css) = css.scan(/(--[\w-]+)\s*:/).flatten.to_set

    def content_sized_in_section?(sheet, chain)
      CssCascade.value_of(sheet, "align-self", chain) == "flex-start" ||
        CssCascade.value_of(sheet, "align-items", chain[0...-1]) == "flex-start"
    end

    # Only the bare form: var(--x, something) draws the something and is a
    # deliberate way to write a default.
    def referenced_properties(css) = css.scan(/var\(\s*(--[\w-]+)\s*\)/).flatten.to_set
  else
    it "is skipped: dart-sass is not installed" do
      skip "run npm install at the project root, then re-run this file, to exercise the cascade checks"
    end
  end

  describe "a dashboard page", :control_plane do
    include Rack::Test::Methods

    let(:seeded) { seeded_sample }
    let(:db) { seeded[0] }
    let(:secret) { "open-sesame" }
    let(:deps) { Rubotty::Dashboard::Deps.new(db: db, logger: Rubotty::Log.null) }
    let(:app) { Rubotty::Dashboard::App.assemble(deps: deps, env: env) }

    before { post "/login", secret: secret }

    let(:env) { { "DASHBOARD_SECRET" => secret } }

    it "serves the dashboard stylesheet over the fallback, with no old dashboard chrome" do
      get "/communities/sample"

      expect(last_response.body).to include(%(<link rel="stylesheet" href="/dashboard.css">))
      expect(last_response.body).to include("@layer rubotty-fallback")
      expect(last_response.body).not_to include("#rb-chrome > main")
    end

    # The panel is its theme over this floor, and most of the panel is still
    # the floor: a section no theme draws is answered with the server's own
    # markup, which has nothing at all to paint it when this is off the page.
    # A themed section needs it just as much, for the resets below.
    it "carries the floor on a section the theme draws and on one it does not" do
      ["/", "/communities/sample"].each do |path|
        get path

        expect(last_response.body).to include("@layer rubotty-fallback"), "#{path} carries no floor"
      end
    end

    # box-sizing and the page's own ground and gutter. No theme restates them,
    # so a page without this file draws every padded box at the wrong size
    # inside a white margin the shell cannot cover.
    it "carries the resets a theme leaves to it" do
      get "/"
      page = last_response.body

      expect(page).to include("@layer rubotty-fallback")
      expect(page).to include("* { box-sizing: border-box; }")
      expect(page).to match(/body \{ margin: 0;/)
      expect(page).to include("background: var(--fb-page)")
    end

    # The page is staged out of sight and revealed by whichever of the theme
    # and the floor gets to it, so the floor being back cannot bring the flash
    # back with it.
    it "still stages the server's own body rather than showing it on arrival" do
      get "/"

      expect(last_response.body).to include(%(<div id="rb-staging" hidden>))
      expect(last_response.body).not_to include(%(id="rb-chrome"))
    end
  end

  # No compiler needed: this is about the fallback on its own.
  describe "the mode it thinks the page is in" do
    let(:fallback) { CssCascade.fallback }

    # The theme layer's restore() sets data-theme on the root, and a fallback
    # that only knows the OS preference disagrees with it in both directions.
    it "answers to data-theme as well as to the OS preference" do
      expect(fallback).to include("@media (prefers-color-scheme: dark)")
      expect(fallback).to include('[data-theme="dark"]')
      expect(fallback).to include('[data-theme="light"]')
    end

    it "carries the same colour scheme into both branches, so native controls follow" do
      expect(fallback).to match(/\[data-theme="dark"\][^{]*\{[^}]*color-scheme: dark/m)
      expect(fallback).to match(/\[data-theme="light"\][^{]*\{[^}]*color-scheme: light/m)
    end

    # The dark override for a control used to be input, textarea, select while
    # the light one named the input's type, so the light one won and a reader
    # could not see what they typed.
    it "draws a control from one rule in every mode rather than a light rule and a darker one" do
      controls = CssCascade.rules(fallback, "background").select do |rule|
        rule.selector.match?(/\A(input|textarea|select)/)
      end

      expect(controls.map(&:value).uniq).to eq(["var(--fb-control)"])
    end

    it "keeps every mode's ink readable in a control" do
      definitions = CssColour.definitions(fallback)
      %w[--fb-control --fb-page --fb-surface].each do |ground|
        expect(CssColour.contrast(CssColour.resolve("var(--fb-control-ink)", definitions),
                                  CssColour.resolve("var(#{ground})", definitions)))
          .to be >= FALLBACK_MINIMUM_CONTRAST
      end
    end

    # The tone tints only followed the OS preference through the swatch layer;
    # with it off, .rb-notice--success and its kin fell back to one pastel with
    # no dark counterpart.
    it "gives every tone tint a dark counterpart that stays readable" do
      light = CssColour.definitions(fallback)
      dark = CssColour.definitions(fallback[/@media \(prefers-color-scheme: dark\).*?\n  \}/m, 0].to_s)

      %w[success warning danger].each do |tone|
        expect(dark["--fb-#{tone}"]).not_to eq(light["--fb-#{tone}"])
        expect(CssColour.contrast(CssColour.hex(dark.fetch("--fb-#{tone}-ink")),
                                  CssColour.hex(dark.fetch("--fb-#{tone}"))))
          .to be >= FALLBACK_MINIMUM_CONTRAST
      end
    end
  end
end
