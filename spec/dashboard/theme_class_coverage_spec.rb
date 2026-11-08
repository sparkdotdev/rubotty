# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"
require "open3"

# Every theme is handed the same markup, and nothing noticed a theme
# that styled none of it: chart shipped with two of the four themes
# carrying no chart rule at all, every theme spec still green. A rule
# being present is no proof it wins visually; this is the floor under that.
module ThemeClassCoverageSupport
end

RSpec.describe "the class vocabulary every theme is handed" do
  ThemeClassCoverageSupport::COVERAGE_ROOT = File.expand_path("../..", __dir__)
  ThemeClassCoverageSupport::SASS_BIN = File.join(ThemeClassCoverageSupport::COVERAGE_ROOT, "node_modules", ".bin", "sass")

  # The classes a theme's own stylesheet owes a rule for: the identity set and
  # the layout set. Shell is not here because only a theme declaring a shell
  # draws one, and one of the four does.
  ThemeClassCoverageSupport::WANTED = (Rubotty::Dashboard::Primitives::Identity::CLASSES +
            Rubotty::Dashboard::Primitives::Layout::CLASSES).uniq.freeze

  ThemeClassCoverageSupport::THEMES = {
    "series-a" => "series-a"
  }.freeze

  # A class a theme has deliberately not styled, with the reason. Anything not
  # listed here is a gap rather than a decision, which is what makes adding a
  # line to this list the moment somebody has to think about it.
  ThemeClassCoverageSupport::UNSTYLED = {
    "series-a" => {
      "rb-code--block" => "no screen on this theme draws a code block yet"
    }
  }.freeze

  def compile(theme)
    source = File.join(ThemeClassCoverageSupport::COVERAGE_ROOT, "assets/themes/#{theme}/style.scss")
    out, status = Open3.capture2e(ThemeClassCoverageSupport::SASS_BIN, "--no-source-map", "--load-path=#{File.join(ThemeClassCoverageSupport::COVERAGE_ROOT, 'assets/themes')}", source)
    raise "compiling #{source} failed:\n#{out}" unless status.success?

    out.dup.force_encoding(Encoding::UTF_8)
  end

  # A whole class name rather than a prefix of one, or .rb-table would answer
  # for .rb-tab and a theme with no TabLinks rules would look covered.
  def selects?(css, name) = css.match?(/\.#{Regexp.escape(name)}(?![\w-])/)

  # A base class the emitters never draw on its own (.rb-form is always
  # .rb-form.rb-form--edit) is covered by a rule on any of its variants.
  def styled?(css, name)
    return true if selects?(css, name)

    ThemeClassCoverageSupport::WANTED.any? { |other| other.start_with?("#{name}--") && selects?(css, other) }
  end

  if File.executable?(ThemeClassCoverageSupport::SASS_BIN)
    ThemeClassCoverageSupport::THEMES.each_key do |theme|
      context "the #{theme} theme" do
        let(:css) { compile(theme) }

        it "carries a rule for every class it is handed" do
          silent = ThemeClassCoverageSupport::WANTED.reject { |name| styled?(css, name) } - ThemeClassCoverageSupport::UNSTYLED.fetch(theme).keys

          expect(silent).to be_empty,
                            "#{theme} styles none of: #{silent.join(', ')}. " \
                            "Style them, or record the reason in ThemeClassCoverageSupport::UNSTYLED."
        end

        # An entry that stops being true is a stale exemption, and a stale
        # exemption is how the next gap hides.
        it "has no exemption for a class it does style after all" do
          stale = ThemeClassCoverageSupport::UNSTYLED.fetch(theme).keys.select { |name| styled?(css, name) }

          expect(stale).to be_empty, "#{theme} styles #{stale.join(', ')}: drop the ThemeClassCoverageSupport::UNSTYLED entry"
        end

        # The chart classes are called out on their own because that is the set
        # this file was written for, and because two themes shipped without any
        # of them. Every one is named outright rather than covered by a variant.
        it "styles every chart class outright" do
          chart = ThemeClassCoverageSupport::WANTED.grep(/\Arb-chart/)
          silent = chart.reject { |name| selects?(css, name) }

          expect(chart.length).to eq(8)
          expect(silent).to be_empty, "#{theme} styles none of: #{silent.join(', ')}"
        end
      end
    end

    it "names an exemption for a class that is not in the vocabulary at all" do
      unknown = ThemeClassCoverageSupport::UNSTYLED.values.flat_map(&:keys).uniq - ThemeClassCoverageSupport::WANTED

      expect(unknown).to be_empty, "exempted class(es) no primitive draws: #{unknown.join(', ')}"
    end
  else
    it "is skipped: dart-sass is not installed" do
      skip "run npm install at the project root, then re-run this file"
    end
  end
end
