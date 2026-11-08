# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"

# Chart styling has shipped twice as code that could never run: a
# renderer picking its own colours and the stylesheet arguing with it
# afterwards. These read the sources directly, which is crude but the
# only check that catches a colour written down by hand.
RSpec.describe "the chart layer" do
  CHART_LAYOUT = File.expand_path("../../lib/rubotty/dashboard/views/layout.erb", __dir__)
  CHART_RUNTIME = File.expand_path("../../assets/themes/runtime/chart.civet", __dir__)
  CHART_ENGINE = File.expand_path("../../assets/themes/runtime/chart-renderer.civet", __dir__)
  CHART_BOOT = File.expand_path("../../assets/themes/runtime/chart-boot.civet", __dir__)

  # A hex colour, or an rgb()/hsl() call. Both are how a colour gets written
  # down instead of being asked for by role.
  COLOUR_LITERAL = /#\h{3,8}\b|\b(?:rgb|hsl)a?\(/

  let(:layout) { File.read(CHART_LAYOUT, encoding: Encoding::UTF_8) }
  let(:engine) { File.read(CHART_ENGINE, encoding: Encoding::UTF_8) }

  describe "the standard renderer's colours" do
    # Series colours come from the Clay palette.
    it "writes no colour literal of its own" do
      [CHART_RUNTIME, CHART_ENGINE, CHART_BOOT].each do |path|
        source = File.read(path, encoding: Encoding::UTF_8)
        offenders = source.lines.grep(COLOUR_LITERAL)

        expect(offenders).to be_empty, "#{path} writes a colour literal: #{offenders.join.strip}"
      end
    end

    it "takes every series colour from the swatch's own series role" do
      expect(engine).to include("var(--rb-series-")
      expect(engine).to match(/--rb-series-\$\{|--rb-series-#\{|series-\$\{/)
    end

    # The axis and the guides are colours too, and both are lines rather than
    # text: at muted-text weight the axis asserted as loudly as the numbers on
    # it.
    it "draws the axis and the guides in a line role" do
      expect(engine).to include("var(--rb-border)")
      expect(engine).not_to include("stroke:var(--rb-muted-text)")
    end

    # Text in SVG defaults to black rather than to the page's colour, so the
    # drawing carries currentColor as the floor under every string in it and a
    # theme's own class rule wins over that inherited value.
    it "leaves text colour to the stylesheets, with currentColor underneath" do
      expect(engine).to include("style=\"fill:currentColor\"")
      expect(engine).not_to match(/<text[^>]*fill:/)
    end

    # A seventh series has to wrap rather than name --rb-series-7, which no
    # swatch owes a value for.
    it "holds the series palette to the length the swatch contract promises" do
      declared = engine[/SERIES_LENGTH := (\d+)/, 1].to_i

      expect(declared).to eq(Swatches.series_length)
    end
  end

  describe "the layout" do
    # The dark-mode block used to carry three rules that existed only to argue
    # with a library about colours it had already written inline.
    it "carries no chart colour rules of its own any more" do
      expect(layout).not_to include("rough-chart")
      expect(layout).not_to match(/barFill|barStroke|darkCharts/)
    end

    # The figure has to be given a width to draw into; the drawing keeps its own
    # proportions from the viewBox.
    it "sizes the drawing from the class rather than from inside the engine" do
      expect(CssCascade.fallback_vocabulary).to match(/\.rb-chart-svg \{[^}]*width: 100%/)
      expect(engine).not_to include("width:100%")
    end
  end
end
