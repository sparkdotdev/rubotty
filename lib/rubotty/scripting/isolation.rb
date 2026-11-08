# frozen_string_literal: true

require "etc"

module Rubotty
  module Scripting
    # The account a script's process runs as, the layer outside the Lua
    # sandbox: sandbox.lua is a deny list, and Lua metaprogramming is what
    # eats deny lists, so it can't be the only thing between a script
    # somebody typed and a process holding every platform's bot token. Hands
    # every child a different, unprivileged account: os.execute gets a shell
    # that can't read this process's environment, ptrace it, signal it, or
    # own any file on disk. There is no namespace (CAP_SYS_ADMIN is
    # unavailable here), so a confined script still reaches the network and reads world readable files.
    module Isolation
      # Whether a deployment refuses to run scripts it cannot confine.
      # "required" is the default; "optional" is an operator saying out loud
      # that they accept scripts running in this process's own account.
      SETTING = "RUBOTTY_SCRIPT_ISOLATION"
      REQUIRED = "required"
      OPTIONAL = "optional"

      # Which account to hand a child, by name or by number, for a deployment
      # that made one on purpose.
      ACCOUNT = "RUBOTTY_SCRIPT_USER"

      # Where to look when nothing was asked for. nobody and nogroup are 65534
      # on Debian and Ubuntu, and 65534 is the kernel's overflow id everywhere,
      # so it stays a valid id to become even on an image carrying no such
      # passwd entry.
      DEFAULT_NAMES = %w[rubotty-script nobody].freeze
      FALLBACK_ID = 65_534

      # Stands in for an Etc::Passwd when an operator named an account by
      # number, which an image may have without carrying a passwd entry for it.
      Account = Struct.new(:uid, :gid)

      module_function

      # The uid and gid a child runs as, or nil when this process cannot hand
      # out an account at all.
      def account
        return @account if defined?(@account)

        @account = resolve
      end

      def available? = !account.nil?

      # What Process.spawn needs to put a child in that account. Empty when
      # there is none, which only gets as far as a spawn when the operator
      # asked for {OPTIONAL}.
      def spawn_options = account || {}

      # What the operator asked for. Anything unrecognised counts as
      # {REQUIRED}, since refusing is the safe direction to guess in.
      def setting(env = ENV) = env[SETTING].to_s.strip.downcase == OPTIONAL ? OPTIONAL : REQUIRED

      def required?(env = ENV) = setting(env) == REQUIRED

      # Whether this deployment is in a state it agreed to run scripts in.
      def satisfied?(env = ENV) = available? || !required?(env)

      # Raised rather than logged: a script running unconfined on a deployment
      # that asked for confinement is the thing this refuses to do quietly.
      def require!(env = ENV)
        return if satisfied?(env)

        raise Unavailable,
              "operator scripts are turned off because they cannot be confined here: #{reason}. " \
              "Set #{SETTING}=#{OPTIONAL} to run them in this process's own account instead."
      end

      # Why there is no account to hand out. Present whenever {available?} is
      # false and worth showing an operator either way.
      def reason(env = ENV)
        return nil if available?

        unless Process.euid.zero?
          return "this process does not run as root, so it cannot start a child under another account"
        end

        "no unprivileged account to run a script under (looked for #{wanted(env).join(", ")})"
      end

      # The account names this deployment would use, for a message.
      def wanted(env = ENV)
        named = env[ACCOUNT].to_s.strip
        named.empty? ? DEFAULT_NAMES : [named]
      end

      # Hand +paths+ to the script account, so a child can read the source it
      # was given and write next to it. A no-op when there is no account.
      def grant(*paths)
        target = account
        return if target.nil?

        paths.each { |path| File.chown(target[:uid], target[:gid], path) }
      rescue SystemCallError => e
        raise Unavailable, "could not hand the script account its working directory: #{e.message}"
      end

      # Whether the script account could actually get to +path+: every
      # directory above it traversable and the file itself readable, using
      # world bits only since the account shares no group with this process
      # (true when there is no account, since nothing has moved). Otherwise
      # an unreadable image would turn every script into a child that exits
      # silently, which is miserable to diagnose from a chat room.
      def reachable?(path)
        return true if account.nil?

        file, *directories = ancestors(File.expand_path(path))
        return false if File.stat(file).world_readable?.nil?

        directories.all? { |dir| File.stat(dir).mode.anybits?(0o001) }
      rescue SystemCallError
        false
      end

      # +path+ and every directory above it, innermost first.
      def ancestors(path)
        walked = []
        while path != File.dirname(path)
          walked << path
          path = File.dirname(path)
        end
        walked << path
      end

      # One line about where scripts run, for the startup checks.
      def describe(env = ENV)
        if available?
          "Operator scripts run as uid #{account[:uid]} (gid #{account[:gid]}), so a script that gets " \
            "out of the Lua sandbox lands in an account that owns nothing here."
        elsif required?(env)
          "Operator scripts are OFF: #{reason}. Set #{SETTING}=#{OPTIONAL} to run them in this " \
            "process's own account instead, which is the account holding every bot token."
        else
          "Operator scripts run in this process's own account, which holds every bot token: #{reason}. " \
            "#{SETTING}=#{OPTIONAL} says that is deliberate."
        end
      end

      # Forget the resolved account. Only tests need this.
      def reset!
        remove_instance_variable(:@account) if defined?(@account)
      end

      # Becoming another account needs root, and there is nothing to become
      # when the only account on offer is this one.
      def resolve(env = ENV)
        return nil unless Process.euid.zero?

        entry = passwd_entry(env)
        return nil if entry.nil? || !entry.uid.positive?

        { uid: entry.uid, gid: entry.gid }
      end

      # The account an operator named, the first of {DEFAULT_NAMES} the image
      # carries, or the fallback id when it carries none of them; a number is
      # taken at face value, since an image may well have the account without
      # the passwd entry. A name that is not there resolves to nothing, so a
      # typo turns scripts off rather than quietly running them elsewhere.
      def passwd_entry(env)
        named = env[ACCOUNT].to_s.strip
        return numbered(named) if named.match?(/\A\d+\z/)
        return lookup(named) unless named.empty?

        DEFAULT_NAMES.filter_map { |name| lookup(name) }.first || Account.new(FALLBACK_ID, FALLBACK_ID)
      end

      def numbered(text)
        id = Integer(text, 10)
        Account.new(id, id)
      end

      def lookup(name)
        Etc.getpwnam(name)
      rescue ArgumentError
        nil
      end
    end
  end
end
