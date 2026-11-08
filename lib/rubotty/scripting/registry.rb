# frozen_string_literal: true

module Rubotty
  module Scripting
    # The host functions a script is allowed to call, and the only place a
    # name a script uses turns into Ruby that runs. This is the security
    # boundary of the whole feature: `webhook("ops-alert")` has to resolve
    # against the community's approved list, and the script must never see
    # a URL, whether or not Lua runs in this process. Built once at wiring
    # time and read only afterwards; per-invocation spending lives in
    # {Budget} (held by {Child}), so one registry serves every community
    # without invocations interfering.
    class Registry
      # How many host calls one invocation may make before it is cut off: a
      # runaway guard, since a round trip over the pipe measures 0.003 ms, so
      # this ceiling was never sized around what a call costs.
      # {DEFAULT_MAX_BROADCASTS} actually holds down the calls that cost
      # something, and {Child::DEFAULT_TIMEOUT} is the real backstop for slow
      # handlers, since a thousand recall()s is a thousand database queries
      # and ten seconds arrives long before the count does.
      DEFAULT_MAX_CALLS = 1024

      # How many of those calls may reach people: notify, warn and alert, the
      # ones with a real cost behind them. Five is a rule that has something
      # to say, past that is a rule shouting; blowing this is not fatal,
      # since the call just answers `false` like any other refusal, and only
      # the call total above actually kills the invocation.
      DEFAULT_MAX_BROADCASTS = 5

      # What a class of call is charged: :free costs nothing (pure string
      # work like formatting helpers, escape, truncate, mention), :read costs
      # one against the total (anything with a lookup, query or write behind
      # it), and :broadcast costs one against the total plus one against the broadcast cap.
      COSTS = %i[free read broadcast].freeze

      attr_reader :max_calls, :max_broadcasts

      def initialize(max_calls: DEFAULT_MAX_CALLS, max_broadcasts: DEFAULT_MAX_BROADCASTS)
        @functions = {}
        @costs = {}
        @max_calls = max_calls
        @max_broadcasts = max_broadcasts
      end

      # Declare a host function: the block receives the arguments the script
      # passed, already decoded, and whatever it returns is encoded back;
      # +cost+ is declared alongside it, defaulting to :read. Keep the
      # handler fast: it runs while the child sits blocked on the pipe with
      # the invocation's wall clock still ticking, so anything slow should
      # enqueue work and return, exactly as async_http() is meant to.
      def register(name, cost: :read, &handler)
        raise ArgumentError, "a host function needs a block" if handler.nil?
        raise ArgumentError, "#{cost.inspect} is not a call cost" unless COSTS.include?(cost)

        @functions[name.to_s] = handler
        @costs[name.to_s] = cost
        self
      end

      # What one call by this name is charged. An unknown name reads as :read,
      # which is what the unknown-function error below is about to cost anyway.
      def cost_of(name) = @costs.fetch(name.to_s, :read)

      # The names handed to the child so it can install a stub per function.
      def names = @functions.keys

      def registered?(name) = @functions.key?(name.to_s)

      # Run one host call. An unknown name is the script's mistake and is
      # reported back to it as an error rather than killing the invocation,
      # since a typo in a script should read like a typo.
      def call(name, args)
        handler = @functions[name.to_s]
        raise UnknownHostFunction, "no host function called #{name.to_s.inspect}" if handler.nil?

        handler.call(*args)
      end
    end
  end
end
