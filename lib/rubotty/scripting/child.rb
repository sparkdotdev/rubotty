# frozen_string_literal: true

require "messagepack"

module Rubotty
  module Scripting
    # One long lived Lua child process, and the loop that drives a single
    # invocation through it. Runs out of process because an operator's
    # infinite loop is otherwise unsurvivable: rlua holds the GVL for the
    # length of its call, so a spinning script freezes every Ruby thread,
    # and Timeout/Thread#kill cannot help, since both rely on a check the
    # VM makes between operations that a tight C loop never reaches.
    # SIGKILL works regardless, and the protocol (three frame types,
    # length-prefixed MessagePack) mirrors what sandbox.lua speaks.
    class Child
      # Where the interpreter is looked for, newest first: any Lua 5.x runs
      # the sandbox, but whichever is found has to be the version the rocks
      # were installed for, or the child's require("MessagePack") fails, so
      # the image deliberately carries exactly one.
      BINARIES = %w[lua5.5 lua5.4 lua5.3 lua].freeze

      # The most one frame may carry. Comfortably more than any reply a room
      # would accept (the widest platform limit is 4096 characters) and far
      # short of what would trouble this process. Checked against the length
      # prefix itself, so an oversized frame is refused before its bytes are
      # ever read rather than after.
      MAX_FRAME_BYTES = 1024 * 1024

      # Big endian, 4 bytes: the frame length prefix, both ways.
      LENGTH_PREFIX = "N"
      LENGTH_PREFIX_BYTES = 4

      SANDBOX = File.expand_path("sandbox.lua", __dir__)

      # The only names copied into the sandbox child's environment. Everything
      # else in this process's ENV, bot tokens and DATABASE_URL included, stays
      # out, whether or not sandbox.lua still strips os by the time the script runs.
      SAFE_ENV_VARS = %w[PATH HOME LANG].freeze

      # Address space ceiling for the child, in bytes. The kernel enforces this
      # from the first instruction, so ("x"):rep(1e12) dies in the child rather
      # than taking the bot's memory with it.
      DEFAULT_MEMORY_BYTES = 256 * 1024 * 1024

      # How long one invocation may take end to end: ten seconds is a hard
      # kill for something pathological, distinct from the one-second
      # save-time smoke test gate for trivial scripts. Since a processor
      # runs before Bridge, this (not {Registry::DEFAULT_MAX_CALLS}) is what
      # really bounds a chatty script, as a thousand recall()s burns clock
      # long before it burns call budget.
      DEFAULT_TIMEOUT = 10

      def initialize(binary: nil, logger: nil, memory_bytes: DEFAULT_MEMORY_BYTES)
        @binary = binary || self.class.find_binary
        @logger = logger
        @memory_bytes = memory_bytes
        @pid = nil
        @status = nil
        @notes = nil
      end

      # The first interpreter on PATH, or nil when there is none, which is what
      # makes the whole feature degrade to "unavailable" rather than raising at
      # boot on a deployment that never enabled it.
      #
      # PATH is walked here rather than shelling out to `command -v`, which is a
      # shell builtin with no executable behind it on Debian and Ubuntu, so that
      # spelling finds nothing on exactly the platform this deploys to.
      def self.find_binary
        paths = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).reject(&:empty?)
        BINARIES.each do |name|
          found = paths.find { |dir| File.executable?(File.join(dir, name)) }
          return File.join(found, name) if found
        end
        nil
      end

      # Both halves of it: an interpreter to run, and a deployment willing to
      # run scripts under the confinement it actually has.
      def available? = !@binary.nil? && Confined.satisfied?

      # Whether the kernel is actually enforcing this child's memory ceiling.
      # False on a platform that refused it, which {Limits} measured up front.
      def limits_applied? = Limits.available?

      def running? = !@pid.nil?

      # Run +source+ with +arg+ and return whatever the script returned,
      # raising {Timeout} when the deadline passes (having SIGKILLed the
      # child) and {Failed} when the script raised or would not compile. A
      # timeout always costs the child: it's killed rather than reused,
      # since a process that missed its deadline is in an unknown state and
      # respawning costs only milliseconds.
      def run(source:, arg: nil, registry: nil, timeout: DEFAULT_TIMEOUT)
        # First, so the refusal an operator gets names the reason rather than
        # blaming a missing interpreter. Memoised booleans: the confinement
        # itself is set up in {#start}, once per pooled child rather than once
        # per invocation.
        Confined.require!
        raise Unavailable, "no Lua interpreter on PATH (looked for #{BINARIES.join(", ")})" unless available?

        start
        deadline = now + timeout
        write(t: "invoke", src: source, arg: arg, sandbox: sandbox_spec(registry))
        pump(registry, deadline)
      rescue Errno::EPIPE, IOError
        # The same reasons a read finds, since a write to a child that has gone
        # is the other way of noticing the same thing.
        reason = gone_message
        kill
        raise Unavailable, "the Lua child went away: #{reason}"
      rescue Desync, Unavailable
        # Killed rather than returned to the pool. A desynced child would fail
        # the next invocation on leftover pipe data, and a child that died mid
        # invocation must be killed just to clear its pid, or #start finds a
        # corpse it thinks is still running.
        kill
        raise
      end

      # Stop the child. Safe to call when it was never started.
      def close
        return if @pid.nil?

        @stdin.close unless @stdin.closed?
        wait_briefly
        kill
      end

      private

      # Read frames until the invocation ends, serving host calls as they come.
      def pump(registry, deadline)
        budget = Budget.for(registry)
        loop do
          frame = read_frame(deadline)
          case frame["t"]
          when "done" then return frame["v"]
          when "error" then raise Failed, frame["m"].to_s
          when "call" then serve_call(frame, registry, budget, deadline)
          else
            raise Desync, "the child sent an unknown frame #{frame["t"].inspect}"
          end
        end
      end

      # Run one host call and write its answer back. A handler that raises
      # becomes an err frame (so a script can pcall around it) rather than
      # aborting the invocation; a refused broadcast likewise answers
      # `false` with a reason, but running out of the total budget ends the
      # invocation outright, since that many calls means the script is
      # looping, not working.
      def serve_call(frame, registry, budget, deadline)
        return write(t: "err", m: "this invocation has no host functions") if registry.nil?

        name = frame["fn"].to_s
        case budget.charge(registry.cost_of(name))
        when Budget::SPENT then raise Desync, budget.exhausted_reason(name)
        when Budget::BROADCAST_SPENT
          refusal = Answer.refuse(budget.broadcast_refusal(name))
          return write(t: "ret", v: refusal.values, multi: true)
        end

        value = call_with_deadline(registry, name, Array(frame["args"]), deadline)
        # A handler that means SEVERAL Lua return values says so, because a
        # bare Array is how the list returning functions answer and those have
        # to stay one table. See Scripting::Answer.
        if value.is_a?(Answer)
          write(t: "ret", v: value.values, multi: true)
        else
          write(t: "ret", v: value)
        end
      rescue Rubotty::Error, StandardError => e
        raise if e.is_a?(Failed) || e.is_a?(Timeout)

        @logger&.warn { "scripting: host call #{frame["fn"].inspect} failed: #{e.class}: #{e.message}" }
        write(t: "err", m: "#{e.class}: #{e.message}")
      end

      # registry.call, on its own thread, so a handler that blocks (a database
      # row lock, most concretely) cannot hold this past the invocation's own
      # deadline: nothing in a plain Ruby call stack checks the deadline the
      # way read_exact's IO.select does. A timed out handler is abandoned
      # rather than killed, since Ruby has no safe way to interrupt one mid
      # call; the child is killed instead, so a wedged handler costs one
      # child respawn rather than one taken out of rotation for good.
      def call_with_deadline(registry, name, args, deadline)
        remaining = deadline - now
        raise handler_timeout_error(name) if remaining <= 0

        raised = nil
        result = nil
        worker = Thread.new do
          result = registry.call(name, args)
        rescue Exception => e # rubocop:disable Lint/RescueException
          raised = e
        end

        raise handler_timeout_error(name) if worker.join(remaining).nil?
        raise raised unless raised.nil?

        result
      end

      # One frame, or a Timeout having killed the child.
      def read_frame(deadline)
        header = read_exact(LENGTH_PREFIX_BYTES, deadline)
        length = header.unpack1(LENGTH_PREFIX)

        # The child's own memory ceiling bounds what it can BUILD, but on a
        # platform that refuses rlimits there is no ceiling at all. The length
        # prefix says how big a frame is before any of it is read, so an
        # oversized one is refused rather than drained first.
        raise Desync, "the child sent a frame over #{MAX_FRAME_BYTES} bytes" if length > MAX_FRAME_BYTES

        Messagepack.unpack(read_exact(length, deadline))
      rescue Messagepack::Error => e
        raise Desync, "the child sent something that is not a frame: #{e.message}"
      end

      # +count+ bytes, or a Timeout having killed the child. IO.select bounds
      # the wait for the deadline, and the blocking read after it gathers the
      # rest, so a child that goes quiet mid frame is still caught either way.
      def read_exact(count, deadline)
        return "" if count.zero?

        remaining = deadline - now
        raise timeout_error if remaining <= 0

        ready = IO.select([@stdout], nil, nil, remaining)
        raise timeout_error if ready.nil?

        data = @stdout.read(count)
        raise Unavailable, gone_message if data.nil? || data.bytesize != count

        data
      end

      # Why the child stopped talking, which from a chat room otherwise looks
      # like nothing at all. Three causes get told apart from a closed pipe: a
      # child that never reached its exec says so down its own pipe, one
      # killed by SIGSYS was stopped by its own syscall filter, and anything
      # else carries the signal or status it went out on.
      def gone_message
        note = Confined.failure_note(@notes)
        return "the Lua child could not run: #{note}" unless note.nil?

        status = settled
        return "the Lua child closed its pipe" if status.nil?
        return "the Lua child exited with status #{status.exitstatus}" unless status.signaled?
        return filtered_message if status.termsig == Seccomp::SIGSYS

        "the Lua child was killed by SIG#{Signal.signame(status.termsig)}"
      end

      def filtered_message
        "the script's process was stopped by the system call filter, which means it tried to reach " \
          "the network, run another program or write a file"
      end

      # The exit status, waiting the moment it takes for a child that has closed
      # its pipe to finish going. Bounded, because a child that closed its pipe
      # and stayed alive would otherwise hold this thread.
      def settled
        deadline = now + 0.1
        loop do
          status = reap
          return status unless status.nil?
          return nil if now >= deadline

          sleep 0.005
        end
      end

      # The child's exit status where it has one to give, kept so {#kill} does
      # not go on to signal a process that has already been reaped.
      def reap
        return @status unless @status.nil?
        return nil if @pid.nil?

        @status = Process.waitpid2(@pid, Process::WNOHANG)&.last
      rescue Errno::ECHILD
        nil
      end

      # What the child is allowed to build its environment from, sent per
      # invocation rather than baked into the Lua so Scripting::Sandbox stays
      # the one definition. Getters go over unconditionally, unlike the host
      # functions, since they are answered inside the child from the payload
      # it already has, so there is no service that could be missing.
      def sandbox_spec(registry)
        {
          globals: Sandbox::GLOBALS,
          modules: Sandbox::MODULES,
          namespace: Sandbox::NAMESPACE,
          hosts: registry ? registry.names : [],
          getters: HostFunctions.getter_names
        }
      end

      def timeout_error
        kill
        Timeout.new("the script did not finish within its time budget")
      end

      def handler_timeout_error(name)
        kill
        Timeout.new("the #{name} host function did not finish within its time budget")
      end

      def write(**frame)
        packed = Messagepack.pack(frame)
        @stdin.write([packed.bytesize].pack(LENGTH_PREFIX), packed)
        nil
      end

      def start
        return if running?

        # Binary on both pipes, explicitly: a pipe otherwise inherits
        # Encoding.default_external, which is US-ASCII with no UTF-8 locale
        # (the container default). MessagePack is binary, so a pipe tagged
        # US-ASCII would raise on the first byte over 0x7F.
        @stdout, child_out = IO.pipe(Encoding::BINARY)
        child_in, @stdin = IO.pipe(Encoding::BINARY)
        @status = nil
        @pid = spawn_child(child_in, child_out)
        child_in.close
        child_out.close
        @logger&.debug { "scripting: started a Lua child (pid #{@pid})" }
      end

      # Start the child under every layer {Confined} can apply (its own
      # account, memory ceiling, syscall filter, Landlock), paid once here so
      # a pooled child carries it for every invocation it serves; a
      # deployment that can't get the ceiling it asked for is refused in
      # {#run} rather than silently served a weaker child. There is
      # deliberately no rlimit_cpu: it would bound CPU over the child's whole
      # pooled lifetime rather than per invocation, which the wall clock
      # deadline and kill already cover.
      def spawn_child(child_in, child_out)
        started = Confined.start(kind: :runtime, binary: @binary, args: [SANDBOX], env: safe_env,
                                 redirects: { in: child_in, out: child_out, err: File::NULL },
                                 rlimits: { rlimit_as: @memory_bytes })
        @notes = started.notes
        warn_about_limits unless limits_applied?
        started.pid
      end

      # {SAFE_ENV_VARS}, limited to the ones actually set.
      def safe_env
        SAFE_ENV_VARS.each_with_object({}) { |name, env| env[name] = ENV[name] if ENV.key?(name) }
      end

      # Warned every time rather than once, because a child running without a
      # memory ceiling is a real reduction in the guarantee this class exists to
      # make. The deadline and the kill still apply either way.
      def warn_about_limits
        @logger&.warn do
          "scripting: #{Limits.reason}, so the Lua child runs with no memory ceiling. " \
            "The time budget and the kill still apply."
        end
      end

      # Give a child that has had its stdin closed a moment to exit on its own,
      # so the ordinary path is a clean exit and SIGKILL is only for the ones
      # that have stopped listening.
      def wait_briefly
        deadline = now + 0.2
        loop do
          return unless reap.nil?
          return if now >= deadline

          sleep 0.01
        end
      end

      # A pid that has already been reaped must not be signalled: it is either
      # gone or belongs to somebody else by now.
      def kill
        return if @pid.nil?

        if @status.nil?
          begin
            Process.kill("KILL", @pid)
            Process.waitpid(@pid)
          rescue Errno::ESRCH, Errno::ECHILD
            nil
          end
        end
        @stdin.close unless @stdin.nil? || @stdin.closed?
        @stdout.close unless @stdout.nil? || @stdout.closed?
        @notes.close unless @notes.nil? || @notes.closed?
        @status = nil
        @pid = nil
      end

      def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
