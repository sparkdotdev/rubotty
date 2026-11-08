# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Core::Announcement do
  let(:frozen) { Time.utc(2026, 7, 22, 14, 8, 7) }

  # A stand in for BuildInfo, so the banner format is pinned without depending
  # on the machine the suite happens to run on.
  let(:info) do
    double(
      service_name: "rubotty",
      version: "0.1.0",
      commit: "a1b2c3",
      runtime: "ruby 4.0.6 (2026-07-14 revision 03b6d3f889)",
      hostname: "miniserv",
      platform: "Linux 7.1.4-200.fc44.x86_64, Fedora Linux 44 (Server Edition) x86_64"
    )
  end

  # Stubbed for the same reason as the build info: probing the real transpilers
  # would pin this spec to whatever the developer happens to have installed.
  let(:dialects) do
    versions = { "moonscript" => "0.5.0", "fennel" => "1.6.1", "teal" => "0.24.6" }
    double(
      lua_runtime: "Lua 5.4.8  Copyright (C) 1994-2025 Lua.org, PUC-Rio",
      available: Rubotty::Scripting::Dialects::ALL,
      version: nil
    ).tap do |stub|
      allow(stub).to receive(:version) { |dialect| versions[dialect.name] }
    end
  end

  def banner(level, dialects: self.dialects)
    described_class.new(level: level, info: info, dialects: dialects, clock: -> { frozen })
  end

  describe "full detail" do
    subject(:text) { banner(:full).text }

    it "matches the requested format exactly" do
      expect(text).to eq(<<~BANNER.chomp)
        Started rubotty at Wed, 22 Jul 2026 14:08:07 GMT.
        rubotty version: 0.1.0 (a1b2c3)
        ruby runtime: ruby 4.0.6 (2026-07-14 revision 03b6d3f889)
        lua runtime: Lua 5.4.8  Copyright (C) 1994-2025 Lua.org, PUC-Rio [dialects: MoonScript 0.5.0, Fennel 1.6.1, Teal 0.24.6]
        host: miniserv (Linux 7.1.4-200.fc44.x86_64, Fedora Linux 44 (Server Edition) x86_64)
      BANNER
    end

    # A build with no interpreter cannot run a script at all, and saying so by
    # omission beats printing a blank version.
    it "drops the lua line when no interpreter is on PATH" do
      absent = double(lua_runtime: nil)
      expect(banner(:full, dialects: absent).text).not_to include("lua runtime")
    end

    # Lua is already named as the runtime, so listing it among the dialects
    # would only repeat it.
    it "lists the transpiled dialects and not lua itself" do
      expect(text).to include("[dialects: MoonScript 0.5.0, Fennel 1.6.1, Teal 0.24.6]")
      expect(text).not_to match(/dialects:[^\]]*\bLua\b/)
    end

    it "reports the time in UTC with a GMT suffix" do
      expect(text).to include("Wed, 22 Jul 2026 14:08:07 GMT")
    end
  end

  describe "minimal detail" do
    subject(:text) { banner(:minimal).text }

    it "keeps the identity lines" do
      expect(text).to eq(<<~BANNER.chomp)
        Started rubotty at Wed, 22 Jul 2026 14:08:07 GMT.
        rubotty version: 0.1.0 (a1b2c3)
      BANNER
    end

    # The reason minimal is the default: these lines tell a stranger in the
    # channel which CVEs might apply to the host.
    it "discloses no kernel, distribution or hostname" do
      expect(text).not_to include("miniserv")
      expect(text).not_to include("Fedora")
      expect(text).not_to include("Linux")
    end
  end

  it "defaults to minimal, the less disclosing option" do
    expect(described_class.new(info: info).level).to eq(:minimal)
  end

  it "falls back to minimal for an unrecognised level" do
    expect(described_class.new(level: :verbose, info: info).level).to eq(:minimal)
  end

  it "produces canonical rich text with no markup" do
    body = banner(:minimal).body
    expect(body).to be_a(Rubotty::Core::RichText)
    expect(body.spans).to be_empty
  end

  it "omits the parenthetical entirely when the commit is unknown" do
    unknown = double(
      service_name: "rubotty", version: "0.1.0", commit: Rubotty::Core::BuildInfo::UNKNOWN,
      runtime: "ruby", hostname: "host", platform: "Linux"
    )
    expect(described_class.new(info: unknown, clock: -> { frozen }).version_line).to eq("rubotty version: 0.1.0")
  end
end

