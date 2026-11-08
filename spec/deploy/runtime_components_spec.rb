# frozen_string_literal: true

require "spec_helper"
require_relative "../../scripts/runtime-components"

RSpec.describe RuntimeComponents do
  let(:directory) { Dir.mktmpdir("runtime-components-") }
  let(:receipt) { File.join(directory, "runtime.json") }
  let(:source) { File.join(directory, "teal-source.json") }
  let(:revision) { "a" * 40 }

  around do |example|
    original_path = ENV.fetch("PATH")
    fixture_bin = File.join(directory, "bin")
    FileUtils.mkdir_p(fixture_bin)
    commands = {
      "ruby" => "echo 'ruby 4.0.9'",
      "lua" => "echo 'Lua 5.5.1' >&2",
      "fennel" => "echo 'Fennel 1.6.1'",
      "tl" => "echo 'Teal 0.24.8+dev'",
      "git" => "echo '#{revision}'",
      "luarocks" => <<~SH
        if [ "$1" = "--version" ]; then
          echo 'LuaRocks 3.13.0'
        else
          printf 'fennel\\t1.6.1-1\\tinstalled\\t/usr/local\\ntl\\tdev-1\\tinstalled\\t/usr/local\\n'
        fi
      SH
    }
    commands.each do |name, body|
      filename = File.join(fixture_bin, name)
      File.write(filename, "#!/bin/sh\n#{body}\n")
      File.chmod(0o755, filename)
    end
    ENV["PATH"] = [fixture_bin, original_path].join(File::PATH_SEPARATOR)
    example.run
  ensure
    ENV["PATH"] = original_path
    FileUtils.remove_entry(directory)
  end

  it "records installed versions, every rock and the exact source used for Teal" do
    described_class.capture_teal(directory, source)
    described_class.capture(receipt, source)
    captured = JSON.parse(File.read(receipt))
    expect(captured.fetch("runtimes").transform_values { |entry| entry.fetch("version") })
      .to eq("ruby" => "4.0.9", "lua" => "5.5.1", "luarocks" => "3.13.0")
    expect(captured.fetch("tools").fetch("fennel").fetch("version")).to eq("1.6.1")
    expect(captured.fetch("tools").fetch("teal")).to include("version" => "0.24.8+dev", "source_commit" => revision)
    expect(captured.fetch("rocks")).to eq([{ "name" => "fennel", "version" => "1.6.1-1" },
                                          { "name" => "tl", "version" => "dev-1" }])
  end

  it "refuses an installed Teal without matching source evidence" do
    expect { described_class.capture(receipt, source) }.to raise_error(/no recorded source/)
    expect(File.exist?(receipt)).to be(false)
    described_class.capture_teal(directory, source)
    recorded = JSON.parse(File.read(source)).merge("version" => "0.0.0")
    File.write(source, JSON.generate(recorded))
    expect { described_class.capture(receipt, source) }.to raise_error(/differs from its source/)
    expect(File.exist?(receipt)).to be(false)
  end

  it "adds missing software components while retaining scanner evidence and source provenance" do
    described_class.capture_teal(directory, source)
    described_class.capture(receipt, source)
    scanner = File.join(directory, "scanner.json")
    enriched = File.join(directory, "release.json")
    existing = { "type" => "library", "name" => "fennel", "version" => "1.6.1-1", "bom-ref" => "scanner-fennel" }
    File.write(scanner, JSON.generate("bomFormat" => "CycloneDX", "components" => [existing],
                                     "metadata" => { "properties" => [{ "name" => "scanner", "value" => "preserve" }] }))
    described_class.enrich(scanner, receipt, enriched)
    captured = JSON.parse(File.read(enriched))
    components = captured.fetch("components")
    expect(components.map { |item| item.fetch("name") }).to contain_exactly("fennel", "ruby", "lua", "luarocks", "tl")
    expect(components.find { |item| item["name"] == "fennel" }).to include("bom-ref" => "scanner-fennel")
    expect(components.find { |item| item["name"] == "tl" }.fetch("properties"))
      .to include("name" => "rubotty:source-commit", "value" => revision)
    expect(captured.fetch("metadata").fetch("properties"))
      .to include("name" => "rubotty:runtime-receipt-sha256", "value" => Digest::SHA256.file(receipt).hexdigest)
    described_class.enrich(enriched, receipt, enriched)
    expect(JSON.parse(File.read(enriched))).to eq(captured)
    expect(JSON.parse(File.read(scanner)).fetch("components")).to eq([existing])
  end

  it "does not rewrite a document that is not a CycloneDX SBOM" do
    wrong = File.join(directory, "wrong.json")
    output = File.join(directory, "out.json")
    File.write(wrong, "{}")
    expect { described_class.enrich(wrong, receipt, output) }.to raise_error(/CycloneDX/)
    expect(File.exist?(output)).to be(false)
  end
end
