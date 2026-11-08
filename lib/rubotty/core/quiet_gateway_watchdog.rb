# frozen_string_literal: true

require "monitor"

module Rubotty
  module Core
    # One supervised thread that notices a receiving endpoint whose
    # connection has stopped delivering while the room around it keeps
    # moving. A plain silence timer can't tell a stalled connection from a
    # genuinely quiet room, so this looks for a sibling instead: another
    # (adapter_name, account) endpoint in the same room still receiving
    # natively is what turns silence into evidence of a stall. With no such
    # sibling, or if siblings are equally quiet, it gives no verdict, since a
    # false reconnect is worse than a missed one.
    class QuietGatewayWatchdog
      # How long a receiving endpoint may go without its OWN inbound activity
      # before it becomes a stall candidate, seconds.
      DEFAULT_THRESHOLD = 1800

      # How often a pass runs, seconds.
      DEFAULT_INTERVAL = 300

      # How many times its own established cadence an endpoint has to be quiet
      # for before the silence counts as broken behaviour rather than a lull.
      CADENCE_MULTIPLE = 4

      # One endpoint judged stalled: quiet past +threshold+ with at least one
      # sibling proving the room is alive elsewhere.
      Verdict = Struct.new(:adapter_key, :endpoint, :quiet_for, :corroborated_by, keyword_init: true)

      # @param adapters [Hash{Array=>Adapters::Base}] keyed the same way
      #   {Core::Runtime} keys its own, so a verdict's adapter_key resolves
      #   straight to the live adapter instance.
      # @param reconnect [#call, nil] called with (adapters, reason:) on a fresh
      #   verdict, expected to be {GatewayCycle#reconnect}. Nil logs the verdict
      #   and stops there: detection and the loud log, no automatic reconnect.
      def initialize(topology:, activity:, adapters:, logger: nil, threshold: DEFAULT_THRESHOLD,
                     interval: DEFAULT_INTERVAL, clock: -> { Time.now.utc }, reconnect: nil)
        @topology = topology
        @activity = activity
        @adapters = adapters
        @logger = logger
        @threshold = threshold
        @interval = interval
        @clock = clock
        @reconnect = reconnect
        @monitor = Monitor.new
        @wake = Thread::Queue.new
        @thread = nil
        @running = false
        # adapter_key => Time the action last latched for it. Cleared the
        # moment a later pass no longer finds that adapter stalled, so a fresh
        # episode after a real recovery is acted on again.
        @acted = {}
        # adapter_key => Verdict, the CURRENT ground truth. Read by
        # Core::Runtime#healthy?, so it reflects now rather than the moment the
        # action fired.
        @stalled = {}
        @failure = nil
        @ticks = 0
      end

      attr_reader :threshold, :interval

      # Start the one watchdog thread. Idempotent.
      def start
        @monitor.synchronize do
          return self if @running

          @running = true
          @failure = nil
          @wake.clear
          @thread = Thread.new { supervise }
        end
        @logger&.info do
          "quiet gateway watchdog: checking every #{@interval}s for #{@threshold}s of silence " \
            "on a gateway endpoint whose room siblings kept moving"
        end
        self
      end

      # Stop the thread. The wait is woken rather than waited out.
      def stop
        thread = @monitor.synchronize do
          @running = false
          current = @thread
          @thread = nil
          current
        end
        return self if thread.nil?

        @wake << :stop
        thread.join(1)
        thread.kill if thread.alive?
        self
      end

      def running? = @monitor.synchronize { @running }

      # Whether the thread is still there to run the next pass. One that was
      # never started is healthy, the terms every other supervised thread here
      # is judged on.
      def healthy?
        @monitor.synchronize do
          return true unless @running

          !@thread.nil? && @thread.alive?
        end
      end

      # Why the watchdog thread died, or nil.
      def failure = @monitor.synchronize { @failure }

      # How many passes have run. Diagnostics and tests.
      def ticks = @monitor.synchronize { @ticks }

      # adapter_key => Verdict for every adapter CURRENTLY judged stalled,
      # empty when nothing is wrong. Level triggered: unlike the action, this
      # is recomputed on every pass rather than latched, so it stays accurate
      # for as long as the condition persists.
      def stalled = @monitor.synchronize { @stalled.dup }

      def stalled? = !stalled.empty?

      # Run one pass right now. Public so a spec, and the first pass after
      # boot, can drive it synchronously rather than waiting on the thread.
      #
      # @return [Hash] adapter_key => Verdict, the same shape {#stalled} reads
      def tick(now = utc_now)
        verdicts = evaluate(now)
        fresh = @monitor.synchronize do
          @stalled = verdicts
          # Forget the latch for anything that no longer verdicts as stalled,
          # so a real recovery lets a later stall be acted on again.
          @acted.keep_if { |key, _| verdicts.key?(key) }
          new_keys = verdicts.keys - @acted.keys
          new_keys.each { |key| @acted[key] = now }
          @ticks += 1
          new_keys
        end
        fresh.each { |key| act(key, verdicts[key]) }
        verdicts
      end

      private

      def utc_now = @clock.call.utc

      # Every gateway endpoint quiet past its own patience with at least one
      # corroborating sibling, grouped by the adapter a verdict against it
      # would reconnect. One endpoint is enough to indict its whole adapter;
      # a second stalled endpoint on the SAME adapter adds no new verdict.
      def evaluate(now)
        by_adapter = {}
        @topology.endpoints.select(&:receives?).each do |endpoint|
          next unless gateway?(endpoint)

          silence = quiet_for(endpoint, now)
          next if silence.nil? || silence < patience_for(endpoint)

          siblings = corroborating_siblings(endpoint, now)
          next if siblings.empty?

          key = adapter_key(endpoint)
          by_adapter[key] ||= Verdict.new(adapter_key: key, endpoint: endpoint, quiet_for: silence,
                                           corroborated_by: siblings)
        end
        by_adapter
      end

      # Whether +endpoint+ belongs to an adapter holding a gateway open, the one
      # kind of endpoint whose silence can mean a connection has stalled. An
      # adapter this process does not hold is left alone too: there is nothing
      # to judge and nothing to reconnect.
      def gateway?(endpoint)
        adapter = @adapters[adapter_key(endpoint)]
        !adapter.nil? && GatewayCycle.persistent?(adapter)
      end

      # Seconds since +endpoint+ last delivered a message of its own, or nil
      # when it never has. An endpoint with nothing behind it gives no verdict
      # either way, the same fail safe a room with no sibling gets.
      def quiet_for(endpoint, now)
        last = @activity.last_seen(endpoint.id)
        last && now - last
      end

      # How long +endpoint+ has to stay silent before it is a candidate: the
      # configured threshold, raised to a multiple of its own delivery cadence
      # once enough has arrived to know one.
      def patience_for(endpoint)
        cadence = @activity.typical_gap(endpoint.id)
        return @threshold if cadence.nil?

        [@threshold, cadence * CADENCE_MULTIPLE].max
      end

      # Every OTHER gateway endpoint sharing a room with +endpoint+, on a
      # different (adapter_name, account), that is itself NOT quiet right
      # now: proof the room is alive on a second platform connection, the
      # only thing that turns "nothing arrived" into "this connection
      # stalled" rather than "quiet night". A guest or API post doesn't
      # count: it proves only that somebody reached the room through this
      # process, not what a platform was delivering natively.
      def corroborating_siblings(endpoint, now)
        siblings = @topology.rooms_for(endpoint.id).flat_map(&:endpoints).uniq(&:id)
        siblings.select do |sibling|
          next false unless sibling.id != endpoint.id && sibling.receives? && gateway?(sibling)
          next false if adapter_key(sibling) == adapter_key(endpoint)

          silence = quiet_for(sibling, now)
          !silence.nil? && silence < @threshold
        end
      end

      def adapter_key(endpoint) = [endpoint.adapter_name, endpoint.account]

      # Log once and hand the verdict to the reconnect callable, if any. Called
      # only for an adapter_key that just went from healthy to stalled, never
      # for one already latched, which is what keeps this to one action per
      # episode rather than one per pass.
      def act(adapter_key, verdict)
        announce(adapter_key, verdict)
        perform_reconnect(adapter_key, verdict)
      end

      def announce(adapter_key, verdict)
        adapter_name, account = adapter_key
        others = verdict.corroborated_by.map(&:id).join(", ")
        @logger&.error do
          "quiet gateway: #{adapter_name}/#{account} was delivering on #{verdict.endpoint.id} until " \
            "#{verdict.quiet_for.round}s ago and has been silent since, past anything that endpoint's own " \
            "traffic explains, while #{others} in the same room kept moving. " \
            "That connection looks stalled rather than idle."
        end
      end

      def perform_reconnect(adapter_key, verdict)
        return if @reconnect.nil?

        adapter = @adapters[adapter_key]
        if adapter.nil?
          @logger&.warn { "quiet gateway: no live adapter for #{adapter_key.join("/")}, cannot reconnect it" }
          return
        end

        @reconnect.call([adapter], reason: "quiet gateway: #{verdict.endpoint.id} stalled")
      rescue StandardError => e
        @logger&.warn { "quiet gateway: reconnecting #{adapter_key.join("/")} failed: #{e.class}: #{e.message}" }
      end

      def supervise
        Thread.current.name = "quiet-gateway-watchdog"
        loop do
          signal = @wake.pop(timeout: @interval)
          break if signal == :stop
          break unless running?

          tick
        end
      rescue Exception => e # rubocop:disable Lint/RescueException
        detail = "#{e.class}: #{e.message}"
        @monitor.synchronize { @failure = detail }
        @logger&.error do
          "the quiet gateway watchdog thread died, a stalled gateway will NOT be noticed " \
            "until this process restarts: #{detail}"
        end
        nil
      end
    end
  end
end
