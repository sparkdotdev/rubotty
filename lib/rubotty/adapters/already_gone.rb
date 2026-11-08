# frozen_string_literal: true

module Rubotty
  module Adapters
    # Whether a platform failure means the thing the call targeted is no longer
    # there: the one answer an adapter may swallow, since a delete racing an
    # edit or a reaction on an already-removed message is ordinary. Centralized
    # so a wider per-adapter copy can't swallow a real failure and leave
    # storage believing in state the platform no longer has.
    module AlreadyGone
      # Each platform's own wording for the same answer. Stoat says NotFound,
      # Matrix says M_NOT_FOUND, Fluxer names the resource, Telegram writes a
      # sentence, and several of them just say 404.
      PATTERNS = Regexp.union(
        /\b404\b/,
        "NotFound",
        "M_NOT_FOUND",
        "Unknown Message",
        "Unknown Webhook",
        "MESSAGE_ID_INVALID",
        "message to edit not found",
        "message to delete not found",
        "message can't be deleted"
      ).freeze

      # @param error [Exception] what the platform call raised
      def self.call(error)
        # "Come back later" is never "it is not there", however it is worded.
        return false if error.is_a?(RateLimitedError)

        PATTERNS.match?(message_of(error))
      end

      def self.message_of(error) = error.respond_to?(:message) ? error.message.to_s : error.to_s
      private_class_method :message_of
    end
  end
end
