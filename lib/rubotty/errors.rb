# frozen_string_literal: true

module Rubotty
  # Base class for every error this library raises deliberately.
  class Error < StandardError; end

  # Raised when the YAML configuration cannot be parsed, or fails validation.
  # Carries every problem found rather than only the first.
  class ConfigError < Error
    # @return [Array<String>] one human readable line per problem
    attr_reader :problems

    def initialize(problems)
      @problems = Array(problems)
      super(build_message)
    end

    private

    def build_message
      return @problems.first.to_s if @problems.size == 1

      lines = @problems.each_with_index.map { |problem, index| "  #{index + 1}. #{problem}" }
      (["#{@problems.size} configuration problems:"] + lines).join("\n")
    end
  end

  # Raised when an adapter is referenced in configuration but is not registered.
  class UnknownAdapterError < ConfigError; end

  # Raised by adapters when the remote platform rejects a call. Adapters should
  # wrap transport level failures in this.
  class AdapterError < Error
    attr_reader :adapter, :retryable, :retry_after

    def initialize(message, adapter: nil, retryable: false, retry_after: nil)
      @adapter = adapter
      @retryable = retryable
      @retry_after = retry_after
      super(message)
    end

    def retryable? = @retryable
  end

  # Raised when a platform reports that the bot lacks permission for an action.
  # Never retryable.
  class PermissionError < AdapterError
    def initialize(message, adapter: nil)
      super(message, adapter: adapter, retryable: false)
    end
  end

  # Raised when the platform says the message an action names is not there.
  # Distinct from a refusal, since the two want opposite handling: a permission
  # error means try again with more rights, this one means the message is gone
  # and whatever was going to happen to it no longer can. Never retryable.
  class MessageGoneError < AdapterError
    def initialize(message, adapter: nil)
      super(message, adapter: adapter, retryable: false)
    end
  end

  # Raised when a platform asks us to slow down. Always retryable, and carries
  # the wait hint when the platform supplies one.
  class RateLimitedError < AdapterError
    def initialize(message, adapter: nil, retry_after: nil)
      super(message, adapter: adapter, retryable: true, retry_after: retry_after)
    end
  end

  # Raised by the storage layer for backend failures.
  class StorageError < Error; end

  # Raised by Storage::Base#with_advisory_lock when the named lock could not be
  # acquired within its timeout, i.e. another caller already holds it.
  class LockUnavailable < StorageError; end

  # Raised when an adapter subclass has not implemented a required part of the
  # contract. Surfaces at boot rather than on the first message.
  class NotImplementedByAdapterError < Error; end
end
