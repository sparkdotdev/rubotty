# frozen_string_literal: true

require "spec_helper"
require "rubotty/scripting"

# How a script's process is started, and the two layers that decide what it
# runs under: the memory ceiling and the Landlock ruleset. The states worth
# testing are ones no single machine is in at once, so both layers are pinned
# rather than read off the host running the suite.
RSpec.describe Rubotty::Scripting::Confined do
  let(:seccomp) { Rubotty::Scripting::Seccomp }
  let(:landlock) { Rubotty::Scripting::Landlock }
  let(:limits) { Rubotty::Scripting::Limits }

  # Probe results computed while a layer is mocked must not outlive the example.
  around do |example|
    layers = [seccomp, landlock, limits, Rubotty::Scripting::Isolation]
    layers.each(&:reset!)
    example.run
  ensure
    layers.each(&:reset!)
  end

  # Nothing to install, which is the state a Mac is really in and the one the
  # plain spawn is for. The account is pinned off too: with one to become, even
  # this path forks, so a container running as root would take the other branch.
  def with_no_filter
    allow(seccomp).to receive_messages(runtime_profile: nil, compile_profile: nil)
    allow(landlock).to receive(:available?).and_return(false)
    allow(landlock).to receive(:compile_available?).and_return(false)
    allow(Rubotty::Scripting::Isolation).to receive(:account).and_return(nil)
  end

  describe "starting a child where there is nothing to install" do
    before do
      with_no_filter
      allow(limits).to receive(:available?).and_return(true)
    end

    it "spawns with everything the layer underneath still asks for" do
      expect(Process).to receive(:spawn).with(
        { "PATH" => "/usr/bin" }, "/usr/bin/lua", "sandbox.lua",
        hash_including(close_others: true, unsetenv_others: true, rlimit_as: 1024, chdir: "/tmp")
      ).and_return(4242)

      started = described_class.start(kind: :runtime, binary: "/usr/bin/lua", args: ["sandbox.lua"],
                                      env: { "PATH" => "/usr/bin" }, redirects: {},
                                      rlimits: { rlimit_as: 1024 }, chdir: "/tmp")

      expect(started.pid).to eq(4242)
      expect(started.notes).to be_nil
    end

    # The old spawn tried again with no limits at all where the platform
    # refused the ceiling, which quietly produced the weakest child of the lot.
    it "leaves out a ceiling the platform has been measured refusing" do
      allow(limits).to receive(:available?).and_return(false)
      expect(Process).to receive(:spawn).with(any_args, hash_excluding(:rlimit_as)).and_return(1)

      described_class.start(kind: :runtime, binary: "/usr/bin/lua", rlimits: { rlimit_as: 1024 })
    end

    it "keeps every other limit while dropping that one" do
      allow(limits).to receive(:available?).and_return(false)

      expect(described_class.capped({ rlimit_as: 1024, rlimit_cpu: 10 })).to eq({ rlimit_cpu: 10 })
    end

    it "gives an opted-in compiler its own group while retaining environment and file limits" do
      expect(Process).to receive(:spawn).with(
        { "PATH" => "/usr/bin" }, "/usr/bin/compiler", "input",
        hash_including(pgroup: true, close_others: true, unsetenv_others: true,
                       rlimit_as: 1024, rlimit_fsize: 2048, chdir: "/tmp")
      ).and_return(4242)
      described_class.start(kind: :compile, binary: "/usr/bin/compiler", args: ["input"],
                            env: { "PATH" => "/usr/bin" }, rlimits: { rlimit_as: 1024, rlimit_fsize: 2048 },
                            chdir: "/tmp", process_group: true)
    end

    # A spawn's uid and gid are setgid and setuid and nothing else, so an
    # account never reaches Process.spawn directly any more: the fork is what
    # gives {become_the_script_account} its chance to drop the group list.
    it "forks itself rather than asking a spawn to drop into an account" do
      allow(Rubotty::Scripting::Isolation).to receive(:account).and_return({ uid: 4321, gid: 8765 })
      expect(Process).not_to receive(:spawn)
      expect(described_class).to receive(:fork_for_isolation)
        .with("/usr/bin/lua", ["sandbox.lua"], { "PATH" => "/usr/bin" }, {}, {}, nil)
        .and_return(described_class::Started.new(4242, nil))

      started = described_class.start(kind: :runtime, binary: "/usr/bin/lua", args: ["sandbox.lua"],
                                      env: { "PATH" => "/usr/bin" }, redirects: {})

      expect(started.pid).to eq(4242)
    end
  end

  describe "compiler group setup on the confined fork path" do
    it "establishes the group before account, filter and resource-limit setup" do
      steps = []
      allow(Process).to receive(:setpgid) { |pid, group| steps << [:group, pid, group] }
      allow(described_class).to receive(:redirect) { |*| steps << :redirect }
      allow(described_class).to receive(:resolve).and_return("/controlled/compiler")
      allow(IO).to receive(:sysopen).and_return(3)
      allow(described_class).to receive(:close_others!) { steps << :close_descriptors }
      allow(seccomp).to receive(:exec_plan).and_return(:plan)
      allow(described_class).to receive(:become_the_script_account) { steps << :account }
      allow(landlock).to receive(:restrict_compile!) { |*| steps << :workspace }
      allow(seccomp).to receive(:install!) { |*| steps << :filter }
      allow(Process).to receive(:setrlimit) { |*| steps << :limits }
      allow(seccomp).to receive(:exec_by_name!) { |*| steps << :exec }

      described_class.confine(binary: "compiler", args: [], env: {}, redirects: {},
                              rlimits: { rlimit_fsize: 2048 }, chdir: nil,
                              profile: seccomp::COMPILE, restrict: false, notes: nil, process_group: true,
                              compile_workspace: "/controlled/workspace")

      expect(steps).to eq([[:group, 0, 0], :redirect, :close_descriptors, :account, :workspace, :filter, :limits, :exec])
    end
  end

  # Landlock only ever rode along with a seccomp fork, so a kernel offering it
  # with seccomp down for any reason got none of the filesystem confinement the
  # startup checks say it has.
  describe "a kernel with Landlock but no seccomp filter" do
    before do
      allow(seccomp).to receive_messages(runtime_profile: nil, compile_profile: nil)
      allow(landlock).to receive(:available?).and_return(true)
      allow(landlock).to receive(:compile_available?).and_return(false)
      allow(limits).to receive(:available?).and_return(true)
      # No account, so the transpiler case below reaches the true plain spawn
      # rather than the fork a root container would take.
      allow(Rubotty::Scripting::Isolation).to receive(:account).and_return(nil)
    end

    it "forks for the ruleset rather than falling to the unconfined plain spawn" do
      expect(described_class).to receive(:fork_and_exec)
        .with(hash_including(profile: nil, restrict: true))
        .and_return(described_class::Started.new(4242, nil))
      expect(Process).not_to receive(:spawn)

      expect(described_class.start(kind: :runtime, binary: "/usr/bin/lua").pid).to eq(4242)
    end

    it "allows the explicit trusted fallback when only the runtime ruleset is available" do
      expect(described_class).not_to receive(:fork_and_exec)
      expect(Process).to receive(:spawn).and_return(4242)

      described_class.start(kind: :compile, binary: "teal")
    end
  end

  # The account a child lands in is only as unprivileged as its group list, and
  # setgid and setuid leave that list alone.
  describe "becoming the script account" do
    it "drops every supplementary group before it drops the privilege to do so" do
      order = []
      allow(Rubotty::Scripting::Isolation).to receive(:account).and_return({ uid: 4321, gid: 8765 })
      allow(Process).to receive(:groups=) { |groups| order << [:groups, groups] }
      allow(Process::Sys).to receive(:setgid) { |gid| order << [:setgid, gid] }
      allow(Process::Sys).to receive(:setuid) { |uid| order << [:setuid, uid] }

      described_class.become_the_script_account

      expect(order).to eq([[:groups, []], [:setgid, 8765], [:setuid, 4321]])
    end

    it "leaves this process alone where there is no account to become" do
      allow(Rubotty::Scripting::Isolation).to receive(:account).and_return(nil)

      expect(Process).not_to receive(:groups=)
      described_class.become_the_script_account
    end
  end

  # Everything else about this path needs an account to become, which means
  # root, which neither a developer's machine nor the runner that gates merges
  # is. The exec itself needs no account, so the parts that would strand a
  # child holding the caller's pipe are checked here rather than skipped.
  describe "the fork the plain path takes on its own account" do
    before do
      missing = ["/bin/echo", "/usr/bin/env", "/bin/pwd"].reject { |path| File.executable?(path) }
      skip "nothing here to start a child with: #{missing.join(", ")}" unless missing.empty?
    end

    def exec_through(binary, args, env, chdir: nil)
      reader, writer = IO.pipe
      started = described_class.fork_for_isolation(binary, args, env,
                                                   { in: File::NULL, out: writer, err: File::NULL },
                                                   {}, chdir)
      writer.close
      printed = reader.read
      reader.close
      [printed, Process.waitpid2(started.pid).last]
    end

    it "reaches the exec and writes down the descriptor it was handed" do
      printed, status = exec_through("/bin/echo", ["through the isolation fork"], {})

      expect(status).to be_success
      expect(printed).to eq("through the isolation fork\n")
    end

    it "carries exactly the environment it was handed and nothing else" do
      printed, = exec_through("/usr/bin/env", [], { "ONLY" => "this" })

      expect(printed.split("\n")).to eq(["ONLY=this"])
    end

    it "starts in the directory it was pointed at" do
      printed, = exec_through("/bin/pwd", [], {}, chdir: Dir.tmpdir)

      expect(File.realpath(printed.strip)).to eq(File.realpath(Dir.tmpdir))
    end

    it "establishes a requested compiler group before exec on the account fork path" do
      reader, writer = IO.pipe
      started = described_class.fork_for_isolation(
        RbConfig.ruby, ["-e", "puts Process.getpgrp"], {},
        { in: File::NULL, out: writer, err: File::NULL }, {}, nil, process_group: true
      )
      writer.close
      expect(reader.read.to_i).to eq(started.pid)
      expect(Process.waitpid2(started.pid).last).to be_success
    ensure
      [reader, writer].each { |io| io&.close unless io&.closed? }
    end

    # Nothing reads a note off this path, so a child that never reaches its
    # exec has to die rather than fall back into the caller's own code.
    it "dies rather than returning when the exec never happens" do
      _, status = exec_through("/nonexistent/interpreter", [], {})

      expect(status.exitstatus).to eq(127)
    end
  end

  # Every dialect is named rather than pathed, and a spawn walks PATH for a
  # bare name while an open does not.
  describe "finding the program" do
    it "walks the child's own PATH for a bare name" do
      expect(described_class.resolve("sh", { "PATH" => "/usr/bin:/bin" })).to match(%r{/sh\z})
    end

    it "leaves a path alone" do
      expect(described_class.resolve("/usr/bin/lua5.4", {})).to eq("/usr/bin/lua5.4")
    end

    it "hands back the name it was given where PATH has nothing, so the failure names it" do
      expect(described_class.resolve("nothing-of-that-name", { "PATH" => "/usr/bin" }))
        .to eq("nothing-of-that-name")
    end
  end

  describe "what a deployment has to agree to" do
    it "asks every layer, and takes the first refusal" do
      allow(Rubotty::Scripting::Isolation).to receive_messages(satisfied?: true)
      allow(limits).to receive_messages(satisfied?: false, reason: "no ceiling here")
      allow(seccomp).to receive_messages(satisfied?: false, reason: "no filter here")

      expect(described_class.satisfied?).to be(false)
      expect(described_class.reason).to eq("no ceiling here")
    end

    it "is satisfied only when all of them are" do
      allow(Rubotty::Scripting::Isolation).to receive(:satisfied?).and_return(true)
      allow(limits).to receive(:satisfied?).and_return(true)
      allow(seccomp).to receive(:satisfied?).and_return(true)

      expect(described_class.satisfied?).to be(true)
      expect(described_class.reason).to be_nil
    end

    it "describes each layer separately, since each is turned off separately" do
      expect(described_class.describe.length).to eq(4)
    end
  end

  # Only on Linux, and only where the kernel really takes a filter. Everything
  # here is the whole path a pooled child goes through.
  describe "a child that really is confined", if: RUBY_PLATFORM.include?("linux") do
    # Multicall utilities can choose their operation from the kernel's exec
    # filename, which is /dev/fd/N for the gated exec. A dedicated executable
    # exercises the same native-program boundary as the Lua interpreter.
    before(:context) do
      @probe_dir = Dir.mktmpdir("rubotty-confined-probe", ENV.fetch("RUNNER_TEMP", "/tmp"))
      File.chmod(0o755, @probe_dir)
      @probe = File.join(@probe_dir, "probe")
      prebuilt = ENV["RUBOTTY_CONFINED_PROBE"]
      if prebuilt && !prebuilt.empty?
        # The image harness binds source, digest and ELF architecture for this
        # finite fixture; a production image does not need a C compiler.
        File.open(prebuilt, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |file|
          raise "the prebuilt confinement probe must be a regular executable" unless file.stat.file? && file.stat.executable?

          IO.copy_stream(file, @probe)
        end
        File.chmod(0o755, @probe)
      else
        source = File.expand_path("../fixtures/scripting/confined_probe.c", __dir__)
        output, status = Open3.capture2e("cc", "-Wall", "-Wextra", "-Werror", source, "-o", @probe)
        raise "Could not build the sandbox probe: #{output}" unless status.success?
      end
    end

    after(:context) { FileUtils.remove_entry(@probe_dir) if @probe_dir }

    before do
      skip "this kernel refuses a filter" unless seccomp.available?
    end

    def run(kind, binary, args, input: nil, rlimits: {}, env: { "PATH" => "/usr/bin:/bin" })
      parent_out, child_out = IO.pipe
      child_in, parent_in = IO.pipe
      started = described_class.start(kind: kind, binary: binary, args: args,
                                      env: env, rlimits: rlimits,
                                      chdir: kind == :compile ? @probe_dir : nil,
                                      redirects: { in: child_in, out: child_out, err: File::NULL })
      [child_in, child_out].each(&:close)
      parent_in.write(input) if input
      parent_in.close
      printed = parent_out.read
      parent_out.close
      [printed, Process.waitpid2(started.pid).last, started]
    end

    it "still reads its stdin and writes its stdout" do
      printed, status = run(:runtime, @probe, [], input: "a line through a filtered child\n")

      expect(printed).to eq("a line through a filtered child\n")
      expect(status).to be_success
    end

    it "carries exactly the environment it was handed and nothing else" do
      printed, status = run(:runtime, @probe, ["--environment"])

      expect(status).to be_success
      expect(printed.split("\n")).to eq(["PATH=/usr/bin:/bin"])
    end

    it "holds no descriptor beyond its three pipes" do
      printed, status = run(:runtime, @probe, ["--descriptors"])

      expect(status).to be_success
      expect(printed.split.map(&:to_i)).to eq([0, 1, 2])
    end

    it "preserves the requested program name through the descriptor exec" do
      printed, status = run(:runtime, @probe, ["--program-name"])

      expect(status).to be_success
      expect(printed.strip).to eq(@probe)
    end

    # The kernel keeps a filter across an exec, so what the interpreter is
    # running under is what was installed before it started. Read back out of
    # the exec'd program's own status rather than assumed: 2 is filter mode.
    it "carries the filter into the program it exec'd" do
      printed, status = run(:runtime, @probe, ["/proc/self/status"])

      expect(status).to be_success
      expect(printed).to match(/^Seccomp:\s+2$/)
      expect(printed).to match(/^NoNewPrivs:\s+1$/)
    end

    # A root process can belong to a group that reaches something a script has
    # no business touching, and the account's own uid and gid say nothing about
    # that, so the list itself has to come back empty.
    it "carries no supplementary groups into the account it becomes" do
      skip "not running as an account this can become" if Rubotty::Scripting::Isolation.account.nil?

      printed, status = run(:runtime, @probe, ["/proc/self/status"])

      expect(status).to be_success
      expect(printed).to match(/^Groups:\s*$/)
    end

    it "says why down its own pipe when it never reaches its exec" do
      _, _, started = run(:runtime, "/nonexistent/interpreter", [])

      expect(described_class.failure_note(started.notes)).to match(/ENOENT/)
    end

    # The interpreter's own stderr goes down the same pipe, so a program that
    # starts and then refuses says why rather than dying quietly.
    it "carries what the program itself complained about" do
      _, status, started = run(:runtime, @probe, ["/nonexistent/file"])

      expect(status).not_to be_success
      expect(described_class.failure_note(started.notes)).to match(/nonexistent/)
    end

    # Resolve the reviewed native fixture through a controlled PATH, independent
    # of host utilities and their startup or I/O behavior.
    it "starts a program named rather than pathed" do
      path_dir = File.join(@probe_dir, "path-bin")
      Dir.mkdir(path_dir, 0o755)
      named_probe = File.join(path_dir, "named-probe")
      FileUtils.cp(@probe, named_probe)
      File.chmod(0o755, named_probe)
      env = { "PATH" => path_dir }

      allow(described_class).to receive(:resolve).and_return("named-probe")
      _, unresolved, started = run(:compile, "named-probe", ["--program-name"], env: env)
      note = described_class.failure_note(started.notes)
      started.notes&.close
      expect(unresolved.exitstatus).to eq(127)
      expect(note).to match(/ENOENT/)

      allow(described_class).to receive(:resolve).and_call_original
      printed, status = run(:compile, "named-probe", ["--program-name"], env: env)

      expect(status).to be_success
      expect(printed.strip).to eq("named-probe")
    end
  end

  # The plain path forks on its own account too, with no filter and no ruleset
  # anywhere in the picture, which is the case the fork used to skip entirely.
  describe "the plain path with an account and nothing else to confine into",
           if: RUBY_PLATFORM.include?("linux") do
    before do
      skip "not running as an account this can become" if Rubotty::Scripting::Isolation.account.nil?
      skip "nothing here to start a child with" unless File.executable?("/bin/cat")
      allow(seccomp).to receive_messages(runtime_profile: nil, compile_profile: nil)
      allow(landlock).to receive(:available?).and_return(false)
    end

    it "still drops supplementary groups before the exec" do
      parent_out, child_out = IO.pipe
      started = described_class.start(kind: :runtime, binary: "/bin/cat", args: ["/proc/self/status"],
                                      env: { "PATH" => "/usr/bin:/bin" },
                                      redirects: { in: File::NULL, out: child_out, err: File::NULL })
      child_out.close
      printed = parent_out.read
      parent_out.close

      expect(Process.waitpid2(started.pid).last).to be_success
      expect(printed).to match(/^Groups:\s*$/)
    end
  end
end

# The kernel enforced memory ceiling, and whether this platform applies one.
RSpec.describe Rubotty::Scripting::Limits do
  around do |example|
    described_class.reset!
    example.run
    described_class.reset!
  end

  def with_setting(value)
    previous = ENV.fetch(described_class::SETTING, nil)
    ENV[described_class::SETTING] = value
    yield
  ensure
    ENV[described_class::SETTING] = previous
  end

  # Measured rather than assumed, and the answer is a property of the platform:
  # Darwin maps RLIMIT_AS to something it does not implement.
  it "reports what this platform actually does with rlimit_as" do
    expect(described_class.available?).to be(RUBY_PLATFORM.include?("linux"))
  end

  describe "a platform that will not cap a child" do
    before { allow(described_class).to receive(:available?).and_return(false) }

    it "refuses to run a script rather than running it uncapped" do
      with_setting("required") do
        expect { described_class.require! }.to raise_error(Rubotty::Scripting::Unavailable, /will not cap/)
      end
    end

    it "runs anyway once an operator has said out loud that they accept it" do
      with_setting("optional") { expect { described_class.require! }.not_to raise_error }
    end

    it "says which of the two it is in a line an operator can act on" do
      with_setting("required") { expect(described_class.describe).to match(/Operator scripts are OFF/) }
      with_setting("optional") { expect(described_class.describe).to match(/says that is deliberate/) }
    end
  end
end

# The filesystem tier, which only some kernels offer.
RSpec.describe Rubotty::Scripting::Landlock do
  it "reports honestly where the kernel has none" do
    described_class.reset!
    allow(described_class).to receive(:abi).and_return(nil)

    expect(described_class.available?).to be(false)
    expect(described_class.describe).to match(/no Landlock/)
  ensure
    described_class.reset!
  end

  it "can be turned off without turning the filter off with it" do
    previous = ENV.fetch(described_class::SETTING, nil)
    ENV[described_class::SETTING] = "off"

    expect(described_class.enabled?).to be(false)
  ensure
    ENV[described_class::SETTING] = previous
  end

  # Every access right the kernel knows about has to be handled, or whatever is
  # left unhandled is allowed everywhere.
  it "handles everything its ABI knows about and grants only reading" do
    expect(described_class.handled_fs(1)).to eq(0x1FFF)
    expect(described_class.handled_fs(3)).to eq(0x7FFF)
    expect(described_class.handled_fs(5)).to eq(0xFFFF)
    expect(described_class.granted_fs(1)).to eq(described_class::EXECUTE | described_class::READ_FILE |
                                                described_class::READ_DIR)
  end

  it "asks for the network rights only from the ABI that has them" do
    expect(described_class.handled_net(3)).to eq(0)
    expect(described_class.handled_net(4)).to eq(3)
  end

  # restrict! stubbed out on every one of these, so the classification is
  # tested on its own, on a platform with no real Landlock to enforce it.
  describe "#probe_result" do
    before { allow(described_class).to receive(:restrict!) }

    it "reports 0 when only the write is denied, the correctly restricted case" do
      allow(File).to receive(:read).with("/etc/hostname").and_return("host\n")
      allow(File).to receive(:write).and_raise(Errno::EACCES)

      expect(described_class.probe_result).to eq(0)
    end

    it "reports 2 when the read itself is denied, catching a ruleset that over-restricts" do
      allow(File).to receive(:read).with("/etc/hostname").and_raise(Errno::EACCES)

      expect(described_class.probe_result).to eq(2)
    end

    it "reports 3 when neither is actually restricted" do
      allow(File).to receive(:read).with("/etc/hostname").and_return("host\n")
      allow(File).to receive(:write)

      expect(described_class.probe_result).to eq(3)
    end
  end

  describe "a ruleset that really takes", if: RUBY_PLATFORM.include?("linux") do
    before { skip "this kernel has no usable Landlock" unless described_class.available? }

    it "leaves a restricted child able to read and unable to create" do
      pid = fork do
        $stderr.reopen(File::NULL, "w")
        described_class.restrict!
        begin
          File.write(File.join(Dir.tmpdir, "rubotty-landlock-spec"), "x")
          exit!(1)
        rescue Errno::EACCES
          exit!(File.read("/proc/self/cmdline").nil? ? 2 : 0)
        end
      end

      expect(Process.waitpid2(pid).last.exitstatus).to eq(0)
    end
  end
end
