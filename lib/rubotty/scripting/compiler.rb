# frozen_string_literal: true

require "tmpdir"

module Rubotty
  module Scripting
    # Turns whatever dialect an operator wrote into the Lua that actually runs.
    #
    # This runs in the web process on text somebody typed into a browser, and no
    # sandbox stops a Fennel macro looping forever, so every compile is a child
    # process with a deadline and memory limits whatever the dialect.
    class Compiler
      class Failed < Scripting::Error; end

      DEFAULT_TIMEOUT = 10

      # Generous for a transpiler and well short of troubling the web process.
      MEMORY_BYTES = 256 * 1024 * 1024

      # How much of a transpiler's complaint is kept: the useful part is at the
      # front and the source it echoes back can be long.
      ERROR_LIMIT = 500
      SOURCE_LIMIT = 512 * 1024
      OUTPUT_LIMIT = 8 * 1024 * 1024
      DIAGNOSTIC_LIMIT = 64 * 1024
      FILE_DESCRIPTORS = 64

      # The only names copied into a transpiler subprocess's environment.
      # Everything else in this process's ENV, bot tokens and DATABASE_URL
      # included, stays out.
      SAFE_ENV_VARS = %w[PATH HOME LANG].freeze

      def initialize(timeout: DEFAULT_TIMEOUT, logger: nil, source_limit: SOURCE_LIMIT,
                     output_limit: OUTPUT_LIMIT, diagnostic_limit: DIAGNOSTIC_LIMIT)
        @timeout = timeout
        @logger = logger
        @source_limit = Integer(source_limit)
        @output_limit = Integer(output_limit)
        @diagnostic_limit = Integer(diagnostic_limit)
        unless [@source_limit, @output_limit, @diagnostic_limit].all?(&:positive?)
          raise ArgumentError, "compiler byte limits must be positive"
        end
      end

      # The Lua for +source+, or the source itself when it is already Lua.
      def compile(source, language: Dialects::DEFAULT)
        source = source.to_s
        raise Failed, "the script exceeds the #{@source_limit} byte input limit." if source.bytesize > @source_limit

        dialect = Dialects.find!(language)
        return source if dialect.native?

        unless Dialects.installed?(dialect.binary)
          reason = Dialects.unavailable_reason(dialect)
          detail = reason.nil? ? "" : " #{reason}"
          raise Failed, "#{dialect.label} needs #{dialect.binary}, which is not installed here.#{detail}"
        end

        Confined.require!(kind: :compile)
        run(dialect, source)
      end

      def available?(language) = Dialects.available?(language)

      private

      # A throwaway directory, because Teal writes its output next to the input
      # rather than to stdout. Handed to the script account, since a confined
      # transpiler runs as somebody else and mktmpdir's 0700 shuts it out.
      def run(dialect, source)
        deadline = monotonic + @timeout
        Dir.mktmpdir("rubotty-compile") do |dir|
          path = File.join(dir, "script#{dialect.extension}")
          File.write(path, source)
          paths = [dir, path]
          if dialect.output == :file
            output = File.join(dir, "script.lua")
            File.open(output, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.truncate(0) }
            paths << output
          end
          Isolation.grant(*paths)

          type_check(dialect, path, dir, deadline: deadline)

          out, err, status = capture(dialect, path, dir, deadline: deadline)
          raise Failed, stopped_message(dialect) if stopped?(status)
          raise Failed, scrub(trim(err, out), dir) unless status&.success?

          result = dialect.output == :file ? read_output(dir, deadline: deadline) : out
          result = result.dup if result.frozen?
          result.force_encoding(Encoding::UTF_8)
          raise Failed, "the compiler produced output that was not valid UTF-8." unless result.valid_encoding?
          raise Failed, "#{dialect.label} produced nothing to run." if result.strip.empty?

          result
        end
      end

      # What the CPU and memory limits look like from here. Where the platform
      # refuses rlimits, the deadline catches a runaway macro instead.
      def stopped?(status) = !status.nil? && status.signaled?

      def stopped_message(dialect)
        "#{dialect.label} was stopped after using too much time or memory, or exceeding its file output limit. " \
          "A macro that never finishes is the usual cause."
      end

      DEFINITIONS = "rubotty"

      # Teal's generator strips the annotations and exits 0 whether or not they
      # hold, so the types are only checked by this separate pass.
      def type_check(dialect, path, dir, deadline:)
        return unless dialect.checked?

        # Teal cannot say anything useful without knowing what m and rubotty are.
        definitions = File.join(dir, "#{DEFINITIONS}.d.tl")
        File.write(definitions, TealDefinitions.to_s)
        Isolation.grant(definitions)
        args = dialect.check_args + ["--global-env-def", DEFINITIONS]
        out, err, status = capture(dialect, path, dir, args: args, deadline: deadline,
                                  stdout_limit: @diagnostic_limit)
        return if status&.success?

        raise Failed, scrub(trim(err, out), dir)
      end

      # Opened without following a link. The transpiler owns this directory, so
      # a symlink left where its output belongs would have this process read
      # whatever it points at and hand that back as the compiled Lua, which
      # would walk a confined child straight back out through its parent.
      def read_output(dir, deadline: nil)
        path = File.join(dir, "script.lua")
        check_deadline(deadline) if deadline
        result = File.open(path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |file|
          raise Failed, "the compiler left something other than a file where its output belongs." unless file.stat.file?
          raise_output_limit if file.stat.size > @output_limit

          text = file.read(@output_limit + 1).to_s
          raise_output_limit if text.bytesize > @output_limit

          text
        end
        check_deadline(deadline) if deadline
        result
      rescue Errno::ENOENT
        raise Failed, "the compiler wrote no Lua."
      rescue Errno::ELOOP, Errno::EMLINK, Errno::ENXIO, Errno::ENODEV, Errno::EISDIR
        raise Failed, "the compiler left something other than a file where its output belongs."
      end

      # Spawned rather than shelled out to, so an awkwardly named source file is
      # an argument and not something the shell parses.
      def capture(dialect, path, dir, args: nil, deadline: monotonic + @timeout, stdout_limit: nil)
        check_deadline(deadline)
        out_read, out_write = IO.pipe(Encoding::UTF_8)
        err_read, err_write = IO.pipe(Encoding::UTF_8)
        started = spawn_child(dialect, path, dir, out_write, err_write, args: args)
        check_deadline(deadline)
        out_write.close
        err_write.close

        stdout_limit ||= dialect.output == :file ? @diagnostic_limit : @output_limit
        out, err = drain(started.pid, out_read, err_read, deadline: deadline, stdout_limit: stdout_limit)
        status = wait(started.pid, deadline)
        reaped = true
        [out, note_or(err, started), status]
      ensure
        kill(started.pid, reaped: reaped) if started
        [out_read, err_read, out_write, err_write, started&.notes].each { |io| io&.close unless io&.closed? }
      end

      # A transpiler that never reached its exec has nothing on either pipe, so
      # what it said on the way down stands in for stderr.
      def note_or(err, started)
        return err unless err.to_s.b.strip.empty?

        Confined.failure_note(started.notes) || err
      end

      # {Confined} decides the account, limits and filter this runs under, the
      # same mechanism the pooled runtime child uses. The rlimit ceiling and
      # the timeout deadline are enforced separately, so a platform that
      # refuses the rlimit does not fall through to running with neither.
      def spawn_child(dialect, path, dir, out_write, err_write, args: nil)
        Confined.start(kind: :compile, binary: dialect.binary, args: [*(args || dialect.args), path],
                       env: safe_env.merge("TMPDIR" => dir, "TMP" => dir, "TEMP" => dir, "PWD" => dir),
                       redirects: { in: File::NULL, out: out_write, err: err_write }, chdir: dir,
                       rlimits: compile_limits, process_group: true,
                       compile_output: dialect.output == :file ? File.join(dir, "script.lua") : nil)
      end

      def compile_limits
        limits = { rlimit_as: MEMORY_BYTES, rlimit_cpu: [@timeout.ceil, 1].max,
                   rlimit_nofile: FILE_DESCRIPTORS, rlimit_core: 0 }
        limits[:rlimit_fsize] = @output_limit if Process.const_defined?(:RLIMIT_FSIZE)
        limits
      end

      # {SAFE_ENV_VARS}, limited to the ones actually set.
      def safe_env
        SAFE_ENV_VARS.each_with_object({}) { |name, env| env[name] = ENV[name] if ENV.key?(name) }
      end

      def drain(_pid, out_read, err_read, deadline: monotonic + @timeout, stdout_limit: @output_limit)
        out = +""
        err = +""
        open = [out_read, err_read]

        until open.empty?
          left = deadline - monotonic
          raise_timeout if left <= 0

          ready = IO.select(open, nil, nil, left)
          raise_timeout if ready.nil?

          ready[0].each do |io|
            buffer = io == out_read ? out : err
            limit = io == out_read ? stdout_limit : @diagnostic_limit
            chunk = io.read_nonblock([4096, limit - buffer.bytesize + 1].min, exception: false)
            if chunk.nil? || chunk == :wait_readable
              open.delete(io) if chunk.nil?
              next
            end
            if buffer.bytesize + chunk.bytesize > limit
              stream = io == out_read ? "output" : "diagnostic output"
              raise Failed, "the compiler exceeded its #{limit} byte #{stream} limit."
            end
            buffer << chunk
          end
        end
        [out, err]
      end

      def raise_timeout
        raise Failed, "the compiler did not finish within #{@timeout} seconds."
      end

      def kill(pid, reaped: false)
        return if reaped || !pid.is_a?(Integer) || !pid.positive?

        signal(-pid)
        # A forked child may not have established its group yet. Its PID is
        # still reserved until reaping, so terminate the leader and retry the
        # group to catch helpers created as that setup race completed.
        signal(pid)
        signal(-pid)
        # A stuck native child must not turn cleanup into an unbounded wait.
        Process.detach(pid)
      rescue Errno::ECHILD
        nil
      end

      def signal(pid)
        Process.kill("KILL", pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end

      def wait(pid, deadline)
        loop do
          check_deadline(deadline)
          if exited?(pid)
            # Keep the exited leader waitable until its helpers have been
            # signaled: reaping it first could let an unrelated process reuse
            # the numeric group ID before cleanup.
            signal(-pid)
            return Process.wait2(pid, Process::WNOHANG)&.last
          end

          IO.select(nil, nil, nil, [deadline - monotonic, 0.01].min.clamp(0, 0.01))
        end
      rescue Errno::ECHILD
        nil
      end

      # waitid(WNOWAIT) observes exit without releasing the PID/group identity.
      # Both supported OS ABIs start siginfo_t with si_signo; the 128-byte buffer
      # covers their complete structures. WEXITED and WNOHANG are 4 and 1 on both.
      def exited?(pid)
        host = RbConfig::CONFIG["host_os"]
        nowait = if host.include?("linux")
                   0x0100_0000
                 elsif host.include?("darwin")
                   0x20
                 else
                   raise Unavailable, "compiler process cleanup needs waitid support on this platform"
                 end
        @waitid ||= Fiddle::Function.new(Fiddle::Handle::DEFAULT["waitid"],
                                        [Fiddle::TYPE_INT, Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT],
                                        Fiddle::TYPE_INT, name: "waitid", need_gvl: true)
        info = "\0".b * 128
        result = @waitid.call(1, pid, Libc.pointer(info), 4 | 1 | nowait)
        raise SystemCallError.new("waitid", Fiddle.last_error) if result == -1

        !info.unpack1("i").zero?
      rescue Errno::EINTR
        false
      rescue Fiddle::DLError
        raise Unavailable, "compiler process cleanup needs waitid support on this platform"
      end

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      def check_deadline(deadline)
        raise_timeout if monotonic >= deadline
      end

      def raise_output_limit
        raise Failed, "the compiler exceeded its #{@output_limit} byte output limit."
      end

      # Some transpilers report on stdout rather than stderr, so both are tried.
      def trim(err, out)
        message = [err, out].map(&:to_s).find { |text| !text.b.strip.empty? }
        return "the compiler refused it but said nothing about why." if message.nil?

        message.b.strip.byteslice(0, ERROR_LIMIT * 4).force_encoding(Encoding::UTF_8).scrub[0, ERROR_LIMIT]
      end

      # Transpilers name the file they were given, which here is a temporary
      # path meaning nothing to the operator.
      def scrub(message, dir)
        message.gsub("#{dir}/", "").gsub(dir, "").gsub(/\bscript\.\w+\b/, "your script").strip
      end
    end
  end
end
