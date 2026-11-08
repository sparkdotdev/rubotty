# frozen_string_literal: true

module Rubotty
  module Scripting
    # What one invocation has spent of its host call allowance. Two ceilings
    # rather than one: cost varies (`bold("x")` versus `notify` reaching every
    # bridged platform), so charging both the same would starve pure string
    # work. The total guards against a loop; the smaller broadcast ceiling
    # holds down calls that reach people. Held per invocation and dropped
    # with it, apart from the shared {Registry}, so one script's spending
    # never leaks into the next community's run.
    class Budget
      # What {#charge} answers: :allowed serves the call, :broadcast_spent
      # refuses this call but the script carries on, and :spent ends the invocation.
      ALLOWED = :allowed
      BROADCAST_SPENT = :broadcast_spent
      SPENT = :spent

      def initialize(max_calls: Registry::DEFAULT_MAX_CALLS,
                     max_broadcasts: Registry::DEFAULT_MAX_BROADCASTS)
        @max_calls = max_calls
        @max_broadcasts = max_broadcasts
        @calls = 0
        @broadcasts = 0
      end

      attr_reader :max_calls, :max_broadcasts, :calls, :broadcasts

      # The ceilings +registry+ asks for, or the defaults when an invocation was
      # given no host functions at all.
      def self.for(registry)
        return new if registry.nil?

        new(max_calls: registry.max_calls, max_broadcasts: registry.max_broadcasts)
      end

      # Spend one call of +cost+ and say whether it may go ahead. A refused
      # broadcast is still counted against the total: it cost the round trip
      # either way, and a script that ignores the refusal and keeps asking
      # should still reach the runaway guard rather than loop for free.
      def charge(cost)
        return ALLOWED if cost == :free

        @calls += 1
        return SPENT if @calls > @max_calls
        return ALLOWED unless cost == :broadcast

        @broadcasts += 1
        @broadcasts > @max_broadcasts ? BROADCAST_SPENT : ALLOWED
      end

      # What the script is told when a broadcast is refused. Written as an
      # ordinary refusal because that is what it is: the reason says which
      # function was refused and why, so an operator reading it in a trace or in
      # their own error branch knows what to change.
      def broadcast_refusal(name)
        "#{name} was not sent: a script may make #{@max_broadcasts} calls that reach people " \
          "in one run, and this is number #{@broadcasts}"
      end

      # What an operator is told when the invocation is cut off. Naming the
      # function is the whole point: the old message named none, so a dead
      # script left nothing to look for in a hundred lines of Lua.
      def exhausted_reason(name)
        "the script made more than #{@max_calls} host calls, and #{name} was the one that ran out"
      end
    end
  end
end
