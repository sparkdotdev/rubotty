# frozen_string_literal: true

module Rubotty
  module Core
    # Decouples adapter receive loops from delivery work: {#call} must
    # return quickly, since a slow Discord write must not stall Telegram
    # polling and vice versa. Messages that fan out to the SAME set of rooms
    # are delivered in receive order. Rooms connected through a shared endpoint
    # use one serial worker, so fan-out from overlapping rooms cannot overtake
    # earlier messages. Policy and accounting run once per inbound event.
    class Dispatcher
      DEFAULT_QUEUE_LIMIT = 1_000
      Worker = Struct.new(:room_ids, :endpoint_ids, :signature, :queue, :thread, keyword_init: true)

      # @param activity [InboundActivity, nil] where the last-inbound moment of
      #   every receiving endpoint is recorded, touched on every message this
      #   dispatcher is handed. Nil keeps no such record, which is fine for a
      #   spec that has no use for it.
      def initialize(topology:, router:, logger:, queue_limit: DEFAULT_QUEUE_LIMIT, activity: nil)
        @topology = topology
        @router = router
        @logger = logger
        @queue_limit = queue_limit
        @activity = activity
        @queues = {}
        @threads = {}
        @workers = {}
        @retired_workers = []
        @running = false
        @mutex = Mutex.new
        # endpoint id => how many of its messages have been discarded for
        # belonging to no room. See #note_discard.
        @stranded = {}
        @stranded_mutex = Mutex.new
        # How many messages this dispatcher owes an answer for. See #drain.
        @inflight = 0
        @inflight_mutex = Mutex.new
        @settled = ConditionVariable.new
      end

      attr_reader :logger, :topology

      def start
        @mutex.synchronize do
          return self if @running

          @running = true
          routing_rooms_locked
          reconcile_workers_locked
        end
        self
      end

      # Adapters call this; never blocks on delivery. The message is counted as
      # in flight here, before the topology is even consulted, so {#drain}
      # covers the whole handover.
      def call(message)
        enter
        begin
          @activity&.touch(message.origin.id)
          @mutex.synchronize do
            # Use one immutable topology snapshot for routing and reconciliation.
            # A later snapshot creates dependent worker generations below.
            snapshot = @topology.rooms
            routing_rooms_locked(snapshot)
            rooms = snapshot.select { |room| room.include?(message.origin.id) }
            if rooms.empty?
              reconcile_workers_locked
              note_discard(message)
              return
            end

            clear_stranded(message.origin.id)
            enqueue_locked(@routing_rooms.fetch(rooms.first.unique_id), message)
          end
        ensure
          leave
        end
      end
      alias << call

      # Endpoint id => how many of its messages have been discarded for belonging
      # to no room. An endpoint that starts routing again drops out, so this only
      # ever describes what is stranded RIGHT NOW.
      def stranded_endpoints = @stranded_mutex.synchronize { @stranded.dup }

      # Room unique id => how many messages are waiting on its worker. Each
      # room's worker is serial, so depth IS lag: a room whose delivery has
      # stalled shows here before anything else says so. A queue at zero is
      # left out, since a bridge at rest is every room reading zero.
      def queue_depths
        pairs = @mutex.synchronize { @queues.map { |id, queue| [id, queue.size] } }
        pairs.reject { |(_, depth)| depth.zero? }.sort_by { |(id, depth)| [-depth, id] }.to_h
      end

      # A message whose endpoint belongs to no room reaches nobody, and that is
      # REAL MESSAGE LOSS: warn the FIRST time an endpoint strands, then fall
      # back to debug for the flood that follows. The count accrues either way.
      def note_discard(message)
        id = message.origin.id.to_s
        first = @stranded_mutex.synchronize do
          @stranded[id] = (@stranded[id] || 0) + 1
          @stranded[id] == 1
        end

        if first
          logger.warn do
            "no room contains #{id}, so every message sent there is being discarded. " \
              "Map it from the dashboard's Discovered connections page, or run /identify-topic in it."
          end
        else
          logger.debug { "no room for endpoint #{id}, discarding #{message.ref}" }
        end
      end

      # Forget an endpoint the moment it routes again, so a LATER stranding warns
      # afresh rather than being absorbed into an old count.
      def clear_stranded(endpoint_id)
        id = endpoint_id.to_s
        return if @stranded.empty?

        @stranded_mutex.synchronize { @stranded.delete(id) }
      end

      def enqueue(room, message)
        # Topology reconciliation may retire queues. Keep selecting and pushing
        # atomic with retirement so a live reload cannot close our chosen queue.
        @mutex.synchronize do
          routing_rooms_locked
          enqueue_locked(@routing_rooms[room.unique_id] || room, message)
        end
      end

      def enqueue_locked(room, message)
        queue = queue_for_locked(room)
        if queue.nil?
          logger.warn { "dispatcher not started, dropping #{message.ref}" }
          return
        end

        # Bound memory without blocking the platform's receive loop.
        if queue.size >= @queue_limit
          dropped = begin
            queue.pop(true)
          rescue ThreadError
            nil
          end
          leave if dropped
          logger.warn { "room #{room.id} queue full, dropped #{dropped&.ref}" }
        end
        enter
        begin
          queue << message
        rescue StandardError
          leave
          raise
        end
      end
      private :enqueue_locked

      # Waits until every message this dispatcher has been handed has been
      # delivered, then returns true. In flight is tracked explicitly, from
      # {#call} until the router returns, since the queue shape alone can't see
      # a message still being routed on a receive thread; bounded on purpose, so
      # an adapter wedged inside a delivery can't hang a shutdown or a test
      # forever, and a timeout logs what's still outstanding and returns false.
      def drain(timeout: 5)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        outstanding = @inflight_mutex.synchronize do
          until @inflight.zero?
            # Monotonic, so a clock correction on a busy host cannot make the
            # deadline appear to have already passed.
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            break if remaining <= 0

            @settled.wait(@inflight_mutex, remaining)
          end
          @inflight
        end
        return true if outstanding.zero?

        logger.warn { "drain gave up after #{timeout}s with #{outstanding} message(s) still in flight" }
        false
      end

      def stop(timeout: 5)
        threads = nil
        @mutex.synchronize do
          return self unless @running

          @running = false
          threads = (@workers.values + @retired_workers).map(&:thread).uniq
          @queues.each_value(&:close)
          @queues = {}
          @threads = {}
          @workers = {}
          @retired_workers = []
        end
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        threads.each do |thread|
          remaining = [deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0].max
          thread.join(remaining)
          thread.kill if thread.alive?
        end
        # The queues went with the dispatcher, so anything still sitting in one
        # will never be handled now. Clearing the count keeps a later {#drain}
        # honest rather than making it wait out its timeout.
        @inflight_mutex.synchronize do
          @inflight = 0
          @settled.broadcast
        end
        self
      end

      def running? = @running

      private

      def enter
        @inflight_mutex.synchronize { @inflight += 1 }
      end

      # Clamped at zero because {#stop} clears the count while a worker that
      # outlived its join may still be finishing a message, and a negative count
      # would strand every later drain.
      def leave
        @inflight_mutex.synchronize do
          @inflight -= 1 if @inflight.positive?
          @settled.broadcast if @inflight.zero?
        end
      end

      # The room's queue, spawning it (and its worker thread) on first use, since
      # #start only builds queues for the rooms that exist AT BOOT and a room
      # created later would otherwise have no worker until the next restart.
      # Keyed on unique_id, never on id, since a room_key is unique only within
      # one community and two communities' identically named rooms would
      # otherwise share a queue and orphan a worker thread per boot.
      def queue_for(room)
        @mutex.synchronize do
          routing_rooms_locked
          queue_for_locked(@routing_rooms[room.unique_id] || room)
        end
      end

      def queue_for_locked(room)
        return nil unless @running

        reconcile_workers_locked
        @queues[room.unique_id]
      end

      # Close changed generations without waiting under the dispatcher mutex.
      # Their successors wait for overlapping predecessors inside their own
      # threads, draining old backlogs before processing any newer message.
      def reconcile_workers_locked
        return unless @running

        @retired_workers.reject! { |worker| !worker.thread.alive? }
        predecessors = @workers.values + @retired_workers
        @workers.keys.each do |id|
          worker = @workers[id]
          next if @routing_groups[id] && @routing_groups[id][:signature] == worker.signature

          worker.queue.close
          @retired_workers << worker
          @workers.delete(id)
          @queues.delete(id)
          @threads.delete(id)
        end
        @routing_groups.each do |id, group|
          next if @workers.key?(id)

          dependencies = predecessors.select do |worker|
            !(worker.room_ids & group[:room_ids]).empty? ||
              !(worker.endpoint_ids & group[:endpoint_ids]).empty?
          end.map(&:thread).uniq
          queue = Thread::Queue.new
          thread = spawn_worker(group[:room], queue, predecessors: dependencies)
          @workers[id] = Worker.new(room_ids: group[:room_ids], endpoint_ids: group[:endpoint_ids],
                                    signature: group[:signature], queue: queue, thread: thread)
          @queues[id] = queue
          @threads[id] = thread
        end
      end

      # Overlapping rooms share side effects, so all their origins must use the
      # same serial worker. Independent connected groups still run concurrently.
      def routing_rooms_locked(rooms = @topology.rooms)
        return @routing_rooms if @routing_snapshot.equal?(rooms)

        parents = rooms.to_h { |room| [room.unique_id, room.unique_id] }
        root = lambda do |id|
          parents[id] = parents[parents[id]] while parents[id] != parents[parents[id]]
          parents[id]
        end
        owners = {}
        rooms.each do |room|
          room.endpoints.each do |endpoint|
            prior = owners[endpoint.id]
            if prior
              left, right = root.call(prior), root.call(room.unique_id)
              parents[right] = left
            else
              owners[endpoint.id] = room.unique_id
            end
          end
        end
        @routing_groups = {}
        @routing_rooms = rooms.group_by { |room| root.call(room.unique_id) }.values.each_with_object({}) do |group, map|
          representative = group.min_by { |room| room.unique_id.to_s }
          @routing_groups[representative.unique_id] = {
            room: representative, room_ids: group.map(&:unique_id),
            endpoint_ids: group.flat_map(&:endpoints).map(&:id).uniq,
            signature: group.map { |room| [room.unique_id, room.endpoints.map(&:id).sort] }.sort
          }
          group.each { |room| map[room.unique_id] = representative }
        end
        @routing_snapshot = rooms
        @routing_rooms
      end

      def spawn_worker(room, queue, predecessors: [])
        Thread.new do
          Thread.current.name = "room-#{room.unique_id}"
          predecessors.each(&:join)
          predecessors.clear
          while (message = queue.pop)
            begin
              @router.handle(message)
            rescue StandardError => e
              # One malformed message must not take down a room's worker.
              logger.error { "unhandled error routing #{message.ref}: #{e.class}: #{e.message}" }
              logger.debug { e.backtrace&.first(10)&.join("\n") }
            ensure
              # Delivery is over either way, so the message stops being in flight
              # here rather than only on the happy path.
              leave
            end
          end
        end
      end
    end
  end
end
