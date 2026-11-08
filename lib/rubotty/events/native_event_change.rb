# frozen_string_literal: true

module Rubotty
  module Events
    # One native-scheduled-event change as reported by an adapter's own gateway
    # or webhook: Discord's GUILD_SCHEDULED_EVENT_CREATE / _UPDATE / _DELETE,
    # normalized so a consumer never has to know discordrb's event shape.
    class NativeEventChange
      ACTIONS = %i[created updated deleted].freeze

      attr_reader :adapter, :account, :action, :native_id, :guild_id, :title,
                  :starts_at, :ends_at, :status, :raw

      # @param adapter [Symbol] which adapter reported the change, e.g. :discord
      # @param native_id [String, nil] the platform's own id for the event
      # @param guild_id [String, nil] the platform space the event lives in
      # @param status [Symbol, String, nil] the platform's own status value
      # @param raw [Hash, nil] the untranslated platform payload, for a
      #   consumer that needs more than the normalized fields carry
      def initialize(adapter:, account:, action:, native_id: nil, guild_id: nil, title: nil,
                     starts_at: nil, ends_at: nil, status: nil, raw: nil)
        @adapter = adapter.to_sym
        @account = account.to_s
        @action = action.to_sym
        @native_id = native_id&.to_s
        @guild_id = guild_id&.to_s
        @title = title
        @starts_at = starts_at
        @ends_at = ends_at
        @status = status
        @raw = raw
        freeze
      end

      def created? = action == :created

      def updated? = action == :updated

      def deleted? = action == :deleted

      def to_s = "#<NativeEventChange #{adapter}:#{account} #{action} #{native_id}>"
      alias inspect to_s
    end
  end
end