RSpec.describe Rubotty::Core::Announcement::Suppressor do
  let(:storage) { Rubotty::Storage::Memory.new }
  let(:now) { Time.now }

  def suppressor(window:, at: now, version: "0.1.5")
    described_class.new(storage: storage, window: window, version: version,
                        logger: Rubotty::Log.null, clock: -> { at })
  end

  it "allows the first announcement" do
    expect(suppressor(window: 3600).claim).to be(true)
  end

  # A crash loop restarting every few seconds would otherwise announce itself
  # into the channel every few seconds.
  it "suppresses a second announcement of the same version inside the window" do
    suppressor(window: 3600).claim
    expect(suppressor(window: 3600, at: now + 60).claim).to be(false)
  end

  it "allows another once the window has passed" do
    suppressor(window: 3600).claim
    expect(suppressor(window: 3600, at: now + 3601).claim).to be(true)
  end

  it "never suppresses when the window is zero" do
    3.times { expect(suppressor(window: 0).claim).to be(true) }
  end

  # A deploy lands well inside the suppress window, so without this the operator
  # never sees the "it is back up, version X" confirmation after a real upgrade.
  it "always posts when the running version changed, bypassing the window" do
    suppressor(window: 3600, version: "0.1.4").claim
    upgraded = suppressor(window: 3600, at: now + 60, version: "0.1.5")
    expect(upgraded.claim).to be(true)
  end

  it "records the new version so a same version restart is then suppressed" do
    suppressor(window: 3600, version: "0.1.4").claim
    suppressor(window: 3600, at: now + 1, version: "0.1.5").claim
    again = suppressor(window: 3600, at: now + 60, version: "0.1.5")
    expect(again.claim).to be(false)
  end

  it "remembers across a restart, because storage is where the state lives" do
    suppressor(window: 3600).claim
    fresh = described_class.new(storage: storage, window: 3600, version: "0.1.5",
                                clock: -> { now + 60 })
    expect(fresh.claim).to be(false)
  end

  # A scope namespaces the persisted state, so one community's banner never
  # squelches another's.
  it "keeps suppression state independent across scopes" do
    described_class.new(storage: storage, window: 3600, version: "0.1.5",
                        scope: "alpha", clock: -> { now }).claim
    beta = described_class.new(storage: storage, window: 3600, version: "0.1.5",
                               scope: "beta", clock: -> { now + 60 })
    expect(beta.claim).to be(true)
  end

  it "suppresses a same-scope restart of the same build within the window" do
    described_class.new(storage: storage, window: 3600, version: "0.1.5",
                        scope: "alpha", clock: -> { now }).claim
    again = described_class.new(storage: storage, window: 3600, version: "0.1.5",
                                scope: "alpha", clock: -> { now + 60 })
    expect(again.claim).to be(false)
  end

  it "does not let a scoped claim suppress the global record" do
    described_class.new(storage: storage, window: 3600, version: "0.1.5",
                        scope: "alpha", clock: -> { now }).claim
    global = described_class.new(storage: storage, window: 3600, version: "0.1.5",
                                 clock: -> { now + 60 })
    expect(global.claim).to be(true)
  end

  # A duplicate banner is a far smaller problem than a bridge that will not start.
  it "posts rather than failing when storage is unavailable" do
    broken = Rubotty::Storage::Memory.new
    allow(broken).to receive(:get_state).and_raise(Rubotty::StorageError, "down")
    guard = described_class.new(storage: broken, window: 3600, version: "0.1.5",
                                logger: Rubotty::Log.null)
    expect(guard.claim).to be(true)
  end
end

RSpec.describe Rubotty::Core::BuildInfo do
  before { described_class.reset! }
  after { described_class.reset! }

  it "reports the hardcoded software identity, not anything discovered at run time" do
    expect(described_class.service_name).to eq("rubotty")
    expect(described_class.version).to eq(Rubotty::VERSION)
  end

  it "uses RUBY_DESCRIPTION verbatim for the runtime line" do
    expect(described_class.runtime).to eq(RUBY_DESCRIPTION)
  end

  it "prefers an injected commit over asking git" do
    expect(described_class.commit(env: { "BRIDGE_COMMIT" => "deadbeefcafe" })).to eq("deadbee")
  end

  # Heroku's Ruby buildpack sets this, and a deployed container has no .git.
  it "reads Heroku's SOURCE_VERSION" do
    expect(described_class.commit(env: { "SOURCE_VERSION" => "abcdef1234567" })).to eq("abcdef1")
  end

  # Coolify sets this only when "Include Source Commit in Build" is enabled,
  # which is off by default.
  it "reads Coolify's SOURCE_COMMIT" do
    expect(described_class.commit(env: { "SOURCE_COMMIT" => "1234567890ab" })).to eq("1234567")
  end

  it "prefers the generic override over a platform variable" do
    env = { "BRIDGE_COMMIT" => "1111111", "SOURCE_VERSION" => "2222222" }
    expect(described_class.commit(env: env)).to eq("1111111")
  end

  it "ignores an empty variable rather than reporting a blank commit" do
    described_class.reset!
    expect(described_class.commit(env: { "BRIDGE_COMMIT" => "  " })).not_to eq("")
  end

  it "always produces a hostname" do
    expect(described_class.hostname).to be_a(String)
    expect(described_class.hostname).not_to be_empty
  end

  it "always produces a platform string" do
    expect(described_class.platform).to be_a(String)
    expect(described_class.platform).not_to be_empty
  end

  # /etc/os-release does not exist on macOS, and a developer's first run must
  # not blow up on it.
  it "tolerates the absence of an os-release file" do
    allow(File).to receive(:readable?).with("/etc/os-release").and_return(false)
    described_class.reset!
    expect { described_class.distribution }.not_to raise_error
    expect(described_class.distribution).to be_nil
  end

  it "reads PRETTY_NAME when the file is present" do
    allow(File).to receive(:readable?).with("/etc/os-release").and_return(true)
    allow(File).to receive(:foreach).with("/etc/os-release")
                                    .and_yield("ID=fedora\n")
                                    .and_yield("PRETTY_NAME=\"Fedora Linux 44 (Server Edition)\"\n")
    described_class.reset!
    expect(described_class.distribution).to eq("Fedora Linux 44 (Server Edition)")
  end
end
