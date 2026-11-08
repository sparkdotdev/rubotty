# frozen_string_literal: true

module Rubotty
  module Watchdog
    # The one message-removal engine every watchdog shares: delete the origin, then
    # every relayed copy the message map names in either direction, then forget the
    # map rows. Same path `/delete` takes, parameterised by the +source+ label.
    #
    # {#apply} runs the whole flow including the audit line and notice; a filter that
    # also flags, warns or mutes drives {#remove_everywhere} and {#notice} separately.
    # A lost audit line or notice never derails containment.
    class Removal
      include Features::AdapterLookup

      # @param topology [Core::Topology] resolves a mapped ref back to a live
      #   endpoint during removal
      # @param source [String] the audit `source` key and log prefix for the
      #   watchdog this engine serves ("word_filter", "multipost", ...)
      # @param ephemeral [Core::EphemeralMessage, nil] posts the notice; nil makes
      #   the notice a silent no-op
      # @param audit [AuditLog::Sequel, AuditLog::Null, nil] the audit sink
      # @param alerts [Boolean] whether a removal here also DMs the operators
      def initialize(topology:, adapters:, storage:, logger:, source:,
                     name: nil, ephemeral: nil, cleanup: nil, audit: nil,
                     admin_notifier: nil, alerts: false)
        @topology = topology
        @adapters = adapters
        @storage = storage
        @logger = logger
        @source = source.to_s
        @notice = Core::RemovalNotice.new(
          ephemeral: ephemeral, cleanup: cleanup, audit: audit,
          logger: logger, source: @source, name: name || @source,
          admin_notifier: admin_notifier, alerts: alerts, adapters: adapters
        )
      end

      attr_reader :logger

      # The whole flow for a plain removal verdict: delete everywhere, then audit it
      # and post the notice.
      #
      # @param context [Features::Context]
      # @param reason [String] the explanation shown to the author and stored
      # @param metadata [Hash] watchdog-specific detail for the audit event
      # @return [Array<Core::MessageRef>]
      def apply(context:, reason:, metadata: {})
        removed = remove_everywhere(context.message)
        notice(context: context, action: "delete", reason: reason, metadata: metadata)
        removed
      end

      # Record the action in the audit log and, on a delete, post the notice. Kept
      # apart from {#remove_everywhere} so a filter that flags without removing can
      # drive the two seams alone.
      #
      # @param action [String] the effective action ("delete" or "flag")
      # @param requested [String, nil] the originally requested action when it
      #   differed (a warn / mute degraded to a stub), for the audit trail
      def notice(context:, action:, reason:, requested: nil, metadata: {})
        @notice.apply(
          context: context, action: action, reason: reason,
          requested: requested, metadata: metadata
        )
      end

      # Remove the offending message and every relayed cross-platform copy. A fresh
      # chat has none yet, since a watchdog runs before the bridge; an edit that newly
      # trips one was already relayed, so its copies go too.
      #
      # @return [Array<Core::MessageRef>] the refs actually removed, diagnostic
      def remove_everywhere(message)
        removed = []
        removed << delete_native(message.origin, message.ref.native_id)

        copies = (@storage.counterparts(message.ref) + @storage.origins(message.ref)).uniq
        copies.each { |ref| removed << delete_ref(ref) }

        @storage.forget(message.ref)
        removed.compact
      rescue StorageError => e
        @logger.error { "#{@source}: could not resolve copies of #{message.ref}: #{e.message}" }
        removed.compact
      end

      private

      # Delete one message on the endpoint a mapped ref names.
      def delete_ref(ref)
        endpoint = @topology.endpoint(ref.endpoint_id)
        return nil if endpoint.nil?

        delete_native(endpoint, ref.native_id)
      end

      # Delete one native message, tolerating an adapter that cannot delete, is not
      # registered, or a message already gone.
      def delete_native(endpoint, native_id)
        return nil if native_id.nil?

        adapter = adapter_for(endpoint)
        return nil if adapter.nil? || !adapter.capabilities_for(endpoint).deletes?

        adapter.delete(endpoint, native_id)
        Core::MessageRef.new(endpoint.id, native_id)
      rescue AdapterError => e
        @logger.error { "#{@source}: delete on #{endpoint.id} failed: #{e.message}" }
        nil
      end
    end
  end
end
