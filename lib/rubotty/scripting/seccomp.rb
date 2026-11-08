# frozen_string_literal: true

require "rbconfig"
require "fiddle"
require "fiddle/struct"

module Rubotty
  module Scripting
    # The syscall filter a script's process puts on ITSELF between fork and
    # exec. Denies the network outright (socket, connect, bind, listen,
    # accept, accept4, socketpair, sends), denies io_uring with it, and denies
    # exec and file writes except for a save-time transpiler ({COMPILE}).
    # Exec can only happen through one open, close-on-exec descriptor via
    # execveat/AT_EMPTY_PATH, with execve denied outright, though native code
    # could still reopen that descriptor. A violation kills the whole process
    # (SECCOMP_RET_KILL_PROCESS); {Child} reads SIGSYS off the exit status.
    module Seccomp
      # Whether a deployment refuses to run scripts it cannot filter.
      # "required" is the default; "optional" is an operator saying out loud
      # that they accept scripts running with no filter on them.
      SETTING = "RUBOTTY_SCRIPT_SECCOMP"
      REQUIRED = "required"
      OPTIONAL = "optional"

      # The pooled Lua child: no network, no exec except the one gated
      # descriptor, no opening a file for writing.
      RUNTIME = :runtime

      # The same without the exec gate, for an interpreter that has to start
      # something (a #! wrapper is the usual reason).
      RUNTIME_OPEN_EXEC = :runtime_open_exec

      # The network denial on its own, which is what an interpreter gets where
      # it turns out to need a file open for writing.
      RUNTIME_OPEN_FILES = :runtime_open_files

      # A save-time transpiler: it can overwrite its sole declared output and
      # exec an interpreter, but cannot create files, children or threads, mutate
      # filesystem metadata, or change peer scheduling after trusted setup.
      COMPILE = :compile

      PROFILES = {
        RUNTIME => { exec: :gated, writes: :denied },
        RUNTIME_OPEN_EXEC => { exec: :open, writes: :denied },
        RUNTIME_OPEN_FILES => { exec: :open, writes: :allowed },
        COMPILE => { exec: :open, writes: :allowed }
      }.freeze

      # Strongest first: the probe takes the first one the real interpreter
      # actually survives, so a deny list that costs it something it turns
      # out to need costs the exec gate or the write denial rather than the
      # whole filter. Every tier denies the network, which is the half worth having.
      TIERS = [RUNTIME, RUNTIME_OPEN_EXEC, RUNTIME_OPEN_FILES].freeze

      # Numbers, not names, are what a filter compares against, and they differ
      # per architecture. Only the two this deploys to are here; anywhere else
      # reports unsupported rather than guessing.
      SYSCALLS = {
        "x86_64" => {
          prctl: 157, seccomp: 317, socket: 41, socketpair: 53, connect: 42,
          bind: 49, listen: 50, accept: 43, accept4: 288, sendto: 44,
          sendmsg: 46, sendmmsg: 307, execve: 59, execveat: 322, open: 2,
          openat: 257, openat2: 437, creat: 85, fcntl: 72,
          io_uring_setup: 425, io_uring_enter: 426, io_uring_register: 427,
          setpgid: 109, setsid: 112, chmod: 90, fchmod: 91, chown: 92, fchown: 93, lchown: 94,
          fchmodat: 268, fchownat: 260, utime: 132, utimes: 235, futimesat: 261, utimensat: 280,
          setxattr: 188, lsetxattr: 189, fsetxattr: 190, removexattr: 197, lremovexattr: 198, fremovexattr: 199,
          unshare: 272, setns: 308, clone: 56, clone3: 435, prlimit64: 302,
          mount: 165, umount2: 166, pivot_root: 155, chroot: 161, open_by_handle_at: 304,
          open_tree: 428, move_mount: 429, fsopen: 430, fsconfig: 431, fsmount: 432, fspick: 433,
          mount_setattr: 442, fchmodat2: 452, setxattrat: 463, removexattrat: 466,
          open_tree_attr: 467, file_setattr: 469, fchroot: 472,
          fork: 57, vfork: 58, fallocate: 285, ioctl: 16,
          memfd_create: 319, memfd_secret: 447, shmget: 29, semget: 64, msgget: 68,
          setpriority: 141, sched_setparam: 142, sched_setscheduler: 144,
          sched_setaffinity: 203, ioprio_set: 251, sched_setattr: 314
        }.freeze,
        "aarch64" => {
          prctl: 167, seccomp: 277, socket: 198, socketpair: 199, connect: 203,
          bind: 200, listen: 201, accept: 202, accept4: 242, sendto: 206,
          sendmsg: 211, sendmmsg: 269, execve: 221, execveat: 281,
          openat: 56, openat2: 437, fcntl: 25,
          io_uring_setup: 425, io_uring_enter: 426, io_uring_register: 427,
          setpgid: 154, setsid: 157, fchmod: 52, fchmodat: 53, fchown: 55, fchownat: 54, utimensat: 88,
          setxattr: 5, lsetxattr: 6, fsetxattr: 7, removexattr: 14, lremovexattr: 15, fremovexattr: 16,
          unshare: 97, setns: 268, clone: 220, clone3: 435, prlimit64: 261,
          mount: 40, umount2: 39, pivot_root: 41, chroot: 51, open_by_handle_at: 265,
          open_tree: 428, move_mount: 429, fsopen: 430, fsconfig: 431, fsmount: 432, fspick: 433,
          mount_setattr: 442, fchmodat2: 452, setxattrat: 463, removexattrat: 466,
          open_tree_attr: 467, file_setattr: 469, fchroot: 472,
          fallocate: 47, ioctl: 29, memfd_create: 279, memfd_secret: 447,
          shmget: 194, semget: 190, msgget: 186, setpriority: 140,
          sched_setparam: 118, sched_setscheduler: 119, sched_setaffinity: 122,
          ioprio_set: 30, sched_setattr: 274
        }.freeze
      }.freeze

      # AUDIT_ARCH_*, which the filter checks first: the numbers above mean
      # something else under any other one.
      AUDIT_ARCH = { "x86_64" => 0xC000_003E, "aarch64" => 0xC000_00B7 }.freeze

      # An x32 task reports AUDIT_ARCH_X86_64 and numbers its calls from a
      # different table, with this bit set.
      X32_SYSCALL_BIT = 0x4000_0000

      # Every network call the deny list covers, in the order they are checked.
      NETWORK = %i[socket socketpair connect bind listen accept accept4 sendto sendmsg sendmmsg].freeze

      # io_uring, denied on every profile: a ring carries connect, openat and
      # write as submission entries the kernel performs on its own, so none of
      # the numbers above are ever reached and both the network denial and the
      # write denial come off. Answered with an error rather than a kill, since
      # a runtime asking for a ring at startup falls back when told there is
      # none and dies on the spot when the process is killed for asking.
      RING = %i[io_uring_setup io_uring_enter io_uring_register].freeze

      # Compiler-only protections for metadata not mediated by Landlock, group
      # escape after setup, and namespace changes. Numbers come from Linux's
      # syscall_64.tbl and asm-generic/unistd.h UAPI tables, including new variants.
      COMPILE_DENIED = %i[
        setpgid setsid chmod fchmod fchmodat fchmodat2 chown fchown lchown fchownat
        utime utimes futimesat utimensat setxattr lsetxattr fsetxattr removexattr lremovexattr fremovexattr
        setxattrat removexattrat file_setattr unshare setns mount umount2 pivot_root chroot fchroot
        open_by_handle_at open_tree move_mount fsopen fsconfig fsmount fspick mount_setattr open_tree_attr
        fork vfork clone clone3 fallocate memfd_create memfd_secret shmget semget msgget
        setpriority sched_setparam sched_setscheduler sched_setaffinity ioprio_set sched_setattr
      ].freeze
      # TCGETS, TIOCGWINSZ and FIONREAD: harmless terminal/pipe queries used by
      # interpreters. Generic file ioctls can allocate outside the file-size cap.
      COMPILE_IOCTL_READS = [0x5401, 0x5413, 0x541B].freeze

      # O_WRONLY | O_RDWR | O_CREAT | O_TRUNC. O_CREAT is in there because
      # O_RDONLY | O_CREAT still makes a file.
      WRITE_FLAGS = 0x1 | 0x2 | 0o100 | 0o1000

      # struct seccomp_data: int nr, __u32 arch, __u64 instruction_pointer,
      # __u64 args[6].
      NR_OFFSET = 0
      ARCH_OFFSET = 4
      ARGS_OFFSET = 16

      SECCOMP_SET_MODE_FILTER = 1
      SECCOMP_RET_KILL_PROCESS = 0x8000_0000
      SECCOMP_RET_ALLOW = 0x7FFF_0000

      # Fail the call instead of killing the caller, with the errno in the low
      # sixteen bits. ENOSYS is 38 on both architectures here and reads as a
      # kernel that never had the call, which is what a fallback path looks for.
      SECCOMP_RET_ERRNO = 0x0005_0000
      ENOSYS = 38

      PR_SET_NO_NEW_PRIVS = 38
      PR_SET_SECCOMP = 22
      SECCOMP_MODE_FILTER = 2

      AT_EMPTY_PATH = 0x1000

      # struct sock_fprog { unsigned short len; struct sock_filter *filter; },
      # whose six bytes of padding Fiddle works out rather than this file.
      SOCK_FPROG = Fiddle::CStructBuilder.create(
        Fiddle::CStruct, [Fiddle::TYPE_SHORT, Fiddle::TYPE_VOIDP], %w[length instructions]
      )

      # What the kernel kills with, and so what {Child} reads back to tell a
      # filtered death from any other one.
      SIGSYS = Signal.list.fetch("SYS", 31)

      # What the exec probe has its child print, so a probe that passed is told
      # apart from a child that exited 0 without ever running.
      PROBE_TOKEN = "rubotty-seccomp-probe"

      # A classic BPF program, assembled against labels so a jump target is a
      # name rather than a hand counted offset. Every jump is forward, which is
      # all classic BPF allows, so the two returns sit at the end.
      class Program
        LOAD = 0x20         # BPF_LD | BPF_W | BPF_ABS
        EQUAL = 0x15        # BPF_JMP | BPF_JEQ | BPF_K
        AT_LEAST = 0x35     # BPF_JMP | BPF_JGE | BPF_K
        ANY_OF = 0x45       # BPF_JMP | BPF_JSET | BPF_K
        GO = 0x05           # BPF_JMP | BPF_JA
        RETURN = 0x06       # BPF_RET | BPF_K

        def initialize
          @code = []
          @labels = {}
        end

        def load(offset) = add(LOAD, nil, nil, offset)
        def equal(value, then_go: nil, else_go: nil) = add(EQUAL, then_go, else_go, value)
        def at_least(value, then_go: nil, else_go: nil) = add(AT_LEAST, then_go, else_go, value)
        def any_of(mask, then_go: nil, else_go: nil) = add(ANY_OF, then_go, else_go, mask)
        def go(name) = add(GO, nil, nil, name)
        def ret(value) = add(RETURN, nil, nil, value)
        def label(name) = @labels[name] = @code.length

        # How many instructions there are, which is what sock_fprog.len wants.
        def length = @code.length

        # The program as the kernel reads it: sock_filter is
        # { __u16 code; __u8 jt; __u8 jf; __u32 k; }, native order.
        def to_s
          @code.each_with_index.map do |(code, jt, jf, k), index|
            [code, offset(jt, index), offset(jf, index), value(k, index)].pack("SCCL")
          end.join
        end

        private

        def add(code, jt, jf, k) = @code << [code, jt, jf, k]

        # A label resolves to the distance from the instruction after this one,
        # which is what a BPF jump counts.
        def offset(target, index)
          return 0 if target.nil?

          @labels.fetch(target) - (index + 1)
        end

        # Only an unconditional jump carries its target in k.
        def value(k, index) = k.is_a?(Symbol) ? offset(k, index) : k
      end

      module_function

      # The architecture whose numbers apply here, or nil where none do.
      def architecture
        cpu = RbConfig::CONFIG["host_cpu"]
        return "x86_64" if cpu == "x86_64"
        return "aarch64" if %w[aarch64 arm64].include?(cpu)

        nil
      end

      def linux? = RbConfig::CONFIG["host_os"].include?("linux")

      # Whether a filter could exist here at all, before asking whether one
      # actually holds.
      def supported? = linux? && !architecture.nil?

      # Whether a filter really installs, really kills, and still leaves an
      # interpreter able to run. Both halves are measured rather than assumed,
      # in throwaway children that do the real thing.
      def available?
        return @available if defined?(@available)

        @available = supported? && enforcing? && !runtime_profile.nil?
      end

      # The strongest tier the interpreter actually survives here, or nil where
      # it survives none.
      def runtime_profile
        return @runtime_profile if defined?(@runtime_profile)

        @runtime_profile = supported? ? TIERS.find { |tier| runs?(tier) } : nil
      end

      # Whether the exec gate is part of what is in force, which is the part
      # most likely to have been given up.
      def exec_gate? = runtime_profile == RUNTIME

      # The tier in force where the probe settled below {RUNTIME}, so a boot
      # can name it. Nil where the whole filter holds, and nil where there is
      # no filter at all, which {reason} already covers.
      def reduced_tier = available? && runtime_profile != RUNTIME ? runtime_profile : nil

      # Which profile a save-time transpiler gets, or nil when it gets none.
      def compile_profile = available? ? COMPILE : nil

      # What the operator asked for. Anything unrecognised counts as
      # {REQUIRED}, since refusing is the safe direction to guess in.
      def setting(env = ENV) = env[SETTING].to_s.strip.downcase == OPTIONAL ? OPTIONAL : REQUIRED

      def required?(env = ENV) = setting(env) == REQUIRED

      # Whether this deployment is in a state it agreed to run scripts in.
      def satisfied?(env = ENV) = available? || !required?(env)

      # Raised rather than logged, for the same reason {Isolation} raises: a
      # script running unfiltered on a deployment that asked for a filter is
      # the thing this refuses to do quietly.
      def require!(env = ENV)
        return if satisfied?(env)

        raise Unavailable,
              "operator scripts are turned off because they cannot be filtered here: #{reason}. " \
              "Set #{SETTING}=#{OPTIONAL} to run them with no system call filter instead."
      end

      # Why there is no filter to install. Present whenever {available?} is
      # false and worth showing an operator either way.
      def reason
        return nil if available?
        return "this is #{RbConfig::CONFIG["host_os"]}, which has no seccomp" unless linux?
        return "seccomp filters here are written for x86_64 and aarch64 only" if architecture.nil?
        return "no interpreter here starts with a filter on it" if enforcing?

        "the kernel refused a filter this process installed on itself"
      end

      # One line about what a script's process is filtered down to, for the
      # startup checks.
      def describe(env = ENV)
        return unfiltered(env) unless available?

        "Operator scripts run behind a system call filter: a script's process cannot open a socket " \
          "or set up an io_uring ring, #{tier_description}."
      end

      # What the tier in force costs beyond the network, since the strongest
      # one is not always the one an interpreter survives. The weakest tier
      # names what it gave up rather than hinting at it: an operator reading
      # this is being told their scripts can exec and write.
      def tier_description
        case runtime_profile
        when RUNTIME then "cannot start another program, and cannot open a file for writing"
        when RUNTIME_OPEN_EXEC then "and cannot open a file for writing (this interpreter needs its own exec)"
        else "but can both start another program and open a file for writing, which is all this " \
             "interpreter left room for"
        end
      end

      # Forget every probe. Only tests need this.
      def reset!
        remove_instance_variable(:@available) if defined?(@available)
        remove_instance_variable(:@enforcing) if defined?(@enforcing)
        remove_instance_variable(:@runtime_profile) if defined?(@runtime_profile)
      end

      # Install the filter on THIS process. Only ever called in a forked child,
      # with the descriptor the interpreter is about to be exec'd from.
      def install!(profile, exec_fd: nil)
        code = program(profile, exec_fd: exec_fd)
        no_new_privs!
        apply(code)
      end

      # Everything the exec needs, worked out ahead of it: +env+ becomes the
      # whole environment (what the caller left out stays out), and this is
      # split from {exec!} because the child caps its own address space
      # right before exec and must not allocate after that, so every string
      # the kernel reads is built here first. +called+ is the name the
      # program finds in argv[0] rather than the path it was found at, so an
      # operator reading its output sees the name they know.
      def exec_plan(fd, path, args, env, called: nil)
        { through: number(:execveat), by_name: number(:execve), fd: fd,
          empty: Libc.string(""), name: Libc.string(path),
          argv: Libc.vector([called || path, *args]),
          envp: Libc.vector(env.map { |key, value| "#{key}=#{value}" }) }
      end

      # Exec the only way the gate allows, through an already open descriptor
      # with an empty path. Returns only when the exec failed, since a
      # successful one never comes back.
      def exec!(plan)
        Libc.syscall(plan[:through], plan[:fd], plan[:empty], plan[:argv], plan[:envp], AT_EMPTY_PATH)
      end

      # Exec by name, for a child whose profile leaves execve alone. What a
      # spawn always did, and the only thing that works on a #! script.
      def exec_by_name!(plan)
        Libc.syscall(plan[:by_name], plan[:name], plan[:argv], plan[:envp])
      end

      # Whether +binary+ is a #! script rather than something the kernel can
      # load on its own: the gate can't carry one, since `execveat` with
      # AT_EMPTY_PATH hands the interpreter /dev/fd/N to read from, and the
      # descriptor is closed on exec by then, so the kernel answers ENOENT.
      # Every transpiler luarocks installs is a #! script, and a
      # distribution can package the interpreter as one too, so this is checked rather than assumed.
      def script?(binary)
        File.binread(binary, 2) == "#!"
      rescue SystemCallError
        false
      end

      # The filter itself, as the bytes the kernel reads.
      def program(profile, exec_fd: nil)
        rules = PROFILES.fetch(profile)
        numbers = SYSCALLS.fetch(architecture)
        code = Program.new

        code.load(ARCH_OFFSET)
        code.equal(AUDIT_ARCH.fetch(architecture), else_go: :kill)
        code.load(NR_OFFSET)
        code.at_least(X32_SYSCALL_BIT, then_go: :kill) if architecture == "x86_64"

        NETWORK.each { |name| code.equal(numbers.fetch(name), then_go: :kill) }
        RING.each { |name| code.equal(numbers.fetch(name), then_go: :refuse) }
        if profile == COMPILE
          COMPILE_DENIED.each { |name| code.equal(numbers[name], then_go: :kill) if numbers.key?(name) }
          code.equal(numbers.fetch(:ioctl), then_go: :compile_ioctl)
          code.equal(numbers.fetch(:prlimit64), then_go: :compile_prlimit)
        end
        gate_exec(code, numbers) if rules[:exec] == :gated
        gate_writes(code, numbers) if rules[:writes] == :denied
        code.go(:allow)

        exec_check(code, exec_fd) if rules[:exec] == :gated
        write_check(code, numbers) if rules[:writes] == :denied
        if profile == COMPILE
          code.label(:compile_ioctl)
          code.load(argument(1) + 4)
          code.equal(0, else_go: :kill)
          code.load(argument(1))
          COMPILE_IOCTL_READS.each { |request| code.equal(request, then_go: :allow) }
          code.go(:kill)
          code.label(:compile_prlimit)
          code.load(ARGS_OFFSET)
          code.equal(0, else_go: :kill)
          code.load(ARGS_OFFSET + 4)
          code.equal(0, else_go: :kill)
          code.go(:allow)
        end

        code.label(:allow)
        code.ret(SECCOMP_RET_ALLOW)
        code.label(:kill)
        code.ret(SECCOMP_RET_KILL_PROCESS)
        code.label(:refuse)
        code.ret(SECCOMP_RET_ERRNO | ENOSYS)
        code
      end

      def gate_exec(code, numbers)
        code.equal(numbers.fetch(:execve), then_go: :kill)
        code.equal(numbers.fetch(:execveat), then_go: :exec_check)
      end

      def gate_writes(code, numbers)
        code.equal(numbers.fetch(:openat), then_go: :openat_check)
        code.equal(numbers.fetch(:open), then_go: :open_check) if numbers.key?(:open)
        code.equal(numbers.fetch(:creat), then_go: :kill) if numbers.key?(:creat)
        code.equal(numbers.fetch(:openat2), then_go: :kill)
      end

      # One descriptor, one flag. openat2 is killed outright above rather than
      # checked, since its flags live behind a pointer a filter cannot read.
      def exec_check(code, exec_fd)
        raise ArgumentError, "the gated exec profile needs the descriptor it is gating" if exec_fd.nil?

        code.label(:exec_check)
        code.load(argument(0))
        code.equal(exec_fd, else_go: :kill)
        code.load(argument(0) + 4)
        code.equal(0, else_go: :kill)
        code.load(argument(4))
        code.equal(AT_EMPTY_PATH, then_go: :allow, else_go: :kill)
      end

      def write_check(code, numbers)
        code.label(:openat_check)
        code.load(argument(2))
        code.any_of(WRITE_FLAGS, then_go: :kill, else_go: :allow)
        return unless numbers.key?(:open)

        code.label(:open_check)
        code.load(argument(1))
        code.any_of(WRITE_FLAGS, then_go: :kill, else_go: :allow)
      end

      # Where the low half of one argument sits in struct seccomp_data.
      def argument(index) = ARGS_OFFSET + (index * 8)

      def number(name) = SYSCALLS.fetch(architecture).fetch(name)

      # Nothing this process later does may hand it more than it has now, which
      # is what makes the filter installable without privilege.
      def no_new_privs!
        Libc.syscall(number(:prctl), PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0)
      end

      # Hand the assembled program to the kernel in a {SOCK_FPROG} pointing at
      # it. The instruction bytes stay in a local while the kernel reads them,
      # since the struct field carries the address alone.
      def apply(code)
        instructions = code.to_s
        program = SOCK_FPROG.malloc(Fiddle::RUBY_FREE)
        program.length = code.length
        program.instructions = Libc.pointer(instructions)
        begin
          Libc.syscall(number(:seccomp), SECCOMP_SET_MODE_FILTER, 0, program.to_ptr)
        rescue SystemCallError
          # Older kernels, and any container profile that refuses the seccomp
          # call itself, still take the prctl spelling of the same thing.
          Libc.syscall(number(:prctl), PR_SET_SECCOMP, SECCOMP_MODE_FILTER, program.to_ptr, 0, 0)
        end
        instructions
      end

      # Install the real filter in a throwaway child and reach for a socket
      # with it on. Anything other than a SIGSYS death means it is not holding,
      # including a child that got its socket.
      def enforcing?
        return @enforcing if defined?(@enforcing)

        status = probe do
          install!(COMPILE)
          Libc.syscall(number(:socket), 2, 1, 0)
        end
        @enforcing = !status.nil? && status.signaled? && status.termsig == SIGSYS
      end

      # Whether the interpreter still starts, links, walks package.path and
      # writes to a pipe under +profile+. Nothing else in this file would
      # notice if the deny list had taken away something Lua needs, and finding
      # that out from a chat room is exactly what this exists to avoid.
      def runs?(profile)
        binary = interpreter
        return false if binary.nil?

        gated = profile == RUNTIME && !script?(binary)
        return false if profile == RUNTIME && !gated

        arguments = probe_arguments(binary)
        printed, status = probe_exec(binary, arguments, profile, gated)
        !status.nil? && status.success? && (arguments.empty? || printed.include?(PROBE_TOKEN))
      end

      def probe_exec(binary, arguments, profile, gated)
        reader, writer = IO.pipe
        status = probe(writer) do
          reader.close
          fd = IO.sysopen(binary, File::RDONLY)
          plan = exec_plan(fd, binary, arguments, probe_env)
          install!(profile, exec_fd: fd)
          gated ? exec!(plan) : exec_by_name!(plan)
        end
        writer.close
        printed = reader.read
        reader.close
        [printed, status]
      end

      # The interpreter to probe with, since a filter that kills Lua is the
      # failure worth catching. Where there is none the feature is off anyway,
      # so /bin/true stands in and proves the exec itself.
      def interpreter = Child.find_binary || (File.executable?("/bin/true") ? "/bin/true" : nil)

      # The environment the real child is given, since an interpreter probed
      # with a different one is not the interpreter that will run.
      def probe_env
        Child::SAFE_ENV_VARS.each_with_object({}) { |name, env| env[name] = ENV[name] if ENV.key?(name) }
      end

      # Requiring the rock is what walks package.path, which is the read side
      # of the filter under load. pcall, so a missing rock is a separate
      # problem rather than this one.
      def probe_arguments(binary)
        return [] if binary == "/bin/true"

        ["-e", "pcall(require, 'MessagePack'); io.write('#{PROBE_TOKEN}')"]
      end

      # A child that runs +block+ and nothing else. GC is off for the length of
      # it, so a throwaway child spends its few milliseconds the way the real
      # one does.
      def probe(out = nil)
        pid = fork do
          GC.disable
          $stdin.reopen(File::NULL)
          $stdout.reopen(out || File::NULL)
          $stderr.reopen(File::NULL, "w")
          begin
            yield
          rescue StandardError, SystemCallError
            exit!(1)
          end
          exit!(0)
        end
        Process.waitpid2(pid)&.last
      rescue NotImplementedError, SystemCallError
        nil
      end

      # A deployment with no filter, said the way {Isolation} says it.
      def unfiltered(env)
        if required?(env)
          "Operator scripts are OFF: #{reason}. Set #{SETTING}=#{OPTIONAL} to run them with no " \
            "system call filter, which lets a script that escapes the Lua sandbox open a socket."
        else
          "Operator scripts run with no system call filter, so a script that escapes the Lua sandbox " \
            "can open a socket: #{reason}. #{SETTING}=#{OPTIONAL} says that is deliberate."
        end
      end
    end
  end
end
