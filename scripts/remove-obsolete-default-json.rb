# frozen_string_literal: true

require "rubygems"
require "rbconfig"
require "fileutils"
require "json"

# The locked, patched JSON gem replaces Ruby's older default copy. Remove the
# unused vulnerable implementation as well as its specification, so it cannot
# be loaded by an absolute stdlib path or redistributed as an active fallback.
minimum = Gem::Version.new("2.21.2")
replacement = Gem.loaded_specs.fetch("json")
unless RbConfig::CONFIG.fetch("prefix") == "/usr/local" &&
       replacement.full_gem_path.start_with?("/usr/local/bundle/") &&
       !replacement.default_gem? && replacement.version >= minimum
  abort "Default JSON cleanup requires the patched application bundle in the container layout"
end

specifications = Dir[File.join(Gem.default_specifications_dir, "json-*.gemspec")]
obsolete = specifications.select { |name| Gem::Specification.load(name).version < minimum }
if obsolete.empty?
  puts "The interpreter has no obsolete default JSON copy"
  exit
end
abort "Unexpected default JSON layout; refusing to remove shared library files" unless specifications.size == 1

roots = %w[rubylibdir archdir].map { |key| RbConfig::CONFIG.fetch(key) }.uniq
roots.each do |root|
  abort "Unexpected interpreter library path" unless root.start_with?("/usr/local/lib/ruby/")

  [File.join(root, "json.rb"), File.join(root, "json")].each do |target|
    abort "Refusing to remove the replacement JSON gem" if replacement.full_gem_path.start_with?(target + "/")

    FileUtils.rm_rf(target)
  end
end
obsolete.each do |name|
  version = Gem::Specification.load(name).version.to_s
  FileUtils.rm_f(name)
  FileUtils.rm_rf(File.join(Gem.default_dir, "gems", "json-#{version}"))
end
puts "Removed the obsolete default JSON implementation; the application uses JSON #{replacement.version}"
