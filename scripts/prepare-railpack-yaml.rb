# frozen_string_literal: true

require "fileutils"

# Coolify checks out the pinned submodule before giving the source to Railpack.
# Published source can install the Git dependency from its public repository.
source = "vendor/yamlcamel-ruby"
exit unless File.directory?(source)

locks = File.read("Gemfile.lock").scan(
  %r{^GIT\n  remote: https://github\.com/[A-Za-z0-9-]+/yamlcamel-ruby\.git\n  revision: ([0-9a-f]{40})\n}
)
abort "Expected one pinned YAMLCamel Git source" unless locks.one?
revision = locks.first.first
cache = "vendor/cache/yamlcamel-ruby-#{revision[0, 12]}"
FileUtils.mkdir_p(cache)

# Only package inputs belong in the cache, with no Git metadata or test fixtures.
%w[lib licenses yamlcamel-ruby.gemspec LICENSE.MD README.md CONTRIBUTING.md LICENSE-THIRD-PARTY.txt].each do |name|
  FileUtils.cp_r(File.join(source, name), cache)
end
