# frozen_string_literal: true

require "digest"
require "json"
require "securerandom"

module Rubotty
  module Core
    # Short-lived ownership of a source fan-out, separate from its completed
    # relay claim. A crash leaves identifiers, never message bodies, and the
    # lease expires so native redelivery or backfill can repair missing copies.
    class RelayLeases
      DEFAULT_LEASE = 300
      LOCK = "rubotty:relay:leases"
      Lease = Struct.new(:key, :owner)

      def initialize(storage:, logger: nil, lease: DEFAULT_LEASE, clock: -> { Time.now })
        @storage = storage
        @logger = logger
        @lease = lease
        @clock = clock
      end

      def claim(source, community)
        @storage.with_advisory_lock(LOCK, timeout: 2) do
          next nil if @storage.relay_claimed?(source: source, operation: "new", community: community)

          key = key_for(source, community)
          pending = read(key)
          next nil if pending && pending["until"].to_f > @clock.call.to_f

          lease = Lease.new(key, SecureRandom.uuid)
          write(lease)
          lease
        end
      rescue LockUnavailable
        nil
      rescue StorageError => e
        @logger&.warn { "could not claim source delivery lease, proceeding without storage: #{e.message}" }
        Lease.new(nil, nil)
      end

      def start_refresh(lease)
        return nil if lease.key.nil?

        stop = Queue.new
        thread = Thread.new do
          Thread.current.name = "relay-lease-refresh"
          while stop.pop(timeout: @lease / 3.0).nil?
            break unless refresh(lease)
          end
        end
        [stop, thread]
      end

      def stop_refresh(refresher)
        return if refresher.nil?

        stop, thread = refresher
        stop << :done
        thread.join(1)
        thread.kill if thread.alive?
      end

      def finish(lease, source:, community:, completed:, claim_ttl:)
        @storage.with_advisory_lock(LOCK, timeout: 2) do
          next if lease.key && read(lease.key)&.fetch("owner", nil) != lease.owner

          if completed
            @storage.claim_relay(source: source, operation: "new", community: community,
                                 expires_at: claim_ttl ? @clock.call + claim_ttl : nil)
          end
          @storage.put_state(lease.key, "{}", expires_at: @clock.call) if lease.key
        end
      rescue StorageError => e
        @logger&.warn { "could not settle source delivery lease: #{e.message}" }
      end

      private

      def refresh(lease)
        @storage.with_advisory_lock(LOCK, timeout: 2) do
          next false unless read(lease.key)&.fetch("owner", nil) == lease.owner

          write(lease)
          true
        end
      rescue StorageError => e
        @logger&.warn { "could not refresh source delivery lease: #{e.message}" }
        true
      end

      def write(lease)
        expires = @clock.call + @lease
        @storage.put_state(lease.key, JSON.generate("owner" => lease.owner, "until" => expires.to_f),
                           expires_at: expires)
      end

      def read(key)
        raw = @storage.get_state(key)
        value = raw && JSON.parse(raw)
        value.is_a?(Hash) ? value : nil
      rescue JSON::ParserError
        nil
      end

      def key_for(source, community)
        "relay-inflight:#{Digest::SHA256.hexdigest(JSON.generate([community.to_s, *source.to_a]))}"
      end
    end
  end
end
