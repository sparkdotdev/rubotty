# frozen_string_literal: true

module Rubotty
  module Core
    # The one acknowledgement template every deferred command shares:
    #
    #   "Acknowledged, <summary> in <t> seconds."
    #
    # <summary> is a short phrase the caller supplies, <t> is the grace
    # period. The self-delete TTL is a per-community or per-channel
    # `feature_settings` value under {TTL_FIELD}, resolved by {ttl_seconds}.
    module CommandAck
      # The standardised default, used when a scope has not set its own value.
      DEFAULT_TTL_SECONDS = 30

      # The single config field name every command feature exposes for its
      # acknowledgement TTL, so it is editable from the dashboard under one key.
      TTL_FIELD = :ack_ttl_seconds

      # The field controlling whether the invoking command message is deleted
      # together with the reply. On by default; a community that wants to
      # keep invocations sets it false.
      DELETE_COMMAND_FIELD = :delete_command_message

      # Whether the invoking command message is removed together with its reply.
      DELETE_COMMAND_DEFAULT = true

      module_function

      # Resolves the acknowledgement TTL from a per-scope feature config hash,
      # tolerating string or symbol keys. A configured 0 means "do not
      # self-delete"; anything missing or unparseable falls back to +default+.
      #
      # @param config [Hash] the resolved per-scope feature config
      # @param default [Integer] the fallback when the field is unset
      # @return [Integer] seconds
      def ttl_seconds(config, default: DEFAULT_TTL_SECONDS)
        config = {} unless config.is_a?(Hash)
        raw = config[TTL_FIELD]
        raw = config[TTL_FIELD.to_s] if raw.nil?
        value = Integer(raw, exception: false)
        value.nil? || value.negative? ? default.to_i : value
      end

      # Whether this scope wants the invoking command message removed alongside
      # the reply it produced. Tolerates a string key and the "false"/"0"
      # spellings; anything unset falls back to {DELETE_COMMAND_DEFAULT}.
      #
      # @param config [Hash] the resolved per-scope feature config
      # @return [Boolean]
      def delete_command?(config)
        config = {} unless config.is_a?(Hash)
        raw = config[DELETE_COMMAND_FIELD]
        raw = config[DELETE_COMMAND_FIELD.to_s] if raw.nil?
        return DELETE_COMMAND_DEFAULT if raw.nil?

        !%w[false 0 no off].include?(raw.to_s.strip.downcase)
      end

      # The refs to hand the ephemeral primitive as +also_delete:+ for one
      # invocation: the command message itself when this scope wants the pair to
      # vanish together, nothing when it does not.
      #
      # A synthetic message (a native Discord slash-command interaction
      # reconstructed for the pipeline) is never paired: its ref names no real
      # posted message, so the ephemeral reap would retry a delete forever.
      # @return [Array<Core::MessageRef>]
      def pair_with(message, config)
        return [] unless delete_command?(config)
        return [] if message.respond_to?(:synthetic?) && message.synthetic?

        ref = message.respond_to?(:ref) ? message.ref : nil
        ref.nil? || ref.native_id.nil? || ref.native_id.empty? ? [] : [ref]
      end

      # The ref to hand the ephemeral primitive as +reply_to:+, so an answer hangs
      # off the message that asked for it rather than floating in the channel.
      #
      # A synthetic message (a native Discord slash-command interaction
      # reconstructed for the pipeline) names no real posted message, so there is
      # nothing on the platform to reply to and this answers nil.
      #
      # @return [Core::MessageRef, nil]
      def reply_to(message)
        return nil if message.respond_to?(:synthetic?) && message.synthetic?

        ref = message.respond_to?(:ref) ? message.ref : nil
        ref.nil? || ref.native_id.nil? || ref.native_id.empty? ? nil : ref
      end

      # The acknowledgement posted the instant a deferred command is accepted.
      #
      #   pending("deleting this message on all services", 15)
      #   # => "Acknowledged, deleting this message on all services in 15 seconds."
      #
      # @param summary [String] a short phrase describing the pending action
      # @param seconds [Integer] the grace period before the action runs
      # @return [String]
      def pending(summary, seconds)
        "Acknowledged, #{summary.to_s.strip} in #{seconds.to_i} #{unit(seconds)}."
      end

      # "second" for a delay of one, "seconds" otherwise.
      def unit(seconds) = seconds.to_i == 1 ? "second" : "seconds"
    end
  end
end
