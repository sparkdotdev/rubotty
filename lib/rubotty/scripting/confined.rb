# frozen_string_literal: true

module Rubotty
  module Scripting
    # How a script's process is started and confined, through {Isolation}'s
    # account, {Limits}'s rlimit ceiling, {Seccomp}'s syscall filter and
    # {Landlock}'s read-only filesystem, each independently switchable.
    # Forks and execs rather than calling Process.spawn: a filter must be
    # installed by the process it applies to, and spawn gives no hook
    # between fork and exec for that. The address space ceiling goes on
    # last, after everything that allocates, since a capped child can't map
    # another page to finish its own exec.
    module Confined
      # A started child, and the pipe it reports a setup failure down. The pipe
      # is nil for a plain spawn, which has nothing to report through it.
      Started = Struct.new(:pid, :notes)

      # Every layer that can refuse to run a script, in the order an operator
      # would want to hear about them.
      LAYERS = [Isolation, Limits, Seccomp].freeze

      # Where a child says why it never reached its exec. Small on purpose: a
      # short message rather than a log stream.
      MAX_NOTE_BYTES = 512

      F_GETFL = 3
      F_SETFD = 2
      F_SETFL = 4
      FD_CLOEXEC = 1
      O_NONBLOCK = 0o4000

      # How far to walk looking for open descriptors where /proc is not there
      # to list them.
      FD_SEARCH_CEILING = 4096

      module_function

      # Every layer a deployment agreed to, or the first refusal.
      def require!(env = ENV, kind: :runtime)
        LAYERS.each { |layer| layer.require!(env) }
        Landlock.require_compile!(env) if kind == :compile
      end

      def satisfied?(env = ENV) = LAYERS.all? { |layer| layer.satisfied?(env) }

      # Why a script will not run, taking the first layer that is unhappy.
      def reason(env = ENV)
        LAYERS.reject { |layer| layer.satisfied?(env) }.filter_map(&:reason).first
      end

      # A line per layer, for the startup checks.
      def describe(env = ENV) = LAYERS.map { |layer| layer.describe(env) } + [Landlock.describe]

      # Start +binary+ under everything this deployment can apply: +kind+
      # picks :runtime (the pooled Lua child) or :compile (a save-time
      # transpiler, spawned by name since it writes its output to a file).
      # Forks itself for either of the two things only the process itself can
      # ask for, a filter to install or a Landlock ruleset to put on, and
      # Landlock no longer waits for a filter to ride along with. With neither
      # this falls to {spawn_plainly}, which forks on its own account whenever
      # there is one to become.
      def start(kind:, binary:, args: [], env: {}, redirects: {}, rlimits: {}, chdir: nil, process_group: false,
                compile_output: nil)
        Landlock.require_compile! if kind == :compile
        profile = Seccomp.available? ? profile_for(kind) : nil
        restrict = kind == :runtime && Landlock.available?
        compile = kind == :compile && Landlock.compile_available?
        raise Unavailable, "compiler filesystem isolation needs a private working directory" if compile && chdir.nil?

        filesystem = compile ? { compile_workspace: File.realpath(chdir) } : {}
        filesystem[:compile_output] = compile_output if compile && compile_output
        limits = capped(rlimits)
        grouping = process_group ? { process_group: true } : {}
        return spawn_plainly(binary, args, env, redirects, limits, chdir, **grouping) if profile.nil? && !restrict && !compile

        fork_and_exec(binary: binary, args: args, env: env, redirects: redirects, rlimits: limits,
                      chdir: chdir, profile: profile, restrict: restrict, **grouping, **filesystem)
      end

      def profile_for(kind) = kind == :runtime ? Seccomp.runtime_profile : Seccomp.compile_profile

      # Whatever the caller asked for, minus a ceiling this platform has
      # already been measured refusing. {Limits} is what decides whether
      # running without it is allowed at all.
      def capped(rlimits)
        return rlimits if Limits.available?

        rlimits.reject { |name, _| name == :rlimit_as }
      end

      # The path this took before there was a filter to install, and still the
      # path where there is neither a filter nor an account to become.
      def spawn_plainly(binary, args, env, redirects, rlimits, chdir, process_group: false)
        grouping = process_group ? { process_group: true } : {}
        return fork_for_isolation(binary, args, env, redirects, rlimits, chdir, **grouping) unless Isolation.account.nil?

        options = plain_options(redirects, chdir)
        options[:pgroup] = true if process_group
        Started.new(Process.spawn(env, binary, *args, **options, **rlimits), nil)
      end

      # Process.spawn turns :uid and :gid into plain setgid and setuid calls
      # and never setgroups, so dropping into a real account needs this process
      # to fork itself for the same reason a filter does: only the process
      # itself can give up what a spawn cannot be asked to give up for it.
      def fork_for_isolation(binary, args, env, redirects, rlimits, chdir, process_group: false)
        pid = fork do
          GC.disable
          Process.setpgid(0, 0) if process_group
          become_the_script_account
          Process.exec(env, binary, *args, **plain_options(redirects, chdir), **rlimits)
        rescue Exception
          nil
        ensure
          exit!(127)
        end
        Started.new(pid, nil)
      end

      # What both plain paths hand the kernel, so neither can drift from the
      # other on what a child starts holding.
      def plain_options(redirects, chdir)
        options = redirects.merge(close_others: true, unsetenv_others: true)
        options[:chdir] = chdir unless chdir.nil?
        options
      end

      def fork_and_exec(**setup)
        reader, writer = IO.pipe
        pid = fork do
          reader.close
          run_child(writer, **setup)
        end
        writer.close
        Started.new(pid, reader)
      end

      # Everything that happens between the fork and the exec: nothing in
      # here may return, since a child that falls out of its exec has to say
      # why and die or the parent is left reading a pipe nobody writes to.
      # Rescues every Exception rather than StandardError, since a child on
      # its way to an exec has nothing to gain by letting one through.
      def run_child(notes, **setup)
        GC.disable
        confine(notes: notes, **setup)
        note(notes, "the exec returned, which it only does when it did not happen")
      rescue Exception => e
        note(notes, "#{e.class}: #{e.message}")
      ensure
        exit!(127)
      end

      def confine(binary:, args:, env:, redirects:, rlimits:, chdir:, profile:, restrict:, notes:,
                  process_group: false, compile_workspace: nil, compile_output: nil)
        Process.setpgid(0, 0) if process_group
        redirect(redirects, notes)
        Dir.chdir(chdir) unless chdir.nil?
        path = resolve(binary, env)
        fd = IO.sysopen(path, File::RDONLY)
        close_others!
        gated = profile == Seccomp::RUNTIME && !Seccomp.script?(path)
        profile = Seccomp::RUNTIME_OPEN_EXEC if profile == Seccomp::RUNTIME && !gated
        plan = Seccomp.exec_plan(fd, path, args, env, called: binary)
        become_the_script_account
        if compile_workspace
          Landlock.restrict_compile!(workspace: compile_workspace, binary: path, output: compile_output)
        elsif restrict
          Landlock.restrict!
        end
        Seccomp.install!(profile, exec_fd: fd) unless profile.nil?
        rlimits.each { |name, bytes| Process.setrlimit(rlimit(name), bytes) }
        gated ? Seccomp.exec!(plan) : Seccomp.exec_by_name!(plan)
      end

      # :rlimit_as as Process::RLIMIT_AS, the way Process.spawn reads the same
      # option.
      def rlimit(name) = Process.const_get(name.to_s.upcase)

      # Where a bare name lives, since a spawn would have walked PATH for it and
      # every dialect is named rather than pathed. The child's own PATH is what
      # is walked, so it finds what it would have found.
      def resolve(binary, env)
        return binary if binary.include?(File::SEPARATOR)

        directories = (env["PATH"] || ENV.fetch("PATH", "")).split(File::PATH_SEPARATOR).reject(&:empty?)
        directories.map { |dir| File.join(dir, binary) }.find { |path| File.executable?(path) } || binary
      end

      # A caller that throws the child's stderr away gets it pointed at the
      # notes pipe instead, so an interpreter that refuses to start says so
      # somewhere the parent can read it. The pipe is close-on-exec and this is
      # a dup of it, which is not, so it survives into the interpreter.
      def redirect(redirects, notes)
        redirect_one($stdin, redirects[:in], "r")
        redirect_one($stdout, redirects[:out], "w")
        redirect_one($stderr, redirects[:err] == File::NULL ? notes : redirects[:err], "w")
        (0..2).each { |fd| block!(fd) }
      end

      # Ruby makes every pipe it creates non-blocking, a property of the open
      # file description that survives the dup onto the descriptors the
      # interpreter reads and writes. Reading a non-blocking pipe hands the
      # interpreter EAGAIN whenever the parent hasn't written yet, which it
      # takes for end of input and exits on, looking from here like a child
      # that finished on its own, so this clears the flag by hand exactly as
      # Process.spawn does.
      def block!(fd)
        flags = Libc.syscall(Seccomp.number(:fcntl), fd, F_GETFL, 0)
        return unless flags.anybits?(O_NONBLOCK)

        Libc.syscall(Seccomp.number(:fcntl), fd, F_SETFL, flags & ~O_NONBLOCK)
      rescue SystemCallError
        nil
      end

      def redirect_one(io, target, mode)
        return if target.nil?

        target.is_a?(String) ? io.reopen(target, mode) : io.reopen(target)
      end

      # What close_others does for a spawn: everything above stderr goes on
      # exec, the descriptor being exec'd from included, so the interpreter
      # starts holding nothing but its three pipes.
      def close_others!
        open_descriptors.each do |fd|
          next if fd < 3

          begin
            Libc.syscall(Seccomp.number(:fcntl), fd, F_SETFD, FD_CLOEXEC)
          rescue SystemCallError
            nil
          end
        end
      end

      def open_descriptors
        return Dir.children("/proc/self/fd").map(&:to_i) if File.directory?("/proc/self/fd")

        (3...FD_SEARCH_CEILING).to_a
      end

      # The supplementary groups, the group and then the account, in the order
      # that needs the privilege being given up. Process.spawn's uid and gid
      # options do the last two and nothing else, so a child started that way
      # keeps every group this process belongs to: the docker socket's group,
      # a shared volume's, whatever an image put root in. Those reach straight
      # past an unprivileged uid, so they go first, and nothing rescues a
      # refusal here: keeping them is what this exists to prevent.
      def become_the_script_account
        account = Isolation.account
        return if account.nil?

        Process.groups = []
        Process::Sys.setgid(account[:gid])
        Process::Sys.setuid(account[:uid])
      end

      def note(notes, text)
        notes.write(text[0, MAX_NOTE_BYTES])
        notes.close
      rescue StandardError
        nil
      end

      # Whatever a child managed to say before it died, for a parent holding a
      # pipe that will not answer again. Nothing to say is the ordinary case:
      # the pipe closes empty when the exec worked.
      def failure_note(notes)
        return nil if notes.nil? || notes.closed?

        text = notes.read_nonblock(MAX_NOTE_BYTES, exception: false)
        text.is_a?(String) && !text.strip.empty? ? text.strip : nil
      rescue IOError, SystemCallError
        nil
      end
    end
  end
end
