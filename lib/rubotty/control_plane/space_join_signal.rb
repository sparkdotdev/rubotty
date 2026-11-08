# frozen_string_literal: true

module Rubotty
  module ControlPlane
    # The platform neutral "bot was added to a space" signal that the Telegram
    # my_chat_member handler and the Discord server_create handler both build
    # before asking {JoinGuard#on_join} to decide. Every field beyond the
    # coarse space address is best effort: a platform that cannot answer "who
    # added the bot" supplies nil, and one with no enumerable channel list
    # (Telegram) supplies an empty sample.
    class SpaceJoinSignal
      # How many channel names to carry. A guild can have hundreds; a sample is
      # enough for a human reviewing an approval request to recognise the space.
      SAMPLE_LIMIT = 5

      attr_reader :adapter, :account, :external_id, :title, :inviter, :channel_sample, :occurred_at

      # @param inviter [Core::Author, nil] who added the bot, when the platform
      #   exposes that: Telegram's my_chat_member "from", Discord's BOT_ADD
      #   audit-log entry. nil when the platform cannot say, or lacks the
      #   permission to ask (Discord's "View Audit Log").
      # @param channel_sample [Array<String>] up to {SAMPLE_LIMIT} channel names
      #   from the space, so a reviewer recognises it. Always empty on Telegram,
      #   which has no enumerable channel list at join time.
      # @param occurred_at [Time]
      def initialize(adapter:, account:, external_id:, title: nil, inviter: nil,
                     channel_sample: [], occurred_at: Time.now)
        @adapter = adapter.to_sym
        @account = account.to_s
        @external_id = external_id.to_s
        @title = presence(title)
        @inviter = inviter
        @channel_sample = Array(channel_sample).filter_map { |name| presence(name) }.first(SAMPLE_LIMIT)
        @occurred_at = occurred_at
        freeze
      end

      def to_h
        {
          adapter: adapter, account: account, external_id: external_id, title: title,
          inviter: inviter&.to_h, channel_sample: channel_sample, occurred_at: occurred_at
        }
      end

      private

      def presence(value)
        return nil if value.nil?

        string = value.to_s.strip
        string.empty? ? nil : string
      end
    end
  end
end
