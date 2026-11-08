# frozen_string_literal: true

module Rubotty
  module ControlPlane
    # Holds the current immutable Snapshot and swaps it atomically: a Ruby
    # object-reference read and write are atomic on MRI, so {#current} takes
    # no lock. A control-plane change calls {#reload} to build a new Snapshot
    # and repoint the reference; in-flight messages keep the Snapshot they
    # started with.
    class Registry
      # @param models [ControlPlane::Models]
      # @param accounts [Hash] fallback account name => credential, used only
      #   while the database accounts table has never been seeded at all
      #   (see SnapshotBuilder#build)
      # @param env [Hash] environment to resolve a database row's token_env against
      # @param builder [#build] injectable for tests; defaults to SnapshotBuilder
      def self.build(models:, accounts: {}, env: ENV, builder: SnapshotBuilder)
        new(models: models, accounts: accounts, env: env, builder: builder)
      end

      def initialize(models:, accounts: {}, env: ENV, builder: SnapshotBuilder)
        @models = models
        @accounts = accounts
        @env = env
        @builder = builder
        @reload_lock = Mutex.new
        @current = build_snapshot
      end

      # The live Snapshot. One volatile reference read, no lock.
      def current = @current

      # Rebuild from the control plane and swap the reference atomically,
      # serialised so two concurrent reloads don't both build. Returns the new Snapshot.
      def reload
        @reload_lock.synchronize { @current = build_snapshot }
      end

      # A control-plane change applies by rebuilding, so apply is reload today.
      alias apply reload

      private

      def build_snapshot
        @builder.build(@models, accounts: @accounts, env: @env)
      end
    end
  end
end
