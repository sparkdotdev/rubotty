# frozen_string_literal: true

module Rubotty
  module Features
    # Cross-channel duplicate (multipost) protection. Asks the multipost watchdog
    # whether the same author has posted the same content across enough distinct
    # channels to count as a raid. The first post stays; the later copies go.
    class Multipost < Base
      # The audit `source` key and the sender label the removal notice is posted under.
      SOURCE = "multipost"
      NOTICE_NAME = "cross-post filter"

      DEFAULT_REMOVAL_REASON = Watchdog::Multipost::REASON

      def self.feature_name = "multipost"

      def self.description = "Catches the same message posted by the same person across multiple channels."

      def self.default_enabled? = false

      # Chat only: an edit is not a fresh post into a channel, so re-counting it
      # as a new sighting would be wrong.
      def self.observes = %i[chat]

      def self.config_schema
        Config::Schema.define do
          field :channel_threshold, :integer, default: Watchdog::Multipost::DEFAULT_CHANNEL_THRESHOLD,
                desc: "distinct channels (the first included) at which cross-posted copies start being removed"
          field :window_seconds, :duration, default: Watchdog::Multipost::DEFAULT_WINDOW_SECONDS,
                desc: "how long a prior post in another channel still counts, in seconds"
          field :min_length, :integer, default: Watchdog::Multipost::DEFAULT_MIN_LENGTH,
                desc: "shortest normalised message length considered, so trivial short repeats are ignored"
          field :exempt_operators, :boolean, default: true
          field :removal_reason, :string, default: DEFAULT_REMOVAL_REASON,
                desc: "the reason shown to the author when a cross-post is removed"
          field Core::RemovalNotice::TTL_FIELD, :integer, default: Core::RemovalNotice::DEFAULT_TTL_SECONDS,
                desc: "seconds the self-deleting removal notice lives before it is removed"
        end
      end

      # @param topology [Core::Topology] resolves a mapped ref during removal
      # @param adapters [Hash{[Symbol,String]=>Adapters::Base}] the shared map
      # @param storage the fingerprint store and message map
      # @param ephemeral [Core::EphemeralMessage, nil] posts the removal notice
      # @param cleanup [Core::Scheduler, nil] fires the notice's self-delete
      # @param audit [Core::AuditLog::Sequel, Core::AuditLog::Null, nil] the durable moderation audit sink
      # @param clock [#call] returns the current Time; injected in tests
      def initialize(topology:, adapters:, storage:, logger:,
                     ephemeral: nil, cleanup: nil,
                     audit: nil, clock: -> { Time.now })
        super()
        @logger = logger
        @watchdog = Watchdog::Multipost.new(storage: storage, clock: clock)
        removal = Watchdog::Removal.new(
          topology: topology, adapters: adapters, storage: storage, logger: logger,
          source: SOURCE, name: NOTICE_NAME, ephemeral: ephemeral, cleanup: cleanup, audit: audit
        )
        @runner = Watchdog::Runner.new(watchdogs: [@watchdog], removal: removal, logger: logger)
      end

      attr_reader :logger

      def call(context)
        # Checked here rather than in the watchdog, so an exempt author's post is
        # never recorded and never counts toward anyone else's total.
        return Outcome.continue([]) if exempt?(context)

        @runner.run(context)
      end

      private

      # Operators are exempt by default because an announcement legitimately spans
      # several channels; `exempt_operators: false` subjects them like anyone else.
      # The deployment-configured owner floor is asked first and ignores that setting: it is
      # meant to survive the database, the CLI and the dashboard, and a per
      # community toggle built to subject ordinary operators to the guard is one
      # more surface it has to survive.
      def exempt?(context)
        return true if deployment_owner?(context)
        return false unless truthy(config_value(context.config, :exempt_operators), default: true)

        # This community's own directory and nothing else. A room key is unique
        # only within one, so an unresolved community denies rather than widening
        # to the merged deployment-wide view. Empty is still not short-circuited:
        # the deployment-configured owner floor is invisible to Directory#empty?.
        directory = context.operators
        return false if directory.nil?

        author = context.message.author
        return false if author.nil? || author.native_id.nil?

        !directory.resolve(context.message.origin.adapter_name, author.native_id,
                           username: author.username).nil?
      end

      # Matched the same way Core::Moderation::Directory#resolve matches the
      # floor: by username on Telegram and Discord, by MXID on Matrix, never by
      # native id alone. Asked directly rather than through exempt_operators or
      # either directory, so a community turning that setting off for itself, or
      # never having granted an operator row, cannot catch the deployment's own
      # owner in a guard built to catch a raid.
      def deployment_owner?(context)
        author = context.message.author
        return false if author.nil?

        Security::ProtectedOperators.default.owner?(
          adapter: context.message.origin.adapter_name, username: author.username, native_id: author.native_id
        )
      end

      # Read one key from the resolved config, tolerating symbol or string keys.
      def config_value(config, key)
        return nil unless config.is_a?(Hash)

        config.key?(key) ? config[key] : config[key.to_s]
      end

      def truthy(value, default:)
        return default if value.nil?
        return value if value == true || value == false

        %w[true yes on 1].include?(value.to_s.strip.downcase)
      end
    end
  end
end
