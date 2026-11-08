# frozen_string_literal: true

require "spec_helper"
require "rubotty/scripting"

# Enough of a classic BPF machine to run what Seccomp::Program assembles: load
# a word out of struct seccomp_data, compare it, mask it, jump, return. A jump
# counted wrong lands here rather than in a chat room.
class SeccompFilterMachine
  LOAD = 0x20
  EQUAL = 0x15
  AT_LEAST = 0x35
  ANY_OF = 0x45
  GO = 0x05
  RETURN = 0x06

  def initialize(program)
    @code = program.to_s.scan(/.{8}/m).map { |instruction| instruction.unpack("SCCL") }
  end

  # What the kernel would do with +data+, as a SECCOMP_RET_* value.
  def run(data)
    counter = 0
    accumulator = 0
    500.times do
      code, jump_true, jump_false, value = @code.fetch(counter)
      counter += 1
      case code
      when LOAD then accumulator = data.fetch(value, 0)
      when EQUAL then counter += accumulator == value ? jump_true : jump_false
      when AT_LEAST then counter += accumulator >= value ? jump_true : jump_false
      when ANY_OF then counter += accumulator.anybits?(value) ? jump_true : jump_false
      when GO then counter += value
      when RETURN then return value
      else raise "the program carries an instruction this machine does not know: #{code}"
      end
    end
    raise "the program never returned"
  end
end

