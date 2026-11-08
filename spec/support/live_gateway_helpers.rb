# frozen_string_literal: true

# Polling helpers for spec/live's opt-in real-gateway specs (issue #133). A
# live connection delivers on its own thread, on the platform's own schedule,
# so every assertion there is "did this arrive within a generous window"
# rather than "did this happen synchronously".
module LiveGateway
  DEFAULT_TIMEOUT = 20
  POLL_INTERVAL = 0.25

  # Poll until +block+ returns a truthy value or +timeout+ elapses. Returns
  # whatever the block returned, or nil on timeout.
  def self.wait_until(timeout: DEFAULT_TIMEOUT)
    deadline = Time.now + timeout
    loop do
      result = yield
      return result if result
      return nil if Time.now >= deadline

      sleep(POLL_INTERVAL)
    end
  end

  # Poll +dispatcher.messages+ (newest first, since the interesting one is
  # usually the last one to arrive) until one matches +block+, or +timeout+
  # elapses.
  def self.wait_for_message(dispatcher, timeout: DEFAULT_TIMEOUT, &block)
    wait_until(timeout: timeout) { dispatcher.messages.reverse.find(&block) }
  end
end
