# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "tmpdir"
require "rack/builder"

RSpec.describe Rubotty::Config::Loader, ".load_for_boot" do
  let(:diagnostics) { StringIO.new }

  def boot(path, env: {})
    described_class.load_for_boot(path, env: env, err: diagnostics)
  end

  [nil, "", "  \t"].each do |path|
    it "announces database configuration when the path is #{path.inspect}" do
      model = boot(path)
      expect(model.accounts).to eq({})
      expect(model.rooms).to eq([])
      expect(diagnostics.string).to match(/No configuration given.*database alone/)
    end
  end

  it "does not silently load a legacy filename when no path was given" do
    Dir.mktmpdir do |directory|
      File.write(File.join(directory, "bridge.config.yaml"), "name: unintended legacy configuration\n")
      Dir.chdir(directory) { expect(boot(nil).name).to eq("rubotty") }
    end
  end

  it "announces an explicitly missing file while retaining database configuration support" do
    Dir.mktmpdir do |directory|
      model = boot(File.join(directory, "missing.yaml"))
      expect(model.accounts).to eq({})
      expect(diagnostics.string).to include("missing or is not a regular file", "database alone")
    end
  end

  it "loads an explicitly supplied file without a missing-configuration notice" do
    Tempfile.create(["bridge", ".yaml"]) do |file|
      file.write("name: configured bridge\naccounts:\n  tg:\n    adapter: telegram\n    token_env: BOOT_TOKEN\n")
      file.flush
      model = boot(file.path, env: { "BOOT_TOKEN" => "fixture-token" })
      expect(model.name).to eq("configured bridge")
      expect(model.accounts.fetch("tg").settings.fetch(:token)).to eq("fixture-token")
      expect(diagnostics.string).to eq("")
    end
  end

  it "keeps an intentionally empty file quiet" do
    Tempfile.create(["bridge", ".yaml"]) do |file|
      expect(boot(file.path).accounts).to eq({})
      expect(diagnostics.string).to eq("")
    end
  end

  it "raises for invalid supplied configuration instead of treating it as absent" do
    Tempfile.create(["bridge", ".yaml"]) do |file|
      file.write("accounts:\n  invalid:\n    adapter: nonexistent\n")
      file.flush
      expect { boot(file.path) }.to raise_error(Rubotty::ConfigError, /unknown adapter/)
      expect(diagnostics.string).to eq("")
    end
  end

  %w[config.ru web.ru guest.ru api.ru filestorage.ru].each do |entrypoint|
    it "uses the shared boot diagnostics in #{entrypoint}" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("BRIDGE_CONFIG").and_return(nil)
      stop = Class.new(StandardError)
      expect(described_class).to receive(:load_for_boot).with(nil, env: ENV).and_raise(stop)
      path = File.expand_path("../../#{entrypoint}", __dir__)
      original_load_path = $LOAD_PATH.dup
      expect { Rack::Builder.new.instance_eval(File.read(path), path, 1) }.to raise_error(stop)
    ensure
      $LOAD_PATH.replace(original_load_path) if original_load_path
    end
  end
end