# The system call filter a script's process installs on itself, run mostly through the
# machine above rather than the kernel: it is the only way to test at all on a Mac, which
# has no seccomp, and it can ask what a killed process would do without the slow setup of
# a real one. The kernel side is checked too, at the bottom.
RSpec.describe Rubotty::Scripting::Seccomp do
  let(:allowed) { described_class::SECCOMP_RET_ALLOW }
  let(:killed) { described_class::SECCOMP_RET_KILL_PROCESS }
  let(:refused) { described_class::SECCOMP_RET_ERRNO | described_class::ENOSYS }
  let(:exec_fd) { 9 }

  # Unit examples substitute architectures and interpreter capabilities. Real
  # kernel examples must probe their host instead of inheriting a cached answer.
  around do |example|
    described_class.reset!
    example.run
  ensure
    described_class.reset!
  end

  # struct seccomp_data, as the offsets to words that the machine reads.
  def call_of(name, args: [], architecture: "x86_64", raw: nil)
    number = raw || described_class::SYSCALLS.fetch(architecture).fetch(name)
    data = { 0 => number, 4 => described_class::AUDIT_ARCH.fetch(architecture) }
    args.each_with_index do |value, index|
      data[16 + (index * 8)] = value & 0xFFFF_FFFF
      data[16 + (index * 8) + 4] = value >> 32
    end
    data
  end

  # Pinned to an architecture rather than read off the host, so the same
  # expectations hold on the Mac this is written on and in the x86_64 container
  # that gates merges.
  def machine_for(profile, architecture: "x86_64")
    allow(described_class).to receive(:architecture).and_return(architecture)
    SeccompFilterMachine.new(described_class.program(profile, exec_fd: exec_fd))
  end

  describe "what the runtime filter answers" do
    subject(:filter) { machine_for(described_class::RUNTIME) }

    it "kills every call that could put a byte on the network" do
      %i[socket socketpair connect bind listen accept accept4 sendto sendmsg sendmmsg].each do |name|
        expect(filter.run(call_of(name))).to eq(killed), "expected #{name} to be killed"
      end
    end

    # read and write are not in the table at all, since the filter never names
    # them, so they go in by number the way the kernel would present them.
    it "leaves alone what an interpreter actually does" do
      { "read" => 0, "write" => 1, "mmap" => 9, "brk" => 12 }.each do |name, number|
        expect(filter.run(call_of(nil, raw: number, args: [1, 0, 16]))).to eq(allowed),
                                                                          "expected #{name} to be allowed"
      end
      expect(filter.run(call_of(:fcntl, args: [3, 1, 0]))).to eq(allowed)
    end

    # O_RDONLY is zero, so this is the whole read side of the filesystem: an
    # interpreter reads its chunk and walks package.path and nothing notices.
    it "lets a file be opened for reading" do
      expect(filter.run(call_of(:openat, args: [-100, 0, 0]))).to eq(allowed)
    end

    it "kills a file opened in any mode that can write" do
      { "O_WRONLY" => 0x1, "O_RDWR" => 0x2, "O_TRUNC" => 0o1000,
        "O_WRONLY | O_CREAT" => 0x1 | 0o100 }.each do |name, flags|
        expect(filter.run(call_of(:openat, args: [-100, 0, flags]))).to eq(killed),
                                                                       "expected #{name} to be killed"
      end
    end

    # O_RDONLY | O_CREAT still makes a file, which is why O_CREAT is in the
    # mask rather than only the two access modes.
    it "kills a read only open that would still create the file" do
      expect(filter.run(call_of(:openat, args: [-100, 0, 0o100]))).to eq(killed)
    end

    it "kills openat2 outright, since its flags live behind a pointer" do
      expect(filter.run(call_of(:openat2, args: [-100, 0, 0]))).to eq(killed)
    end

    it "kills the legacy open and creat the same way" do
      expect(filter.run(call_of(:open, args: [0, 0x1]))).to eq(killed)
      expect(filter.run(call_of(:open, args: [0, 0x0]))).to eq(allowed)
      expect(filter.run(call_of(:creat, args: [0, 0o644]))).to eq(killed)
    end

    it "kills execve, which is how a script reaching os.execute would get a shell" do
      expect(filter.run(call_of(:execve))).to eq(killed)
    end

    it "allows the one exec it was built for" do
      expect(filter.run(call_of(:execveat, args: [exec_fd, 0, 0, 0, 0x1000]))).to eq(allowed)
    end

    it "kills an exec through any other descriptor" do
      expect(filter.run(call_of(:execveat, args: [exec_fd + 1, 0, 0, 0, 0x1000]))).to eq(killed)
      expect(filter.run(call_of(:execveat, args: [0, 0, 0, 0, 0x1000]))).to eq(killed)
    end

    it "kills an exec that names a path rather than the descriptor" do
      expect(filter.run(call_of(:execveat, args: [exec_fd, 0, 0, 0, 0]))).to eq(killed)
    end

    # The descriptor is compared whole, so a value carrying the right low half
    # and rubbish above it is not the descriptor.
    it "kills an exec whose descriptor only matches in its low half" do
      expect(filter.run(call_of(:execveat, args: [(1 << 32) | exec_fd, 0, 0, 0, 0x1000]))).to eq(killed)
    end
  end

  # A ring takes connect, openat and write as submission entries the kernel
  # performs itself, so nothing above is ever entered and both the network
  # denial and the write denial come off a filter that never named it.
  describe "io_uring" do
    it "refuses every one of its three calls on the runtime filter" do
      filter = machine_for(described_class::RUNTIME)

      described_class::RING.each do |name|
        expect(filter.run(call_of(name))).to eq(refused), "expected #{name} to be refused"
      end
    end

    # Denied on the transpiler's profile too: that one only ever promised no
    # network, and a ring is a way to have one.
    it "is refused on every profile there is, weakest included" do
      described_class::PROFILES.each_key do |profile|
        filter = machine_for(profile)

        expect(filter.run(call_of(:io_uring_setup))).to eq(refused), "expected #{profile} to refuse a ring"
      end
    end

    it "is refused at its own numbers under aarch64" do
      filter = machine_for(described_class::RUNTIME_OPEN_FILES, architecture: "aarch64")

      expect(filter.run(call_of(:io_uring_setup, architecture: "aarch64"))).to eq(refused)
    end

    # An answer rather than a death: libuv asks for a ring as it starts and
    # takes ENOSYS for no, where a killed process takes the transpiler with it.
    it "answers ENOSYS rather than killing the process for asking" do
      expect(refused).not_to eq(killed)
      expect(described_class::ENOSYS).to eq(38)
    end
  end

  describe "what the filter does with something it was not written for" do
    subject(:filter) { machine_for(described_class::RUNTIME) }

    it "kills anything arriving under another architecture" do
      data = call_of(nil, raw: 0).merge(4 => described_class::AUDIT_ARCH.fetch("aarch64"))

      expect(filter.run(data)).to eq(killed)
    end

    # An x32 task reports AUDIT_ARCH_X86_64 and numbers its calls from another
    # table, so every number checked above would mean something else.
    it "kills an x32 call, whose numbers mean something else" do
      expect(filter.run(call_of(nil, raw: 0x4000_0000))).to eq(killed)
    end
  end

  describe "the same filter under aarch64" do
    subject(:filter) { machine_for(described_class::RUNTIME, architecture: "aarch64") }

    it "kills the network calls at their own numbers" do
      expect(filter.run(call_of(:socket, architecture: "aarch64"))).to eq(killed)
      expect(filter.run(call_of(:connect, architecture: "aarch64"))).to eq(killed)
    end

    # 41 is socket on x86_64 and something else here, which is the whole reason
    # the architecture is checked before any number is.
    it "does not read x86_64 numbers into it" do
      expect(filter.run(call_of(nil, architecture: "aarch64", raw: 41))).to eq(allowed)
    end
  end

  describe "what a transpiler gets" do
    subject(:filter) { machine_for(described_class::COMPILE) }

    it "still cannot reach the network" do
      expect(filter.run(call_of(:socket))).to eq(killed)
      expect(filter.run(call_of(:connect))).to eq(killed)
    end

    # Teal writes its output next to its input rather than to stdout, and every
    # dialect is a #! script the kernel starts by name.
    it "keeps the file writing and the exec it needs" do
      expect(filter.run(call_of(:openat, args: [-100, 0, 0x1 | 0o100]))).to eq(allowed)
      expect(filter.run(call_of(:execve))).to eq(allowed)
    end

    %w[x86_64 aarch64].each do |architecture|
      it "denies post-setup group changes and filesystem metadata mutations on #{architecture}" do
        filter = machine_for(described_class::COMPILE, architecture: architecture)
        numbers = described_class::SYSCALLS.fetch(architecture)
        described_class::COMPILE_DENIED.each do |name|
          next unless numbers.key?(name)

          expect(filter.run(call_of(name, architecture: architecture))).to eq(killed), name.to_s
        end
      end

      it "denies process creation and peer changes while keeping self limits on #{architecture}" do
        filter = machine_for(described_class::COMPILE, architecture: architecture)
        expect(filter.run(call_of(:clone, architecture: architecture, args: [17]))).to eq(killed)
        expect(filter.run(call_of(:clone, architecture: architecture, args: [0x10000000 | 17]))).to eq(killed)
        expect(filter.run(call_of(:clone, architecture: architecture, args: [0x8000 | 17]))).to eq(killed)
        expect(filter.run(call_of(:clone3, architecture: architecture))).to eq(killed)
        expect(filter.run(call_of(:prlimit64, architecture: architecture, args: [0]))).to eq(allowed)
        expect(filter.run(call_of(:prlimit64, architecture: architecture, args: [42]))).to eq(killed)
        expect(filter.run(call_of(:prlimit64, architecture: architecture, args: [1 << 32]))).to eq(killed)
        expect(filter.run(call_of(:execve, architecture: architecture))).to eq(allowed)
      end

      it "allows only terminal/pipe read queries rather than generic file ioctls on #{architecture}" do
        filter = machine_for(described_class::COMPILE, architecture: architecture)
        [0x5401, 0x5413, 0x541B].each do |request|
          expect(filter.run(call_of(:ioctl, architecture: architecture, args: [1, request]))).to eq(allowed)
          expect(filter.run(call_of(:ioctl, architecture: architecture, args: [1, (1 << 32) | request]))).to eq(killed)
        end
        expect(filter.run(call_of(:ioctl, architecture: architecture, args: [1, 0x40049409]))).to eq(killed)
      end
    end

    {
      "x86_64" => [56, 57, 58, 435, 285, 319, 447, 29, 64, 68, 141, 142, 144, 203, 251, 314],
      "aarch64" => [220, 435, 47, 279, 447, 194, 190, 186, 140, 118, 119, 122, 30, 274]
    }.each do |architecture, calls|
      it "blocks the primary-UAPI process/allocation/priority numbers only for compilation on #{architecture}" do
        compile = machine_for(described_class::COMPILE, architecture: architecture)
        runtime = machine_for(described_class::RUNTIME_OPEN_FILES, architecture: architecture)
        calls.each do |number|
          data = call_of(nil, raw: number, architecture: architecture)
          expect(compile.run(data)).to eq(killed), "compile syscall #{number}"
          expect(runtime.run(data)).to eq(allowed), "runtime syscall #{number} changed"
        end
      end
    end
  end

  describe "the middle tiers" do
    it "gives up the exec gate and keeps everything else" do
      filter = machine_for(described_class::RUNTIME_OPEN_EXEC)

      expect(filter.run(call_of(:execve))).to eq(allowed)
      expect(filter.run(call_of(:socket))).to eq(killed)
      expect(filter.run(call_of(:openat, args: [-100, 0, 0x1]))).to eq(killed)
    end

    it "gives up the write denial too, and still keeps the network out" do
      filter = machine_for(described_class::RUNTIME_OPEN_FILES)

      expect(filter.run(call_of(:openat, args: [-100, 0, 0x1]))).to eq(allowed)
      expect(filter.run(call_of(:socket))).to eq(killed)
    end
  end

  # required? is satisfied by any tier at all, which is the deliberate part.
  # What was missing is anything telling an operator which one they got.
  describe "the line an operator reads about the tier in force" do
    it "spells out what the weakest tier gave up rather than hinting at it" do
      allow(described_class).to receive_messages(available?: true,
                                                 runtime_profile: described_class::RUNTIME_OPEN_FILES)

      expect(described_class.describe).to include("start another program and open a file for writing")
      expect(described_class.reduced_tier).to eq(described_class::RUNTIME_OPEN_FILES)
    end

    it "still says the exec gate is the only thing the middle tier gave up" do
      allow(described_class).to receive_messages(available?: true,
                                                 runtime_profile: described_class::RUNTIME_OPEN_EXEC)

      expect(described_class.describe).to include("cannot open a file for writing")
      expect(described_class.reduced_tier).to eq(described_class::RUNTIME_OPEN_EXEC)
    end

    it "has no tier to report where the whole filter holds" do
      allow(described_class).to receive_messages(available?: true, runtime_profile: described_class::RUNTIME)

      expect(described_class.reduced_tier).to be_nil
    end

    # No filter at all is a separate line already, and reporting a tier here
    # would name one that is not in force.
    it "has no tier to report where there is no filter at all" do
      allow(described_class).to receive_messages(available?: false,
                                                 runtime_profile: described_class::RUNTIME_OPEN_FILES)

      expect(described_class.reduced_tier).to be_nil
    end
  end

  describe "assembling the program" do
    before { allow(described_class).to receive(:architecture).and_return("x86_64") }

    it "refuses to build a gated profile with no descriptor to gate" do
      expect { described_class.program(described_class::RUNTIME) }.to raise_error(ArgumentError, /descriptor/)
    end

    it "packs each instruction into the eight bytes the kernel reads" do
      program = described_class.program(described_class::COMPILE)

      expect(program.to_s.bytesize).to eq(program.length * 8)
    end
  end

  describe "a platform with no filter to install" do
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

    before { allow(described_class).to receive(:available?).and_return(false) }

    it "refuses to run a script rather than running it unfiltered" do
      with_setting("required") do
        expect { described_class.require! }.to raise_error(Rubotty::Scripting::Unavailable, /cannot be filtered/)
      end
    end

    it "runs anyway once an operator has said out loud that they accept it" do
      with_setting("optional") { expect { described_class.require! }.not_to raise_error }
    end

    it "says so in a way an operator can act on" do
      with_setting("required") { expect(described_class.describe).to match(/Operator scripts are OFF/) }
      with_setting("optional") { expect(described_class.describe).to match(/says that is deliberate/) }
    end

    it "counts anything it does not recognise as required, since refusing is the safe guess" do
      with_setting("whatever") { expect(described_class.required?).to be(true) }
    end
  end

  describe "the interpreter probe" do
    around do |example|
      described_class.reset!
      example.run
      described_class.reset!
    end

    # The strongest tier a #! interpreter can have is the one without the gate,
    # because execveat with an empty path cannot carry a script at all.
    it "does not offer the exec gate to a #! interpreter" do
      allow(described_class).to receive_messages(script?: true, interpreter: "/bin/sh")

      expect(described_class.runs?(described_class::RUNTIME)).to be(false)
    end

    it "reports no filter at all where there is nothing to probe with" do
      allow(described_class).to receive(:interpreter).and_return(nil)

      expect(described_class.runtime_profile).to be_nil
      expect(described_class.available?).to be(false)
    end
  end

  # A probe that fails for any reason at all reads as "no filter here," and a deployment
  # that opted out then runs everything unfiltered without a word. Where the kernel does
  # enforce a filter and there is an interpreter to run, one of the tiers has to hold, and
  # this says so out loud rather than letting the whole thing turn itself off quietly.
  describe "the tier it settles on", if: RUBY_PLATFORM.include?("linux") do
    before do
      skip "this kernel refuses a filter at all" unless described_class.enforcing?
      skip "no Lua interpreter on PATH" if Rubotty::Scripting::Child.find_binary.nil?
    end

    it "finds one for the interpreter this machine actually has" do
      expect(described_class.runtime_profile).not_to be_nil
      expect(described_class.available?).to be(true)
    end
  end

  # Everything above says what the program means. This says the kernel agrees,
  # and it is the only part that cannot run on a Mac.
  describe "against a real kernel", if: RUBY_PLATFORM.include?("linux") do
    before { skip "this kernel refuses a filter" unless described_class.available? }

    it "kills a child that reaches for a socket" do
      status = described_class.probe do
        described_class.install!(described_class::COMPILE)
        syscall(described_class.number(:socket), 2, 1, 0)
      end

      expect(status).to be_signaled
      expect(status.termsig).to eq(described_class::SIGSYS)
    end

    it "kills a child that opens a file for writing" do
      status = described_class.probe do
        described_class.install!(described_class::RUNTIME, exec_fd: 3)
        File.open(File.join(Dir.tmpdir, "rubotty-seccomp-spec"), File::WRONLY | File::CREAT, 0o600)
      end

      expect(status).to be_signaled
      expect(status.termsig).to eq(described_class::SIGSYS)
    end

    it "leaves a child that only reads alone" do
      status = described_class.probe do
        described_class.install!(described_class::RUNTIME, exec_fd: 3)
        exit!(File.read("/proc/self/cmdline").empty? ? 1 : 0)
      end

      expect(status.exitstatus).to eq(0)
    end

    it "still carries a real program through the exec it leaves open" do
      reader, writer = IO.pipe
      status = described_class.probe(writer) do
        reader.close
        fd = IO.sysopen("/bin/cat", File::RDONLY)
        plan = described_class.exec_plan(fd, "/bin/cat", ["/proc/self/comm"], {})
        described_class.install!(described_class::RUNTIME_OPEN_EXEC, exec_fd: fd)
        described_class.exec_by_name!(plan)
      end
      writer.close
      printed = reader.read
      reader.close

      expect(status.exitstatus).to eq(0)
      expect(printed.strip).to eq("cat")
    end
  end
end
