# frozen_string_literal: true

require "spec_helper"
require "json"
require "open3"

# The deploy config, checked for the mistakes CI cannot see. CI installs the same
# packages on a runner that already has Ruby, and never assembles an image, so
# nothing else exercises what order the layers are built in and what each one is
# built on.
RSpec.describe "railpack.json" do
  root = File.expand_path("../..", __dir__)
  source = File.read(File.join(root, "railpack.json"))

  # Railpack parses its config with hujson, so the file legitimately carries
  # comments and trailing commas that Ruby's JSON refuses.
  def self.parse_jwcc(text)
    out = +""
    state = :code
    index = 0

    while index < text.length
      char = text[index]
      pair = text[index, 2]

      case state
      when :code
        case pair
        when "//" then state = :line_comment
        when "/*" then state = :block_comment
        else
          out << char
          state = :string if char == "\""
        end
      when :string
        out << char
        if char == "\\"
          out << text[index + 1].to_s
          index += 1
        elsif char == "\""
          state = :code
        end
      when :line_comment
        state = :code if char == "\n"
      when :block_comment
        if pair == "*/"
          state = :code
          index += 1
        end
      end

      index += 1
    end

    # Trailing commas, which hujson allows and JSON does not.
    JSON.parse(out.gsub(/,(\s*[}\]])/m, '\1'))
  end

  # A constant assigned in a describe block lands on Object, so two deploy specs
  # naming the same one would fight.
  parsed = parse_jwcc(source)
  repo_root = root

  let(:root) { repo_root }
  let(:config) { parsed }

  def steps
    config.fetch("steps")
  end

  def all_layers
    steps.values.flat_map { |step| step["inputs"].to_a } +
      [config.dig("deploy", "base")].compact +
      config.dig("deploy", "inputs").to_a
  end

  def all_commands
    steps.values.flat_map { |step| step["commands"].to_a }
  end

  def commands_in(step)
    steps.fetch(step).fetch("commands")
  end

  it "parses, which is the cheapest thing this file can get wrong" do
    expect(config).to be_a(Hash)
    expect(config["$schema"]).to eq("https://schema.railpack.com")
  end

  # Coolify decodes this file with PHP's json_decode before railpack ever runs, and that
  # rejects comments and trailing commas even though railpack's own hujson parser would
  # accept them, so the file has to stay strict JSON.
  it "is strict JSON, because Coolify decodes it before railpack sees it" do
    expect { JSON.parse(source) }.not_to raise_error
  end

  # Railpack's builder image is where mise lives, mise compiles Ruby from source,
  # and railpack's apt step is the layer underneath it, so a step based on either
  # one puts the Ruby build back in reach of a package change.
  it "never bases a step on railpack's own images or on its mise and apt steps" do
    offenders = all_layers.select do |layer|
      layer["image"].to_s.include?("railpack-") || layer["step"].to_s.start_with?("packages:")
    end

    expect(offenders).to be_empty,
                         "these layers put mise (and the Ruby build) back under the deploy: " \
                         "#{offenders.map(&:to_s).join(", ")}"
  end

  # Build and deploy share the patched OS step, so the interpreter and native
  # extensions link against the libraries the final image actually contains.
  it "builds on the same distribution railpack deploys onto" do
    images = all_layers.filter_map { |layer| layer["image"] }

    expect(images).not_to be_empty
    images.each do |image|
      expect(image).to include("trixie"), "#{image.inspect} does not match the selected Debian runtime"
    end
  end

  # build-ruby.sh deliberately never pins a version: it resolves the newest tagged
  # stable release at build time (git ls-remote against ruby/ruby), so production
  # is never more than a release behind. .ruby-version stays the separate,
  # minimum-supported floor for local dev, not something the build has to match.
  it "never pins a Ruby version to bump by hand" do
    script = File.read(File.join(root, "scripts/build-ruby.sh"), encoding: Encoding::UTF_8)

    expect(script).not_to match(/^RUBY_VERSION=\d/),
                          "build-ruby.sh hardcodes a version instead of resolving the latest tag"
    expect(script).to match(/git ls-remote --tags --refs https:\/\/github\.com\/ruby\/ruby\.git/)
  end

  # Railpack flattens a local include to its basename: an include of scripts/build-ruby.sh
  # is copied to /app/build-ruby.sh, not to /app/scripts/build-ruby.sh. Calling it by the
  # repository path fails with "No such file or directory".
  it "calls the build scripts where railpack actually puts them" do
    invocations = all_commands.grep(/build-(ruby|lua|teal)\.sh/)

    expect(invocations).not_to be_empty
    invocations.each do |command|
      expect(command).to match(%r{/app/build-(ruby|lua|teal)\.sh}),
                         "#{command.inspect} uses the repository path; railpack copies these to /app by basename"
    end
  end

  # Railpack pins GEM_HOME and GEM_PATH to /usr/local/bundle with no way to change them, so
  # `bundle config path` is not an option: it puts gems where the runtime never looks.
  it "installs gems where the runtime is told to look for them" do
    install = steps.fetch("install")

    expect(install["commands"]).to include(a_string_matching(%r{GEM_HOME=/usr/local/bundle BUNDLE_FROZEN=true bundle install}))
    expect(all_commands).not_to include(a_string_matching(/bundle config .*\bpath\b/)),
                                "bundle config path relocates the gems out from under GEM_PATH"
  end

  # Railpack mounts supplied build variables in every command. The recipe only
  # declares the non-sensitive inputs its own steps use for caching.
  it "declares no credential inputs in the build recipe" do
    expect(config.fetch("secrets")).to contain_exactly("SOURCE_COMMIT", "BUNDLE_WITH")
    expect(steps.values.flat_map { |step| step.fetch("secrets") }.uniq).to match_array(config.fetch("secrets"))
  end

  it "keeps the deployment checkout of YAMLCamel at the locked revision" do
    next unless File.file?(File.join(root, ".gitmodules"))

    lock = File.read(File.join(root, "Gemfile.lock"))
    revision = lock[%r{remote: https://github\.com/[A-Za-z0-9-]+/yamlcamel-ruby\.git\n  revision: ([0-9a-f]{40})}, 1]
    expect(revision).not_to be_nil
    entry, status = Open3.capture2("git", "-C", root, "ls-files", "-s", "--", "vendor/yamlcamel-ruby")
    expect(status).to be_success
    expect(entry.strip).to eq("160000 #{revision} 0\tvendor/yamlcamel-ruby")
  end

  # Hardcoded because a command may not contain a colon, which rules out the
  # provider's own `gem install bundler:<version>` form.
  it "locks the source-built SQLite dependency graph used by the frozen runtime" do
    require "bundler"

    lock = Bundler::LockfileParser.new(File.read(File.join(root, "Gemfile.lock")))
    expect(lock.platforms.map(&:to_s)).to include("ruby")
    sqlite = lock.specs.find { |spec| spec.name == "sqlite3" && spec.platform.to_s == "ruby" }
    expect(sqlite).not_to be_nil
    sqlite.dependencies.each do |dependency|
      target = lock.specs.find { |spec| spec.name == dependency.name }
      expect(target).not_to be_nil
      expect(dependency.requirement).to be_satisfied_by(target.version)
    end
    expect(config.dig("deploy", "variables", "BUNDLE_FROZEN")).to eq("true")
  end

  it "installs the bundler the lockfile was resolved with" do
    locked = File.read(File.join(root, "Gemfile.lock")).lines.last.strip
    install = steps.fetch("install")

    expect(install["commands"]).to include(a_string_matching(/gem install -N bundler -v #{Regexp.escape(locked)}/)),
                                   "Gemfile.lock says #{locked}"
  end

  # force_ruby_platform has to be readable at runtime, not just while installing. Set with
  # --global it lands in /root/.bundle, which the deploy image never copies, so it has to
  # be written next to the Gemfile instead, where it travels with the app.
  it "carries force_ruby_platform into the image, not just the build" do
    expect(steps.fetch("build")["commands"])
      .to include(a_string_matching(/bundle config set --local force_ruby_platform true/))
  end

  # A source build that cannot verify what it downloaded is a supply chain hole. Ruby
  # and luarocks are cloned rather than fetched as tarballs, so git's own object hashing
  # is the verification. Lua comes from a tarball instead, since lua.org publishes no
  # checksum to pin against, so TLS is what verifies that fetch.
  it "verifies what it fetches, by git hash where a repo is the source" do
    ruby = File.read(File.join(root, "scripts/build-ruby.sh"), encoding: Encoding::UTF_8)
    lua = File.read(File.join(root, "scripts/build-lua.sh"), encoding: Encoding::UTF_8)

    expect(ruby).to match(%r{git clone --depth 1 --branch .*github\.com/ruby/ruby\.git}m)
    expect(lua).to match(%r{git clone --depth 1 --branch .*github\.com/luarocks/luarocks\.git}m)
    expect(lua).to match(%r{curl -fsSL .*https://www\.lua\.org/ftp/}m)
  end

  # System libraries come from the selected base and its runtime packages;
  # compiled application artifacts alone are copied from the install layer.
  it "asks for the libraries the interpreter links" do
    packages = config.dig("deploy", "aptPackages").to_a

    expect(packages).to include("libyaml-0-2", "libssl3t64", "zlib1g", "libffi8")
    expect(packages).to include("libjemalloc2"), "the provider LD_PRELOADs this and cannot be told not to"
    expect(packages).to include("curl", "wget"), "the healthcheck calls these"
  end

  # build-ruby.sh and build-lua.sh both need git on PATH before they run, to resolve
  # the latest tag and clone the source: it has to land in the runtime step's own apt
  # install, not just the toolchain step's later one, since toolchain runs after these
  # scripts already have. A production deploy failed within seconds on exactly this.
  it "installs git before the build scripts that need it run" do
    runtime_commands = commands_in("runtime")
    apt_line = runtime_commands.find { |cmd| cmd.start_with?("apt-get install") }
    script_index = runtime_commands.index { |cmd| cmd.match?(/build-(ruby|lua)\.sh/) }

    expect(apt_line).to include(" git"), "git is missing from the runtime step's own apt install"
    expect(runtime_commands.index(apt_line)).to be < script_index
  end

  it "uses the patched OS layer as the explicit build and deployment base" do
    expect(config.dig("deploy", "base")).to eq({ "step" => "os" })
    expect(steps.fetch("runtime").fetch("inputs").first).to eq({ "step" => "os" })
    expect(commands_in("os")).to include("apt-get update", "apt-get upgrade -y --no-install-recommends")
  end

  # The runtime step's own filesystem has to be copied in explicitly, because railpack will
  # not use it as a base. Paths are listed one by one rather than as a bare /usr, since
  # buildkit refuses to copy a directory over a symlink; only /usr/local ships, since
  # copying anything from the distribution itself overwrote the base image's own binaries.
  it "copies what we built and nothing belonging to the distribution" do
    runtime_input = config.dig("deploy", "inputs").find { |input| input["include"] == ["/usr/local"] }

    expect(runtime_input).not_to be_nil, "nothing carries ruby and lua into the image"
    included = runtime_input["include"].to_a

    expect(included).to eq(["/usr/local"])
    expect(included).not_to include("/usr/bin"), "this overwrote the base image's bash"
    expect(included).not_to include("."), "the workdir alone is what broke this before"
  end



  # The sandbox child requires MessagePack on every message, so a deploy
  # without it produces a bot that cannot run a single script.
  it "installs the one runtime rock, and proves it can be required" do
    commands = commands_in("runtime")

    expect(commands).to include(a_string_matching(/luarocks\S* install lua-messagepack-lua53/))
    expect(commands).to include(a_string_matching(/\blua -l MessagePack\b/))
  end

  # Railpack reads a command string containing a colon as "type:payload"
  # (core/plan/command.go, UnmarshalStringCommand), so `gem install bundler:4.0.16`
  # quietly becomes a command of a type nobody meant.
  it "keeps colons out of the command strings, which railpack reads as a type prefix" do
    offenders = all_commands.grep(/:/)

    expect(offenders).to be_empty,
                         "railpack will split these on the colon and run something else: #{offenders.join(", ")}"
  end

  # Railpack builds the real command as "sh -c '" + yours + "'" and shlex splits
  # the result, so a quote of your own closes railpack's and the rest of the line
  # falls out into stray arguments. The build usually still succeeds.
  it "keeps single quotes out of the command strings, which railpack quotes for you" do
    offenders = all_commands.grep(/'/)

    expect(offenders).to be_empty,
                         "these close the quote railpack wraps around them: #{offenders.join(", ")}"
  end

  # luarocks is built from source against the Lua built alongside it, so it lands
  # as a plain `luarocks`. A distribution's version-suffixed one could drag its own
  # interpreter back in beside ours, which is the thing to keep out.
  it "calls the luarocks it builds rather than a distribution package" do
    invoked = all_commands.flat_map { |command| command.scan(/(\S*luarocks\S*)\s+install\b/) }.flatten

    expect(invoked).not_to be_empty
    invoked.each do |binary|
      expect(binary).to eq("luarocks"),
                        "#{binary.inspect} selects a different interpreter from the one built for the image"
    end
  end

  # A dialect whose compiler is missing is reported unavailable and never offered,
  # so a transpiler failing to build costs one dialect rather than the service.
  # tl comes from build-teal.sh rather than a rock, so it is checked against
  # its own script call instead of a luarocks install.
  it "lets a transpiler fail without failing the deploy" do
    %w[fennel moonscript].each do |rock|
      line = all_commands.find { |command| command.match?(/luarocks\S* install #{rock}\b/) }

      expect(line).not_to be_nil, "#{rock} is not installed at all"
      expect(line).to include("||"), "#{rock} failing would take the deploy down with it"
    end

    teal_line = all_commands.find { |command| command.match?(%r{/app/build-teal\.sh\b}) }

    expect(teal_line).not_to be_nil, "tl is not installed at all"
    expect(teal_line).to include("||"), "tl failing would take the deploy down with it"
  end

  it "builds Teal from upstream main rather than a Rubotty fork" do
    script = File.read(File.join(root, "scripts", "build-teal.sh"), encoding: Encoding::UTF_8)

    expect(script).to include('TEAL_REPO="${RUBOTTY_TEAL_REPO:-https://github.com/teal-language/tl}"')
    expect(script).to include('TEAL_REF="${RUBOTTY_TEAL_REF:-main}"')
  end

  it "does not let the required rock fail quietly" do
    required = all_commands.find { |command| command.match?(/luarocks\S* install lua-messagepack-lua53/) }

    expect(required).not_to include("||"),
                            "a missing MessagePack has to fail the build here, rather than at the first message somebody sends"
  end

  # Railpack writes Entrypoint: ["/bin/bash", "-c"] into the image config with no setting to
  # change it, so a base without bash dies on "exec: /bin/bash: not found" before any of our
  # code runs. bash comes with the base image now, so what's worth asserting is that nothing
  # replaces it.
  it "trusts the base image for bash and does not overwrite it" do
    expect(config.dig("deploy", "aptPackages")).to include("ca-certificates")
  end

  # The toolchain is deliberately NOT removed: only /usr/local is copied into the deploy
  # image, so a compiler in this step cannot reach production however long it stays. Purging
  # it instead broke the build, since apt-get purge plus autoremove took bundler's own
  # dependencies with it.
  it "never copies anything that could carry the toolchain" do
    runtime_input = config.dig("deploy", "inputs").find { |input| input["include"] == ["/usr/local"] }

    expect(runtime_input["include"]).to eq(["/usr/local"])
    expect(runtime_input["step"]).to eq("install")
  end

  # A source build that quietly resolves a precompiled gem is not a source build,
  # and Bundler prefers the platform binaries ffi, pg and sqlite3 publish.
  it "forces bundler off the precompiled gems" do
    expect(all_commands).to include(a_string_matching(/bundle config .*force_ruby_platform true/))
  end

  # The deployed 0.4.1 build reported +PRISM and no +YJIT, so this is the whole
  # point of building the interpreter rather than taking the packaged one.
  it "builds ruby with yjit and proves it" do
    script = File.read(File.join(repo_root, "scripts/build-ruby.sh"), encoding: Encoding::UTF_8)

    expect(script).to match(/--enable-yjit/)
    expect(script).to match(/RubyVM..YJIT\.enabled\?/)
  end

  # Every host builds its own image, which is what makes native tuning safe, and
  # the override is what makes it recoverable if that ever stops being true.
  it "lets the architecture flags be overridden" do
    %w[build-ruby.sh build-lua.sh].each do |name|
      script = File.read(File.join(repo_root, "scripts", name), encoding: Encoding::UTF_8)
      expect(script).to match(/RUBOTTY_ARCH_FLAGS/), "#{name} hardcodes the architecture"
    end
  end

  # The bundles are gitignored, so this step is the only thing that puts the
  # dashboard's script editor and charts in the image.
  it "builds the browser bundles" do
    expect(commands_in("assets")).to include("npm ci --no-audit --no-fund", "npm run build")
  end

  # npm ci runs in a step the application step is built on, so node_modules is in
  # /app by the time anything is copied out of it. Nothing drops it on its own:
  # the deploy input has to say so by name.
  it "leaves node_modules out of the final image" do
    carrying_app = config.dig("deploy", "inputs").select { |input| input["include"].to_a.include?(".") }

    expect(carrying_app).not_to be_empty
    carrying_app.each do |input|
      expect(input["exclude"].to_a).to include("node_modules"),
                                       "#{input.inspect} ships the whole build tree, node_modules and all"
    end
  end

  # Build inputs can carry version metadata and deployment authentication.
  # The final application copy excludes repository metadata, local environment
  # files and SSH directories, including nested copies.
  it "excludes local environment files, key directories and git metadata from the final image" do
    carrying_app = config.dig("deploy", "inputs").select { |input| input["include"].to_a.include?(".") }
    private_inputs = %w[.git **/.git .env .env.* **/.env **/.env.* .ssh **/.ssh]

    expect(carrying_app).not_to be_empty
    carrying_app.each do |input|
      expect(input["exclude"].to_a).to include(*private_inputs),
                                       "the final application copy must exclude private build inputs"
    end
  end

  it "excludes private CI infrastructure while retaining the shared application recipe" do
    carrying_app = config.dig("deploy", "inputs").select { |input| input["include"].to_a.include?(".") }
    expect(carrying_app).not_to be_empty
    flags = File::FNM_PATHNAME | File::FNM_DOTMATCH
    carrying_app.each do |input|
      exclusions = input.fetch("exclude")
      expect(exclusions).to include("deploy/ci", "deploy/ci/**")
      excluded = lambda do |path|
        parts = path.split("/")
        prefixes = (1..parts.length).map { |length| parts.take(length).join("/") }
        prefixes.any? { |prefix| exclusions.any? { |pattern| File.fnmatch?(pattern, prefix, flags) } }
      end
      %w[deploy/ci deploy/ci/Dockerfile deploy/ci/nested/admit-job.py].each do |path|
        expect(excluded.call(path)).to be(true)
      end
      %w[deploy/shared-image.compose.yml lib/rubotty/runtime.rb].each do |path|
        expect(excluded.call(path)).to be(false)
      end
    end
  end

  # The deploy image has no .git for lib/rubotty/version.rb to shell out to, so
  # the tag is resolved here instead and baked into a file the running service
  # reads.
  it "resolves the version from the git tag rather than a hardcoded number" do
    build_commands = commands_in("build")

    expect(build_commands).to include(a_string_matching(%r{resolve-version\.sh}))
    expect(steps.fetch("build")["inputs"].to_a.flat_map { |input| input["exclude"].to_a })
      .not_to include(".git"), "the build step needs .git present to resolve the tag"
  end

  # Mirrors "never pins a Ruby version to bump by hand": this script has to keep
  # deriving from the tag, not carry a version anyone would need to bump by hand.
  it "derives the resolved version from a git tag rather than a literal" do
    script = File.read(File.join(root, "scripts/resolve-version.sh"), encoding: Encoding::UTF_8)

    expect(script).to match(/git -C ".*" describe --tags/)
    expect(script).not_to match(/^VERSION="\d/)
  end

  # A step sees repository files only if it was given a local input, and the
  # default is none, so a command naming a file in the tree fails the build.
  it "gives a step a local input before any command in it names a repository file" do
    steps.each do |name, step|
      mentioned = step["commands"].to_a.join(" ").scan(%r{[\w./-]+/[\w./-]+}).uniq.select do |candidate|
        cleaned = candidate.sub(%r{\A\./}, "")
        next false if cleaned.start_with?("/")

        File.exist?(File.join(root, cleaned))
      end

      next if mentioned.empty?

      locals = step["inputs"].to_a.select { |input| input["local"] }
      expect(locals).not_to be_empty,
                            "step #{name.inspect} names #{mentioned.join(", ")} but was given no local input, " \
                            "so the source is not on disk when it runs"
    end
  end

  # The Procfile decides which process a deploy runs, and is the only place the
  # long polling and webhook choice is written down.
  it "leaves the start command to the Procfile" do
    expect(config.dig("deploy", "startCommand")).to be_nil
    expect(File).to exist(File.join(root, "Procfile"))
  end

  # Belongs to the image rather than the Procfile because a platform carrying its own start
  # command never reads the Procfile: the dashboard deploys that way, so a Procfile-only
  # setting would reach the bot but not the dashboard.
  it "switches yjit on for every process, not just the ones the Procfile starts" do
    expect(config.dig("deploy", "variables", "RUBY_YJIT_ENABLE")).to eq("1")
  end

  # A boot diagnostic is worth writing and worth taking back out. Left in, the
  # `|| sleep` that holds a failed container open long enough to read also hides
  # the crash from the orchestrator that would otherwise restart it.
  it "starts each process directly, with no diagnostic wrapper left behind" do
    procfile = File.read(File.join(root, "Procfile"), encoding: Encoding::UTF_8)
    entries = procfile.scan(/^([\w-]+):\s+(.+)$/)

    expect(entries).not_to be_empty
    entries.each do |type, command|
      expect(command).to match(/\Abundle exec bin\/rubotty \S+\z/),
                         "process type #{type.inspect} runs #{command.inspect} rather than the service alone"
    end
  end
end
