# frozen_string_literal: true

module Rubotty
  module Scripting
    # Kernel enforced memory ceiling on a script's process, and whether this platform can
    # apply one. `rlimit_as` stops something like `("x"):rep(1e12)` from taking the bot's
    # memory with it, held from the child's first instruction, so it works even against a
    # script that cooperates in no way. Darwin refuses it (RLIMIT_AS maps to a limit it
    # doesn't implement, so every spawn carrying one fails EINVAL), which is what
    # {OPTIONAL} is for, on a developer's machine; {REQUIRED} stays the default everywhere
    # else.
    module Limits
      # Whether a deployment refuses to run scripts it cannot cap.
      SETTING = "RUBOTTY_SCRIPT_LIMITS"
      REQUIRED = "required"
      OPTIONAL = "optional"

      # What the probe asks for. The same order of magnitude as the real
      # ceiling, since what is being measured is whether the platform takes the
      # limit at all.
      PROBE_BYTES = 256 * 1024 * 1024

      module_function

      # Whether an address space ceiling really applies here. Measured rather
      # than assumed: a throwaway child sets one on itself, and its exit status
      # is the answer.
      def available?
        return @available if defined?(@available)

        @available = applies?
      end

      # What the operator asked for. Anything unrecognised counts as
      # {REQUIRED}, since refusing is the safe direction to guess in.
      def setting(env = ENV) = env[SETTING].to_s.strip.downcase == OPTIONAL ? OPTIONAL : REQUIRED

      def required?(env = ENV) = setting(env) == REQUIRED

      def satisfied?(env = ENV) = available? || !required?(env)

      def require!(env = ENV)
        return if satisfied?(env)

        raise Unavailable,
              "operator scripts are turned off because this platform will not cap what one can " \
              "allocate: #{reason}. Set #{SETTING}=#{OPTIONAL} to run them with the time budget as " \
              "the only bound instead."
      end

      def reason
        return nil if available?

        "#{RbConfig::CONFIG["host_os"]} refused rlimit_as for a child of this process"
      end

      # One line for the startup checks.
      def describe(env = ENV)
        if available?
          "A script's process is capped at #{PROBE_BYTES / 1024 / 1024} MB of address space, which " \
            "the kernel holds from its first instruction."
        elsif required?(env)
          "Operator scripts are OFF: #{reason}. Set #{SETTING}=#{OPTIONAL} to run them with the " \
            "time budget as the only bound."
        else
          "A script's process runs with no memory ceiling, so the time budget and the kill are the " \
            "only bounds on it: #{reason}. #{SETTING}=#{OPTIONAL} says that is deliberate."
        end
      end

      # Forget the probe. Only tests need this.
      def reset!
        remove_instance_variable(:@available) if defined?(@available)
      end

      # Set on the child rather than asked about, because a platform can carry
      # the constant and still refuse the call. Nothing runs after it, so a
      # ceiling below what this process has already mapped costs nothing.
      def applies?
        pid = fork do
          $stderr.reopen(File::NULL, "w")
          begin
            Process.setrlimit(Process::RLIMIT_AS, PROBE_BYTES)
          rescue StandardError, SystemCallError
            exit!(1)
          end
          exit!(0)
        end
        Process.waitpid2(pid)&.last&.exitstatus&.zero? || false
      rescue NotImplementedError, NameError, SystemCallError
        false
      end
    end
  end
end
