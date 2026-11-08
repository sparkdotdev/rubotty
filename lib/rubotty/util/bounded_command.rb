# frozen_string_literal: true

module Rubotty
  module Util
    # Runs an external encoder under a wall clock deadline and kills it when
    # it overruns: a fresh child per invocation, the deadline parked in the
    # kernel on IO.select rather than polled, and SIGKILL on expiry, which no
    # amount of work inside the child can ignore (the same shape
    # {Scripting::Compiler} uses). The process group matters as much as the
    # deadline: an encoder invoked through a wrapper, or one that forks a
    # helper, would leave the deadline killing a parent and orphaning the
    # thing actually burning the CPU.
    class BoundedCommand
      # What the child said, and whether it finished at all.
      Result = Struct.new(:status, :stdout, :stderr, :timed_out, keyword_init: true) do
        def ok? = !timed_out && !status.nil? && status.success?

        def timed_out? = !!timed_out
      end

      # How much of an encoder's complaint is kept, since the useful part is at
      # the front and ffmpeg in particular writes a great deal.
      ERROR_LIMIT = 500

      # Neither pipe may make the relay retain unlimited encoder output.
      # ffprobe's selected fields fit here; excess output fails the operation.
      OUTPUT_LIMIT = 1024 * 1024

      # The only names copied into an encoder's environment: everything else
      # in this process's ENV, bot tokens and DATABASE_URL included, stays
      # out. TMPDIR rides along since ffmpeg and ImageMagick can spill
      # scratch data beyond the input and output paths this class hands
      # them, and losing it would silently move that spill wherever the
      # platform defaults to.
      SAFE_ENV_VARS = %w[PATH HOME LANG TMPDIR].freeze
      IMAGE_POLICY_DIRECTORY = File.expand_path("../../../config/imagemagick", __dir__)

      # @param timeout [Numeric] seconds of wall clock before the group is killed
      # @param memory_bytes [Integer, nil] address space ceiling, or nil for none
      # @param nice [Integer, nil] how far below the relay to run. Applied by
      #   invoking through the coreutils binary, since Process.spawn has no
      #   priority option and there is no pre-exec hook to set one from.
      def initialize(timeout:, memory_bytes: nil, nice: nil, logger: nil)
        @timeout = timeout
        @memory_bytes = memory_bytes
        @nice = nice
        @logger = logger
      end

      # @param argv [Array<String>] the command and its arguments, never a
      #   string: nothing here is parsed by a shell, so a filename with a space
      #   or a leading dash in it is an argument and only an argument.
      # @return [Result]
      def run(argv)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @timeout
        out_read, out_write = IO.pipe
        err_read, err_write = IO.pipe
        pid = spawn_child(niced(argv), out_write, err_write)
        [out_write, err_write].each(&:close)
        streams = drain(pid, out_read, err_read, deadline)
        return Result.new(timed_out: true, stdout: "", stderr: "") if streams.nil?
        if streams == :output_limit
          return Result.new(timed_out: false, stdout: "", stderr: "encoder output limit exceeded")
        end

        status = wait(pid, deadline)
        return Result.new(timed_out: true, stdout: "", stderr: "") if status == :timed_out

        Result.new(status: status, stdout: streams[0],
                   stderr: streams[1].strip[0, ERROR_LIMIT], timed_out: false)
      rescue Errno::ENOENT => e
        Result.new(stdout: "", stderr: e.message, timed_out: false)
      ensure
        [out_read, err_read, out_write, err_write].each { |io| io&.close unless io&.closed? }
      end

      private

      # nice execs in place, so the pid handed back is still the encoder's own
      # and the deadline signals the right group.
      def niced(argv) = @nice ? ["nice", "-n", @nice.to_s, *argv] : argv

      # Most limited first, and a loop rather than a second rescue, because
      # Darwin refuses rlimit_as outright and one bad limit rejects the whole
      # spawn. Where a limit is refused the deadline is still the real bound.
      def spawn_child(argv, out_write, err_write)
        options = { out: out_write, err: err_write, close_others: true, unsetenv_others: true, pgroup: true }
        attempts = limit_attempts

        attempts.each_with_index do |limits, index|
          return Process.spawn(safe_env, *argv, **options, **limits)
        rescue Errno::EINVAL
          raise if index == attempts.length - 1
        end
      end

      # {SAFE_ENV_VARS}, limited to the ones actually set.
      def safe_env
        SAFE_ENV_VARS.each_with_object({ "MAGICK_CONFIGURE_PATH" => IMAGE_POLICY_DIRECTORY }) do |name, env|
          env[name] = ENV[name] if ENV.key?(name)
        end
      end

      def limit_attempts
        cpu = @timeout.ceil
        return [{ rlimit_cpu: cpu }, {}] if @memory_bytes.nil?

        [{ rlimit_as: @memory_bytes, rlimit_cpu: cpu }, { rlimit_cpu: cpu }, {}]
      end

      # @return [Array(String, String), Symbol, nil] stdout and stderr, or a
      #   refusal after killing a child that exceeds its deadline or output limit
      def drain(pid, out_read, err_read, deadline)
        buffers = { out_read => +"", err_read => +"" }
        open = buffers.keys.dup

        until open.empty?
          left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          return expire(pid) if left <= 0

          ready = IO.select(open, nil, nil, left)
          return expire(pid) if ready.nil?

          ready[0].each do |io|
            read = read_into(buffers[io], io)
            if read == :output_limit
              @logger&.warn { "an encoder exceeded the output limit and was stopped" }
              kill(pid)
              return :output_limit
            end
            open.delete(io) unless read
          end
        end
        [buffers[out_read], buffers[err_read]]
      end

      # @return [Boolean, Symbol] EOF, more data, or an output-limit refusal
      def read_into(buffer, io)
        chunk = io.read_nonblock(4096, exception: false)
        return false if chunk.nil?

        return :output_limit if chunk != :wait_readable && buffer.bytesize + chunk.bytesize > OUTPUT_LIMIT

        buffer << chunk unless chunk == :wait_readable
        true
      end

      def expire(pid)
        @logger&.warn { "an encoder overran #{@timeout} seconds and was stopped" }
        kill(pid)
        nil
      end

      def kill(pid)
        Process.kill("KILL", -pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      ensure
        # Reaping must not extend the caller's deadline if a native process is
        # stuck in kernel I/O. The detached waiter still collects its exit.
        begin
          Process.detach(pid)
        rescue Errno::ECHILD
          nil
        end
      end

      def wait(pid, deadline)
        loop do
          result = Process.wait2(pid, Process::WNOHANG)
          return result.last if result

          left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          if left <= 0
            expire(pid)
            return :timed_out
          end
          IO.select(nil, nil, nil, [left, 0.01].min)
        end
      rescue Errno::ECHILD
        nil
      end
    end
  end
end
