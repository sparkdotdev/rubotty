# frozen_string_literal: true

# Where the theme build's binaries live, and what the theme specs do when the
# toolchain is missing: fail by default instead of skip.
#
# Three spec files compile the real Civet and esbuild bundle, the whole check
# on what a theme draws. They used to skip themselves when the toolchain was
# absent, and a pending example reads as a pass in the summary: runs looked
# clean while the themed rendering was never exercised. RUBOTTY_THEME_TOOLCHAIN=optional
# is the same opt-out spec_helper.rb gives sandbox layers a machine lacks.
module DashboardToolchain
  ROOT = File.expand_path("../..", __dir__)
  SOURCES = File.join(ROOT, "assets", "themes")
  OPT_OUT = "RUBOTTY_THEME_TOOLCHAIN"

  # node comes off PATH; the other three are what npm ci writes into node_modules.
  PATHS = {
    "node" => `command -v node 2>/dev/null`.strip,
    "civet" => File.join(ROOT, "node_modules", ".bin", "civet"),
    "esbuild" => File.join(ROOT, "node_modules", ".bin", "esbuild"),
    "sass" => File.join(ROOT, "node_modules", ".bin", "sass")
  }.freeze

  def self.path(name) = PATHS.fetch(name)

  def self.installed?(name)
    found = PATHS.fetch(name)
    !found.empty? && File.executable?(found)
  end

  def self.absent(names) = names.reject { |name| installed?(name) }

  def self.ready?(names) = absent(names).empty?

  def self.opted_out? = ENV[OPT_OUT] == "optional"

  def self.sources_present? = File.directory?(SOURCES)

  # Called from the one example that stands in for a group which could not run.
  def self.report_gap!(example, names, checks)
    gap = "missing #{absent(names).join(', ')}, so #{checks} did not run."
    return example.skip("#{gap} There are no theme sources in this checkout to check.") unless sources_present?

    fix = "Run npm ci at the project root to install the theme build."
    return example.skip("#{gap} #{fix} #{OPT_OUT}=optional is set for this run.") if opted_out?

    raise RSpec::Expectations::ExpectationNotMetError, "#{gap} #{fix} Set #{OPT_OUT}=optional to skip instead."
  end
end
