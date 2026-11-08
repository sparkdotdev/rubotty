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
module ThemeTableCascadeSupport
end

RSpec.describe "every theme's table cascade" do
  ThemeTableCascadeSupport::CASCADE_ROOT = File.expand_path("../..", __dir__)
  ThemeTableCascadeSupport::SASS_BIN = File.join(ThemeTableCascadeSupport::CASCADE_ROOT, "node_modules", ".bin", "sass")

  # What Features draws in an actions cell: the toggle Button inside the Form
  # that carries its two hidden fields.
  ThemeTableCascadeSupport::CASCADE_ACTIONS_FORM = [
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
  ThemeTableCascadeSupport::CASCADE_ALIGNED_CELL = [
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
  ThemeTableCascadeSupport::CASCADE_NESTED_SECTION = [
    CssCascade.node("div", "rb-page", "rb-page--default"),
    CssCascade.node("div", "rb-page-body"),
    CssCascade.node("section", "rb-section", "rb-section--default"),
    CssCascade.node("div", "rb-section-body"),
    CssCascade.node("section", "rb-section", "rb-section--default")
  ].freeze

  ThemeTableCascadeSupport::CASCADE_DEFAULT_PAGE = [CssCascade.node("div", "rb-page", "rb-page--default")].freeze
  ThemeTableCascadeSupport::CASCADE_WIDE_PAGE = [CssCascade.node("div", "rb-page", "rb-page--wide")].freeze

  ThemeTableCascadeSupport::CASCADE_INLINE = %w[inline inline-flex inline-block inline-grid].freeze
  ThemeTableCascadeSupport::CASCADE_END_ALIGNED = %w[right end].freeze

  if File.executable?(ThemeTableCascadeSupport::SASS_BIN)
    # Compiled once for every theme, the same step build:theme-<name>-style
    # runs, since a cascade question can only be asked of the real output.
    before(:context) do
      FileUtils.mkdir_p(File.join(ThemeTableCascadeSupport::CASCADE_ROOT, "tmp"))
      @dir = Dir.mktmpdir("cascade-spec", File.join(ThemeTableCascadeSupport::CASCADE_ROOT, "tmp"))
      @sheets = Themes.names.to_h do |name|
        out = File.join(@dir, "#{name}.css")
        result, status = Open3.capture2e(ThemeTableCascadeSupport::SASS_BIN, "--no-source-map", "--style=expanded",
                                         Themes.stylesheet(name), out)
        raise "compiling #{name}'s stylesheet failed:\n#{result}" unless status.success?

        [name, CssCascade.themed(File.read(out, encoding: "UTF-8"))]
      end
    end

    after(:context) { FileUtils.remove_entry(@dir, true) }

    it "compiles a stylesheet for every theme, so nothing below passes on an empty set" do
      expect(@sheets.keys).to eq(Themes.names)
      expect(@sheets.values).to all(include(".rb-table"))
    end

    it "gives a table page a broader content cap than a reading page" do
      offenders = @sheets.filter_map do |name, css|
        default = CssCascade.value_of(css, "max-width", ThemeTableCascadeSupport::CASCADE_DEFAULT_PAGE)
        wide = CssCascade.value_of(css, "max-width", ThemeTableCascadeSupport::CASCADE_WIDE_PAGE)
        next nil if wide && wide != default

        "#{name}: default=#{default.inspect}, wide=#{wide.inspect}"
      end

      expect(offenders).to be_empty, offenders.join("\n")
    end

    # The bug: `.rb-form--edit { display: block }` weighs the same as
    # `.rb-table-actions > *` and sits later in the file, so it won, and every
    # actions cell on a twenty-nine row Features table stacked its pill,
    # toggle and Config link onto three lines.
    it "keeps a Form in an actions cell on the row's own line rather than a block of its own" do
      offenders = @sheets.filter_map do |name, css|
        display = CssCascade.value_of(css, "display", ThemeTableCascadeSupport::CASCADE_ACTIONS_FORM)
        next nil if ThemeTableCascadeSupport::CASCADE_INLINE.include?(display)

        "#{name}: a Form in an actions cell resolves to display: #{display.inspect}"
      end

      expect(offenders).to be_empty, offenders.join("\n")
    end

    # The bug: `.rb-align-end` is one class and `.rb-table td` is a class and a
    # type, so a column asked to align to the end drew left aligned.
    it "aligns a cell asked to align to the end to the end" do
      offenders = @sheets.filter_map do |name, css|
        align = CssCascade.value_of(css, "text-align", ThemeTableCascadeSupport::CASCADE_ALIGNED_CELL)
        next nil if ThemeTableCascadeSupport::CASCADE_END_ALIGNED.include?(align)

        "#{name}: a column declared align: \"end\" resolves to text-align: #{align.inspect}"
      end

      expect(offenders).to be_empty, offenders.join("\n")
    end

    it "draws every nested Section as a ruled subdivision rather than another card" do
      offenders = @sheets.filter_map do |name, css|
        rule = CssCascade.value_of(css, "border-left", ThemeTableCascadeSupport::CASCADE_NESTED_SECTION)
        next nil if rule&.match?(/solid.*var\(--(?:rb-accent-secondary|cm-rule-bright)\)/)

        "#{name}: a nested Section resolves to border-left: #{rule.inspect}"
      end

      expect(offenders).to be_empty, offenders.join("\n")
    end

    # Two more from the Series A review, held to this theme alone: where a
    # cell sits on its line, and whether a notice colours its own paragraph.
    # Both shipped green under text checks, since the declaration was there
    # and a later one of equal weight beat it.
    ThemeTableCascadeSupport::SERIES_A = "series-a"

    ThemeTableCascadeSupport::CASCADE_PLAIN_CELL = [
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
    ThemeTableCascadeSupport::CASCADE_DANGER_NOTICE = [
      CssCascade.node("div", "rb-page", "rb-page--default"),
      CssCascade.node("div", "rb-page-body"),
      CssCascade.node("section", "rb-section", "rb-section--default"),
      CssCascade.node("div", "rb-section-body"),
      CssCascade.node("p", "rb-notice", "rb-notice--danger")
    ].freeze

    it "sits a Series A cell on its line's middle, so a wrapped value and the button beside it line up" do
      align = CssCascade.value_of(@sheets.fetch(ThemeTableCascadeSupport::SERIES_A), "vertical-align", ThemeTableCascadeSupport::CASCADE_PLAIN_CELL)

      expect(align).to eq("middle")
    end

    it "leaves a Series A danger Notice's own text at reading ink rather than colouring the paragraph" do
      colour = CssCascade.value_of(@sheets.fetch(ThemeTableCascadeSupport::SERIES_A), "color", ThemeTableCascadeSupport::CASCADE_DANGER_NOTICE)

      expect(colour).to eq("var(--rb-content-text)")
    end

    # The rule the notice tone rides on instead, so the two examples together
    # say the tone moved rather than that it went away.
    it "carries a Series A danger Notice's tone on its own ground and rule" do
      css = @sheets.fetch(ThemeTableCascadeSupport::SERIES_A)

      expect(CssCascade.value_of(css, "border-left-color", ThemeTableCascadeSupport::CASCADE_DANGER_NOTICE)).to eq("var(--rb-danger)")
      expect(CssCascade.value_of(css, "background", ThemeTableCascadeSupport::CASCADE_DANGER_NOTICE)).to include("var(--rb-danger)")
    end

  else
    it "is skipped: dart-sass is not installed" do
      skip "run npm install at the project root, then re-run this file, to exercise the cascade checks"
    end
  end
end
