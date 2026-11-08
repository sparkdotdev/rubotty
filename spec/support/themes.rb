# frozen_string_literal: true

require "json"

# Source locations used by the stylesheet and cascade checks.
module Themes
  module_function

  PROJECT = File.expand_path("../..", __dir__)
  ROOT = File.join(PROJECT, "assets", "themes")

  # assets/themes holds one directory per theme, plus the shared runtime every
  # theme composes from and the swatch sources, which are neither.
  SHARED = %w[runtime swatches].freeze

  # Series A keeps its presentation entry point beside its stylesheet.
  def names
    Dir.glob(File.join(ROOT, "*", "index.civet"))
       .map { |path| File.basename(File.dirname(path)) }
       .reject { |name| SHARED.include?(name) }
       .sort
  end

  def dir(name) = File.join(ROOT, name)

  def civet_sources(name) = Dir.glob(File.join(dir(name), "*.civet")).sort

  def stylesheet(name) = File.join(dir(name), "style.scss")

  def source(name) = File.read(File.join(dir(name), "index.civet"), encoding: "UTF-8")

  def style_artifact(name) = "theme-#{name}.css"

  def package_scripts
    JSON.parse(File.read(File.join(PROJECT, "package.json"), encoding: "UTF-8")).fetch("scripts")
  end

  # The runtime's own sources, compiled once and shared by every theme.
  def runtime_civet_sources = Dir.glob(File.join(ROOT, "runtime", "*.civet")).sort
end
