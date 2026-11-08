# frozen_string_literal: true

module Rubotty
  module Core
    # The sub conversation a message lives in: a Discord thread, a Telegram
    # forum topic. +name+ is filled in from {ThreadNames} on platforms that
    # omit it per message, and nil when truly unknown; +creator+ is nil except
    # on platforms that report it.
    class ThreadRef
      attr_reader :native_id, :name, :creator, :creator_native_id

      # @param native_id [String, Integer] the platform's thread id
      # @param name [String, nil] the thread's title, when known
      # @param creator [String, nil] the handle of the member who started it
      # @param creator_native_id [String, nil] their stable platform identity,
      #   when the adapter exposes it
      def initialize(native_id:, name: nil, creator: nil, creator_native_id: nil)
        @native_id = native_id.to_s
        @name = presence(name)
        @creator = presence(creator)
        @creator_native_id = presence(creator_native_id)
        freeze
      end

      def named? = !name.nil?

      def created_by? = !creator.nil?

      def to_s = name || native_id

      def ==(other)
        other.is_a?(ThreadRef) && other.native_id == native_id &&
          other.name == name && other.creator == creator &&
          other.creator_native_id == creator_native_id
      end
      alias eql? ==

      def hash = [native_id, name, creator, creator_native_id].hash

      def inspect = "#<ThreadRef #{native_id}#{name ? " #{name.inspect}" : ""}>"

      private

      def presence(value)
        return nil if value.nil?

        string = value.to_s
        string.empty? ? nil : string
      end
    end
  end
end
