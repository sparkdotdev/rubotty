# frozen_string_literal: true

require "spec_helper"
require "json"

# The second supported build, checked for the mistakes CI cannot see: what order
# the buildpacks run in, and what is on disk when they run. apt comes first because
# the buildpacks after it inherit the PATH it exports and nothing before it can.
RSpec.describe "the Heroku buildpack build" do
  root = File.expand_path("../..", __dir__)

  let(:root) { root }
  let(:app_json) { JSON.parse(File.read(File.join(root, "app.json"))) }
  let(:aptfile) { File.read(File.join(root, "Aptfile")) }
  let(:profile) { File.read(File.join(root, ".profile")) }
  let(:project_toml) { File.read(File.join(root, "project.toml")) }

  # Aptfile's own syntax: the buildpack strips comments and blank lines, and reads
  # a leading :repo: as a source rather than a package.
  def apt_packages
    aptfile.lines.map(&:strip).reject { |line| line.empty? || line.start_with?("#", ":repo:") }
  end

  def buildpacks
    app_json.fetch("buildpacks").map { |entry| entry.fetch("url") }
  end

  it "runs apt first, so lua5.4 is on PATH for every buildpack after it" do
    expect(buildpacks.first).to eq("heroku-community/apt")
  end

  # With ruby anywhere else the Procfile's entries are read by a buildpack that
  # cannot run them.
  it "runs ruby last, because the last buildpack owns the Procfile" do
    expect(buildpacks.last).to eq("heroku/ruby")
  end

  # The bundles under lib/rubotty/dashboard/public are gitignored, and on Heroku the
  # node buildpack running package.json's build script is what produces them.
  it "runs the node buildpack, which is the only thing that builds the bundles" do
    expect(buildpacks).to include("heroku/nodejs")
  end

  it "asks apt for the interpreter" do
    expect(apt_packages).to include("lua5.4")
  end

  # There is no apt package for it, and this stack's LuaRocks cannot reach a
  # Lua 5.4 tree at all, so the rock the sandbox requires ships in the
  # repository instead of coming from either package manager.
  it "does not ask apt for a MessagePack package that does not exist" do
    expect(apt_packages).not_to include(a_string_matching(/messagepack/i))
  end

  it "vendors the rock the sandbox requires, since neither package manager can supply it" do
    vendored = File.read(File.join(root, "vendor", "lua", "MessagePack.lua"))

    expect(vendored).to include("m.pack")
    expect(vendored).to include("m.unpack")
  end

  # noble's luarocks still links against Lua 5.1 and cannot install into a 5.4 tree,
  # so listing it would read as though the transpilers are covered when they are not.
  it "does not ask apt for luarocks, which cannot reach Lua 5.4 on this stack" do
    expect(apt_packages).not_to include("luarocks")
  end

  # The apt buildpack relocates everything under $HOME/.apt and exports PATH and
  # LD_LIBRARY_PATH, which finds the interpreter but not its modules: Lua's search
  # path is compiled in and names the original /usr/share/lua/5.4.
  it "points LUA_PATH at the relocated rock, and keeps the default path too" do
    expect(profile).to match(/export LUA_PATH=.*\.apt.*lua\/5\.4/)
    expect(profile).to match(/LUA_PATH=.*;;"/), "without a trailing ;; this replaces Lua's built in path"
    expect(profile).to match(/export LUA_CPATH=.*;;"/)
  end

  it "also points LUA_PATH at the vendored MessagePack, since apt has nothing to relocate" do
    expect(profile).to match(%r{export LUA_PATH=.*vendor/lua})
  end

  # A `ruby` directive in the Gemfile is the tempting fix for a wrong deploy
  # interpreter, and it writes Gemfile.lock's RUBY VERSION stanza, which then has to
  # match the deploy patch level everywhere else. Pin it on the Heroku app instead.
  it "keeps the Gemfile free of a ruby directive, and the lockfile free of RUBY VERSION" do
    gemfile = File.read(File.join(root, "Gemfile"))
    lockfile = File.read(File.join(root, "Gemfile.lock"))

    expect(gemfile).not_to match(/^\s*ruby\s+["']/),
                           "a ruby directive here pins Gemfile.lock to one patch level and breaks the other builds"
    expect(lockfile).not_to include("RUBY VERSION")
  end

  # heroku-postbuild REPLACES the build script rather than running after it, so one
  # that forgets `npm run build` quietly ships a dashboard with no editor or charts.
  it "leaves the node build to the build script, or makes a postbuild call it" do
    package = JSON.parse(File.read(File.join(root, "package.json")))
    scripts = package.fetch("scripts")

    expect(scripts).to have_key("build")

    postbuild = scripts["heroku-postbuild"]
    next if postbuild.nil?

    expect(postbuild).to include("npm run build"),
                         "heroku-postbuild replaces the build script, so it has to run it itself"
  end

  # Same rule as app.json's list, in the format the Fir generation reads:
  # heroku/procfile last, or the Procfile is never read and there are no process types.
  it "orders the Cloud Native buildpacks the same way, with procfile last" do
    ids = project_toml.scan(/^id\s*=\s*"([^"]+)"/).flatten

    expect(ids.first).to eq("heroku/deb-packages")
    expect(ids.last).to eq("heroku/procfile")
    expect(ids).to include("heroku/ruby", "heroku/nodejs")
  end

  it "installs the same two packages on Fir as it does on Cedar" do
    listed = project_toml[/^install\s*=\s*\[(.*?)\]/m, 1].to_s.scan(/"([^"]+)"/).flatten

    expect(listed).to match_array(apt_packages)
  end

  # Heroku's process type names allow letters, digits, hyphens and underscores, so
  # guest-portal is the one that looks risky and is not.
  it "declares process types Heroku will accept" do
    types = File.read(File.join(root, "Procfile")).scan(/^([\w-]+):\s+\S/).flatten

    expect(types).to include("web", "worker", "webui", "guest-portal")
    types.each { |type| expect(type).to match(/\A[a-zA-Z0-9_-]+\z/) }
  end
end
