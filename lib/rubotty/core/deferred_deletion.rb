# frozen_string_literal: true

module Rubotty
  module Core
    # A `/delete` an operator asked for later rather than now. A durable job,
    # not an in-process timer, because the times this exists for are hours or
    # days out and a restart in between must not drop the removal. The removal
    # goes through {Watchdog::Removal#remove_everywhere}, the same path every
    # other bot-mediated delete takes, so a copy already relayed to another
    # platform goes with the original.
    class DeferredDeletion
      KIND = "deferred_delete"

      # Read back from the payload rather than held in memory, since the job
      # outlives the process that booked it.
      ENDPOINT_KEY = "endpoint_id"
      NATIVE_KEY = "native_id"
      ISSUER_KEY = "issued_by"

      # @param topology [Core::Topology] resolves the endpoint the job names
      # @param removal [Watchdog::Removal] does the cross-platform delete
      def initialize(topology:, removal:, logger: nil, audit: nil)
        @topology = topology
        @removal = removal
        @logger = logger
        @audit = audit
      end

      Target = Struct.new(:origin, :ref)

      # Book one. The caller has already checked the time is in the future and
      # that a message was actually named.
      #
      # @param scheduler [Core::DurableScheduler]
      # @param at [Time] when to remove it, in UTC
      # @return [Object, nil] the enqueued job, or nil where it could not be booked
      def self.book(scheduler:, community:, origin:, ref:, at:, issuer: nil)
        return nil if scheduler.nil? || origin.nil? || ref&.native_id.to_s.empty?

        scheduler.schedule(
          kind: KIND, run_at: at, community: community,
          # The payload names a message, never its text, so nothing about what
          # was said waits around in the job store for the delete to come due.
          payload: { ENDPOINT_KEY => origin.id, NATIVE_KEY => ref.native_id.to_s,
                     ISSUER_KEY => issuer.to_s },
          discard_payload: true
        )
      end

      # An endpoint that no longer resolves, or a message already gone, is not
      # an error worth retrying: the job has done all it can and says so by
      # returning rather than raising.
      def run(job)
        payload = job.payload || {}
        endpoint = endpoint_for(payload[ENDPOINT_KEY])
        native_id = payload[NATIVE_KEY].to_s
        return if endpoint.nil? || native_id.empty?

        removed = @removal.remove_everywhere(Target.new(endpoint, MessageRef.new(endpoint.id, native_id)))
        record(job, payload, endpoint, native_id, removed)
      rescue StandardError => e
        @logger&.warn { "deferred delete: could not remove #{payload_ref(job)}: #{e.class}: #{e.message}" }
      end

      private

      def endpoint_for(endpoint_id)
        return nil if endpoint_id.to_s.empty?

        @topology&.rooms&.filter_map { |room| room.endpoint(endpoint_id) }&.first
      end

      # Written down like any other bot-mediated removal, naming the operator
      # who asked for it rather than the scheduler that carried it out.
      def record(job, payload, endpoint, native_id, removed)
        @audit&.record(
          community: job.community, source: KIND, action: "delete",
          adapter: endpoint.adapter_name.to_s, actor: payload[ISSUER_KEY],
          target_ref: "#{endpoint.id}:#{native_id}",
          metadata: { endpoints: Array(removed).length }
        )
      rescue StandardError => e
        @logger&.warn { "deferred delete: could not record the removal: #{e.message}" }
      end

      def payload_ref(job)
        payload = job.payload || {}
        "#{payload[ENDPOINT_KEY]}:#{payload[NATIVE_KEY]}"
      end
    end
  end
end
