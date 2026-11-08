# frozen_string_literal: true

require "spec_helper"

# The marker that covers the window between asking a platform to create a
# native scheduled event and recording the id it answered with. See #1801.
RSpec.describe Rubotty::Events::NativeCreateClaims do
  # Open a claim on another thread and block inside it, so an example can
  # observe what a waiter does while a create is genuinely in flight.
  def hold(claims, adapter, account)
    open = Queue.new
    release = Queue.new
    thread = Thread.new do
      claims.holding(adapter, account) do
        open << :held
        release.pop
      end
    end
    open.pop
    yield
  ensure
    release << :go
    thread&.join(5)
  end

  it "settles at once when nothing is in flight" do
    expect(described_class.new(timeout: 5.0).settle(:discord, "dc")).to be(true)
  end

  it "gives up rather than waiting for ever on a create that never finishes" do
    claims = described_class.new(timeout: 0.05)

    hold(claims, :discord, "dc") do
      expect(claims.settle(:discord, "dc")).to be(false)
    end
  end

  it "reports the create as in flight while the claim is open" do
    claims = described_class.new(timeout: 0.05)

    hold(claims, :discord, "dc") do
      expect(claims.in_flight?(:discord, "dc")).to be(true)
    end
  end

  it "settles once the claim is dropped" do
    claims = described_class.new(timeout: 5.0)
    hold(claims, :discord, "dc") { nil }

    expect(claims.settle(:discord, "dc")).to be(true)
  end

  it "keys by account, so one account's create cannot stall another account's echo" do
    claims = described_class.new(timeout: 0.05)

    hold(claims, :discord, "one") do
      expect(claims.settle(:discord, "two")).to be(true)
    end
  end

  it "releases the claim when the platform call raises, rather than wedging every later echo" do
    claims = described_class.new(timeout: 0.05)

    expect { claims.holding(:discord, "dc") { raise Rubotty::AdapterError.new("nope", adapter: :discord) } }
      .to raise_error(Rubotty::AdapterError)
    expect(claims.settle(:discord, "dc")).to be(true)
  end

  # An outbound create and the echo of it can land on one thread, and a wait
  # there would spend the whole budget before giving up on itself.
  it "never waits on a claim the calling thread is holding itself" do
    claims = described_class.new(timeout: 5.0)

    expect(claims.holding(:discord, "dc") { claims.settle(:discord, "dc") }).to be(true)
  end

  it "hands both halves the same registry by default, so the guard is never quietly unwired" do
    expect(described_class.shared).to equal(described_class.shared)
  end
end
