# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"
require "open3"

module DashboardClassCoverageSupport
end

RSpec.describe "the dashboard stylesheet vocabulary" do
  DashboardClassCoverageSupport::COVERAGE_ROOT = File.expand_path("../..", __dir__)
  DashboardClassCoverageSupport::SASS_BIN = File.join(DashboardClassCoverageSupport::COVERAGE_ROOT, "node_modules", ".bin", "sass")

  # The classes a theme's own stylesheet owes a rule for: the identity set and
  # the layout set. Shell is not here because only a theme declaring a shell
  # draws one, and one of the four does.
  DashboardClassCoverageSupport::WANTED = (Rubotty::Dashboard::Primitives::Identity::CLASSES +
            Rubotty::Dashboard::Primitives::Layout::CLASSES).uniq.freeze

  DashboardClassCoverageSupport::UNSTYLED = %w[rb-code--block].freeze

  def compile
    source = File.join(DashboardClassCoverageSupport::COVERAGE_ROOT, "assets/dashboard/style.scss")
    out, status = Open3.capture2e(DashboardClassCoverageSupport::SASS_BIN, "--no-source-map", source)
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

    DashboardClassCoverageSupport::WANTED.any? { |other| other.start_with?("#{name}--") && selects?(css, other) }
  end

  if File.executable?(DashboardClassCoverageSupport::SASS_BIN)
    let(:css) { compile }

    it "styles the primitive classes used by the dashboard" do
      missing = DashboardClassCoverageSupport::WANTED.reject { |name| styled?(css, name) }

      expect(missing).to match_array(DashboardClassCoverageSupport::UNSTYLED)
    end

    it "styles every chart class outright" do
      chart = DashboardClassCoverageSupport::WANTED.grep(/\Arb-chart/)

      expect(chart.length).to eq(8)
      expect(chart.reject { |name| selects?(css, name) }).to be_empty
    end
  else
    it "is skipped: dart-sass is not installed" do
      skip "run npm install at the project root, then re-run this file"
    end
  end
end
