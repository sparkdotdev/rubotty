# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"
require "open3"
require "tmpdir"
require "fileutils"

# Two selector collisions, held over every theme instead of fixed
# piecemeal, since one stylesheet per theme over one set of class
# names is the premise here. Every selector involved reads correctly
# on its own, so these ask what the browser resolves, not what a selector says.
module DashboardTableCascadeSupport
end

RSpec.describe "the dashboard table cascade" do
  DashboardTableCascadeSupport::CASCADE_ROOT = File.expand_path("../..", __dir__)
  DashboardTableCascadeSupport::SASS_BIN = File.join(DashboardTableCascadeSupport::CASCADE_ROOT, "node_modules", ".bin", "sass")

  # What Features draws in an actions cell: the toggle Button inside the Form
  # that carries its two hidden fields.
  DashboardTableCascadeSupport::CASCADE_ACTIONS_FORM = [
    CssCascade.node("div", "rb-page", "rb-page--default"),
    CssCascade.node("div", "rb-page-body"),
    CssCascade.node("section", "rb-section", "rb-section--default"),
    CssCascade.node("div", "rb-section-body"),
    CssCascade.node("div", "rb-table-scroll"),
    CssCascade.node("table", "rb-table"),
    CssCascade.node("tbody"),
    CssCascade.node("tr"),
    CssCascade.node("td", "rb-table-actions"),
    CssCascade.node("form", "rb-form", "rb-form--edit")
  ].freeze

  # What Room games draws for a column declared align: "end".
  DashboardTableCascadeSupport::CASCADE_ALIGNED_CELL = [
    CssCascade.node("div", "rb-page", "rb-page--default"),
    CssCascade.node("div", "rb-page-body"),
    CssCascade.node("section", "rb-section", "rb-section--default"),
    CssCascade.node("div", "rb-section-body"),
    CssCascade.node("div", "rb-table-scroll"),
    CssCascade.node("table", "rb-table"),
    CssCascade.node("tbody"),
    CssCascade.node("tr"),
    CssCascade.node("td", "rb-align-end")
  ].freeze

  # A Section primitive inside another Section's body. The shared renderer
  # composes each nested level this way, including a collapsible Section below
  # a proposal or a titled group.
  DashboardTableCascadeSupport::CASCADE_NESTED_SECTION = [
    CssCascade.node("div", "rb-page", "rb-page--default"),
    CssCascade.node("div", "rb-page-body"),
    CssCascade.node("section", "rb-section", "rb-section--default"),
    CssCascade.node("div", "rb-section-body"),
    CssCascade.node("section", "rb-section", "rb-section--default")
  ].freeze

  DashboardTableCascadeSupport::CASCADE_DEFAULT_PAGE = [CssCascade.node("div", "rb-page", "rb-page--default")].freeze
  DashboardTableCascadeSupport::CASCADE_WIDE_PAGE = [CssCascade.node("div", "rb-page", "rb-page--wide")].freeze

  DashboardTableCascadeSupport::CASCADE_INLINE = %w[inline inline-flex inline-block inline-grid].freeze
  DashboardTableCascadeSupport::CASCADE_END_ALIGNED = %w[right end].freeze

  if File.executable?(DashboardTableCascadeSupport::SASS_BIN)
    before(:context) do
      source = File.join(DashboardTableCascadeSupport::CASCADE_ROOT, "assets/dashboard/style.scss")
      css, status = Open3.capture2e(DashboardTableCascadeSupport::SASS_BIN, "--no-source-map", source)
      raise "compiling #{source} failed:\n#{css}" unless status.success?

      @css = CssCascade.dashboard(css)
    end

    it "gives a table page a broader content cap than a reading page" do
      default = CssCascade.value_of(@css, "max-width", DashboardTableCascadeSupport::CASCADE_DEFAULT_PAGE)
      wide = CssCascade.value_of(@css, "max-width", DashboardTableCascadeSupport::CASCADE_WIDE_PAGE)

      expect(wide).to be_truthy
      expect(wide).not_to eq(default)
    end

    it "keeps a form in an actions cell on the row's own line" do
      display = CssCascade.value_of(@css, "display", DashboardTableCascadeSupport::CASCADE_ACTIONS_FORM)

      expect(DashboardTableCascadeSupport::CASCADE_INLINE).to include(display)
    end

    it "aligns a cell asked to align to the end to the end" do
      align = CssCascade.value_of(@css, "text-align", DashboardTableCascadeSupport::CASCADE_ALIGNED_CELL)

      expect(DashboardTableCascadeSupport::CASCADE_END_ALIGNED).to include(align)
    end

    it "draws a nested section as a ruled subdivision" do
      rule = CssCascade.value_of(@css, "border-left", DashboardTableCascadeSupport::CASCADE_NESTED_SECTION)

      expect(rule).to match(/solid.*var\(--rb-accent-secondary\)/)
    end

    DashboardTableCascadeSupport::CASCADE_PLAIN_CELL = [
      CssCascade.node("div", "rb-page", "rb-page--default"),
      CssCascade.node("div", "rb-page-body"),
      CssCascade.node("section", "rb-section", "rb-section--default"),
      CssCascade.node("div", "rb-section-body"),
      CssCascade.node("div", "rb-table-scroll"),
      CssCascade.node("table", "rb-table"),
      CssCascade.node("tbody"),
      CssCascade.node("tr"),
      CssCascade.node("td")
    ].freeze

    # A danger Notice, which is the tone that made the case: four lines of
    # explanation set entirely in red.
    DashboardTableCascadeSupport::CASCADE_DANGER_NOTICE = [
      CssCascade.node("div", "rb-page", "rb-page--default"),
      CssCascade.node("div", "rb-page-body"),
      CssCascade.node("section", "rb-section", "rb-section--default"),
      CssCascade.node("div", "rb-section-body"),
      CssCascade.node("p", "rb-notice", "rb-notice--danger")
    ].freeze

    it "sits a the dashboard cell on its line's middle, so a wrapped value and the button beside it line up" do
      align = CssCascade.value_of(@css, "vertical-align", DashboardTableCascadeSupport::CASCADE_PLAIN_CELL)

      expect(align).to eq("middle")
    end

    it "leaves a the dashboard danger Notice's own text at reading ink rather than colouring the paragraph" do
      colour = CssCascade.value_of(@css, "color", DashboardTableCascadeSupport::CASCADE_DANGER_NOTICE)

      expect(colour).to eq("var(--rb-content-text)")
    end

    # The rule the notice tone rides on instead, so the two examples together
    # say the tone moved rather than that it went away.
    it "carries a the dashboard danger Notice's tone on its own ground and rule" do
      css = @css

      expect(CssCascade.value_of(css, "border-left-color", DashboardTableCascadeSupport::CASCADE_DANGER_NOTICE)).to eq("var(--rb-danger)")
      expect(CssCascade.value_of(css, "background", DashboardTableCascadeSupport::CASCADE_DANGER_NOTICE)).to include("var(--rb-danger)")
    end

  else
    it "is skipped: dart-sass is not installed" do
      skip "run npm install at the project root, then re-run this file, to exercise the cascade checks"
    end
  end
end
