# frozen_string_literal: true

require "tmpdir"

module Rubotty
  module Scripting
    # Filesystem half of what a script's process gives up, on top of {Seccomp}: Landlock
    # is the LSM the kernel asks about the path itself, so unlinking, renaming,
    # truncating, and making a node are covered too, none of which pass a flag a syscall
    # filter could read. The runtime gets a read-only rule on `/`. A compiler gets
    # trusted interpreter/library paths to read and execute, one precreated output
    # file to write, and signal scoping so another invocation sharing its UID stays outside
    # the domain. Its syscall filter covers metadata changes Landlock cannot mediate.
    module Landlock
      # Set to "off" for a deployment that wants the seccomp filter without
      # this for the runtime. Untrusted compilation requires its separate workspace
      # policy; only the existing explicitly trusted isolation opt-out bypasses that.
      SETTING = "RUBOTTY_SCRIPT_LANDLOCK"
      OFF = "off"

      # Same numbers on every architecture this runs on.
      CREATE_RULESET = 444
      ADD_RULE = 445
      RESTRICT_SELF = 446

      # Asking for the ABI version rather than for a ruleset.
      CREATE_RULESET_VERSION = 1
      RULE_PATH_BENEATH = 1

      EXECUTE = 1 << 0
      READ_FILE = 1 << 2
      READ_DIR = 1 << 3
      REFER = 1 << 13
      TRUNCATE = 1 << 14
      IOCTL_DEV = 1 << 15
      WRITE_FILE = 1 << 1
      REMOVE_DIR = 1 << 4
      REMOVE_FILE = 1 << 5
      MAKE_DIR = 1 << 7
      MAKE_REG = 1 << 8
      SCOPE_SIGNAL = 1 << 1
      # ABI3 supplies truncate protection; ABI6 also isolates same-UID signals.
      COMPILE_MIN_ABI = 6
      COMPILE_READ_ROOTS = %w[/usr /bin /sbin /lib /lib64].freeze
      COMPILE_READ_FILES = %w[/etc/ld.so.cache /etc/localtime /dev/urandom].freeze

      # Everything ABI 1 knew about: execute, write, read, list, remove and the
      # seven make bits.
      ORIGINAL = (1 << 13) - 1

      # Bind and connect over TCP, from ABI 4.
      NET_BIND_TCP = 1 << 0
      NET_CONNECT_TCP = 1 << 1

      module_function

      # What the kernel offers, or nil where it offers nothing. A read only
      # call, so this one needs no child to ask it in.
      def abi
        return @abi if defined?(@abi)

        @abi = ask_abi
      end

      def ask_abi
        return nil unless Seccomp.supported?

        version = Libc.syscall(CREATE_RULESET, 0, 0, CREATE_RULESET_VERSION)
        version.positive? ? version : nil
      rescue StandardError, SystemCallError, NotImplementedError
        nil
      end

      # Whether a ruleset really takes. Measured the same way the filter is: a
      # throwaway child restricts itself and then tries both sides of the line.
      def available?
        return @available if defined?(@available)

        @available = enabled? && !abi.nil? && restricts?
      end

      def enabled?(env = ENV) = env[SETTING].to_s.strip.downcase != OFF

      def compile_available?
        return @compile_available if defined?(@compile_available)

        @compile_available = enabled? && abi.to_i >= COMPILE_MIN_ABI && compile_restricts?
      end

      def require_compile!(env = ENV)
        return unless Isolation.required?(env)
        return if compile_available? && Seccomp.available?

        raise Unavailable,
              "non-Lua compilation requires enforced compiler syscall isolation and Landlock ABI #{COMPILE_MIN_ABI} " \
              "for private scratch files and signals. #{Isolation::SETTING}=#{Isolation::OPTIONAL} is only " \
              "for explicitly trusted scripts on a machine without those protections."
      end

      # Everything this ABI knows how to handle, so that whatever is not
      # granted below is denied.
      def handled_fs(version)
        bits = ORIGINAL
        bits |= REFER if version >= 2
        bits |= TRUNCATE if version >= 3
        bits |= IOCTL_DEV if version >= 5
        bits
      end

      # The whole filesystem, read only. IOCTL_DEV goes back because an
      # interpreter asks a character device whether it is a terminal, and
      # refusing that is a confusing way to gain nothing.
      def granted_fs(version)
        bits = EXECUTE | READ_FILE | READ_DIR
        bits |= IOCTL_DEV if version >= 5
        bits
      end

      def handled_net(version) = version >= 4 ? NET_BIND_TCP | NET_CONNECT_TCP : 0

      # Put the ruleset on THIS process. Only ever called in a forked child,
      # before the exec.
      def restrict!(version = abi)
        raise Unavailable, "this kernel has no Landlock" if version.nil?

        prctl_no_new_privs
        fd = create_ruleset(version)
        begin
          allow_reading_everything(fd, version)
          Libc.syscall(RESTRICT_SELF, fd, 0)
        ensure
          IO.for_fd(fd).close
        end
      end

      # struct landlock_ruleset_attr { __u64 handled_access_fs;
      # __u64 handled_access_net; __u64 scoped; }. The second field exists from
      # ABI4 and signal scoping from ABI6, so the length says which one this is.
      def create_ruleset(version, scoped: 0)
        attribute = [handled_fs(version), handled_net(version), scoped].pack("Q3")
        length = scoped.positive? ? 24 : (version >= 4 ? 16 : 8)
        Libc.syscall(CREATE_RULESET, Libc.pointer(attribute), length, 0)
      end

      def compile_rules(workspace:, binary: nil, output: nil, version: abi)
        raise Unavailable, "compiler filesystem isolation needs Landlock ABI #{COMPILE_MIN_ABI}" if version.to_i < COMPILE_MIN_ABI

        workspace = File.realpath(workspace)
        raise Unavailable, "compiler scratch must be a directory" unless File.directory?(workspace)
        roots = COMPILE_READ_ROOTS.filter_map { |path| canonical_existing(path) }.uniq
        ambient = %w[/ /tmp /var/tmp].filter_map { |path| canonical_existing(path) }
        ambient << File.realpath(Dir.tmpdir)
        ambient << canonical_existing(ENV["HOME"]) unless ENV["HOME"].to_s.empty?
        if ambient.include?(workspace) || roots.any? { |root| beneath?(workspace, root) || beneath?(root, workspace) }
          raise Unavailable, "compiler scratch overlaps an ambient or trusted read path"
        end
        rules = roots.map { |path| [path, granted_fs(version)] }
        COMPILE_READ_FILES.each do |path|
          canonical = canonical_existing(path)
          rules << [canonical, READ_FILE] if canonical
        end
        rules << [File.realpath(binary), EXECUTE | READ_FILE] if binary
        null_rights = READ_FILE | WRITE_FILE | (version >= 5 ? IOCTL_DEV : 0)
        rules << [File.realpath(File::NULL), null_rights]
        rules << [workspace, READ_FILE | READ_DIR]
        if output
          stat = File.lstat(output)
          canonical = File.realpath(output)
          unless stat.file? && stat.nlink == 1 && canonical == File.join(workspace, "script.lua")
            raise Unavailable, "compiler output must be the precreated regular script.lua file in its private workspace"
          end
          rules << [canonical, READ_FILE | WRITE_FILE | TRUNCATE]
        end
        rules
      end

      def restrict_compile!(workspace:, binary: nil, output: nil, version: abi)
        rules = compile_rules(workspace: workspace, binary: binary, output: output, version: version)
        prctl_no_new_privs
        fd = create_ruleset(version, scoped: SCOPE_SIGNAL)
        begin
          rules.each { |path, rights| allow_path(fd, path, rights) }
          Libc.syscall(RESTRICT_SELF, fd, 0)
        ensure
          IO.for_fd(fd).close
        end
      end

      def allow_path(fd, path, rights)
        parent = IO.sysopen(path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK)
        begin
          unless IO.for_fd(parent, autoclose: false).stat.directory?
            rights &= EXECUTE | READ_FILE | WRITE_FILE | TRUNCATE | IOCTL_DEV
          end
          rule = [rights].pack("Q") + [parent].pack("l")
          Libc.syscall(ADD_RULE, fd, RULE_PATH_BENEATH, Libc.pointer(rule), 0)
        ensure
          IO.for_fd(parent).close
        end
      end

      def canonical_existing(path)
        File.realpath(path)
      rescue Errno::ENOENT
        nil
      end

      def beneath?(path, root) = path == root || path.start_with?(root + File::SEPARATOR)

      def compile_restricts?
        Dir.mktmpdir("rubotty-compile-probe") do |dir|
          own = File.join(dir, "own")
          other = File.join(dir, "other")
          Dir.mkdir(own)
          Dir.mkdir(other)
          output = File.join(own, "script.lua")
          File.write(output, "")
          File.write(File.join(other, "one"), "x")
          pid = fork do
            $stderr.reopen(File::NULL, "w")
            begin
              restrict_compile!(workspace: own, output: output)
              File.write(output, "x")
              begin
                File.write(File.join(own, "new"), "x")
                exit!(5)
              rescue Errno::EACCES, Errno::EPERM
                nil
              end
              begin
                File.read(File.join(other, "one"))
                exit!(2)
              rescue Errno::EACCES, Errno::EPERM
                nil
              end
              begin
                File.write(File.join(other, "one"), "x")
                exit!(3)
              rescue Errno::EACCES, Errno::EPERM
                exit!(0)
              end
            rescue StandardError, SystemCallError
              exit!(4)
            end
          end
          return Process.waitpid2(pid)&.last&.success? || false
        end
      rescue NotImplementedError, SystemCallError
        false
      end

      # struct landlock_path_beneath_attr { __u64 allowed_access;
      # __s32 parent_fd; }, packed, so twelve bytes rather than sixteen. By hand
      # because Fiddle::CStruct cannot express a packed struct.
      def allow_reading_everything(fd, version)
        root = IO.sysopen("/", File::RDONLY)
        begin
          rule = [granted_fs(version)].pack("Q") + [root].pack("l")
          Libc.syscall(ADD_RULE, fd, RULE_PATH_BENEATH, Libc.pointer(rule), 0)
        ensure
          IO.for_fd(root).close
        end
      end

      def prctl_no_new_privs = Libc.syscall(Seccomp.number(:prctl), Seccomp::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0)

      # A child that restricts itself and then tries both sides of the line: a
      # file it should still be able to read, and one it should no longer be
      # able to create.
      def restricts?
        pid = fork do
          GC.disable
          $stderr.reopen(File::NULL, "w")
          exit!(probe_result)
        end
        Process.waitpid2(pid)&.last&.exitstatus&.zero? || false
      rescue NotImplementedError, SystemCallError
        false
      end

      def probe_result
        restrict!
        begin
          File.read("/etc/hostname")
        rescue Errno::EACCES, Errno::EPERM
          return 2
        end

        File.write(File.join(Dir.tmpdir, "rubotty-landlock-probe"), "x")
        3
      rescue Errno::EACCES, Errno::EPERM
        0
      rescue StandardError, SystemCallError
        4
      end

      # One line for the startup checks, or nothing where there is nothing to
      # say beyond what the filter already said.
      def describe
        return "The kernel has no Landlock, so the filesystem side rests on the system call filter alone." if abi.nil?
        unless available?
          return "This kernel offers Landlock ABI #{abi}, and a ruleset did not take here, so the " \
                 "filesystem side rests on the system call filter alone."
        end

        network = abi >= 4 ? ", and no TCP at all" : ""
        "Script runtimes also run under a Landlock ruleset (ABI #{abi}): the whole filesystem read " \
          "only, so a script's process cannot create, delete, rename or truncate anything#{network}."
      end

      # Forget the probe. Only tests need this.
      def reset!
        remove_instance_variable(:@abi) if defined?(@abi)
        remove_instance_variable(:@available) if defined?(@available)
        remove_instance_variable(:@compile_available) if defined?(@compile_available)
      end
    end
  end
end
