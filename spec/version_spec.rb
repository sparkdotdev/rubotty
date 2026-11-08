# frozen_string_literal: true

require "spec_helper"
require "rubotty"
require "rubotty/api"
require "tmpdir"
require "open3"
require "fileutils"

# The deploy image bakes lib/rubotty/resolved_version.txt at build time (see
# scripts/resolve-version.sh); this checkout never has one, so
# Rubotty::VERSION is always the fallback in this run.
RSpec.describe Rubotty::VersionResolution do
  it "reads a baked version file when one is present" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "resolved_version.txt")
      File.write(path, "0.8.0+12-gabc1234\n")

      expect(described_class.resolve(path)).to eq("0.8.0+12-gabc1234")
    end
  end

  it "ignores a present but empty file rather than reporting a blank version" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "resolved_version.txt")
      File.write(path, "\n")

      expect(described_class.resolve(path)).to eq(described_class::FALLBACK)
    end
  end

  it "falls back plainly when no file was baked in" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "resolved_version.txt")

      expect(described_class.resolve(path)).to eq(described_class::FALLBACK)
    end
  end

  # The whole point of the fallback: it must not read as a specific release
  # nobody cut, the failure mode the previous per-PR patch bump produced.
  it "marks the fallback as unresolved rather than a real patch number" do
    expect(described_class::FALLBACK).to match(/unreleased|unresolved|unknown/)
  end

  # spec/api/openapi_drift_spec.rb compares Rubotty::VERSION's feature line
  # (major.minor) against the published spec, and this is what it reads in any
  # run outside a railpack build. If a release moves the feature line, this and
  # the published spec have to move together.
  it "keeps the fallback's feature line matching this checkout's published API spec", :api_spec_document do
    document = YAMLCamel.load(File.read(ApiSpecDocument::PATH))
    feature_line = ->(version) { version.to_s.split(".").first(2).join(".") }

    expect(feature_line[described_class::FALLBACK]).to eq(feature_line[document.dig("info", "version")])
  end
end

RSpec.describe "Rubotty::VERSION" do
  it "is whatever this checkout's version resolution produces" do
    expect(Rubotty::VERSION).to eq(Rubotty::VersionResolution.resolve)
  end
end

RSpec.describe "scripts/resolve-version.sh" do
  it "records Coolify's source commit without a Git checkout or a remote fetch" do
    Dir.mktmpdir do |dir|
      scripts = File.join(dir, "scripts")
      lib = File.join(dir, "lib", "rubotty")
      FileUtils.mkdir_p([scripts, lib])
      script = File.join(scripts, "resolve-version.sh")
      FileUtils.cp(File.expand_path("../scripts/resolve-version.sh", __dir__), script)
      FileUtils.cp(File.expand_path("../lib/rubotty/version.rb", __dir__), lib)
      env = { "SOURCE_COMMIT" => "deadbeef" + "0" * 32, "GIT_ALLOW_PROTOCOL" => "" }

      output, status = Open3.capture2e(env, "sh", script)

      expect(status).to be_success, output
      expect(File.read(File.join(lib, "resolved_version.txt")))
        .to eq("#{Rubotty::VersionResolution::FALLBACK}+gdeadbeef\n")
    end
  end
end
