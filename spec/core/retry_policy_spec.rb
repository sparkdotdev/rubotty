# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Core::RetryPolicy do
  let(:slept) { [] }

  subject(:policy) do
    described_class.new(attempts: 3, base_delay: 0.1, logger: Rubotty::Log.null,
                        sleeper: ->(seconds) { slept << seconds })
  end

  def retryable(message = "boom", retry_after: nil)
    Rubotty::AdapterError.new(message, adapter: :fake, retryable: true, retry_after: retry_after)
  end

  it "returns the value when the block succeeds first time" do
    expect(policy.call { :ok }).to eq(:ok)
    expect(slept).to be_empty
  end

  it "retries a retryable failure and returns the eventual success" do
    attempts = 0
    result = policy.call do
      attempts += 1
      raise retryable if attempts < 3

      :ok
    end
    expect(result).to eq(:ok)
    expect(attempts).to eq(3)
    expect(slept.size).to eq(2)
  end

  it "gives up after the configured number of attempts" do
    attempts = 0
    expect do
      policy.call do
        attempts += 1
        raise retryable
      end
    end.to raise_error(Rubotty::AdapterError)
    expect(attempts).to eq(3)
  end

  # Retrying a permission error just blocks the room for longer.
  it "does not retry an error marked as not retryable" do
    attempts = 0
    expect do
      policy.call do
        attempts += 1
        raise Rubotty::PermissionError.new("kicked", adapter: :fake)
      end
    end.to raise_error(Rubotty::PermissionError)
    expect(attempts).to eq(1)
    expect(slept).to be_empty
  end

  # The platform knows when its limit lifts, and guessing is how a bridge earns
  # a longer ban.
  it "honours a platform supplied retry_after rather than guessing" do
    attempts = 0
    policy.call do
      attempts += 1
      raise Rubotty::RateLimitedError.new("slow down", adapter: :fake, retry_after: 7) if attempts == 1

      :ok
    end
    expect(slept.first).to be_within(0.5).of(7)
  end

  it "refuses to block a room worker for an absurdly long rate limit" do
    expect do
      policy.call { raise Rubotty::RateLimitedError.new("banned", adapter: :fake, retry_after: 3600) }
    end.to raise_error(Rubotty::RateLimitedError)
    expect(slept).to be_empty
  end

  describe "backoff" do
    it "grows exponentially" do
      first = policy.exponential(1)
      third = policy.exponential(3)
      expect(third).to be > first
    end

    it "is capped" do
      capped = described_class.new(base_delay: 1, max_delay: 5)
      expect(capped.exponential(20)).to be <= 5
    end

    # Without jitter, every room hitting the same outage retries in lockstep
    # and arrives together, which knocks a recovering service back over.
    it "is jittered, so simultaneous failures do not retry in lockstep" do
      samples = Array.new(20) { policy.exponential(3) }
      expect(samples.uniq.size).to be > 1
    end
  end
end
