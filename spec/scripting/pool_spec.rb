# frozen_string_literal: true

require "spec_helper"
require "rubotty/scripting"

# The child pool. Skips without an interpreter, for the same reason the child specs do.
RSpec.describe Rubotty::Scripting::Pool do
  before(:all) do
    skip "no Lua interpreter on PATH" if Rubotty::Scripting::Child.find_binary.nil?
  end

  subject(:pool) { described_class.new(size: 2, logger: Rubotty::Log.null) }

  after { pool.close }

  it "runs a script on a free child" do
    expect(pool.run(source: "return 2 + 3")).to eq(5)
  end

  it "serves more invocations than it has children, one after another" do
    results = 5.times.map { |i| pool.run(source: "return rubotty.__internal * 2", arg: i) }

    expect(results).to eq([0, 2, 4, 6, 8])
  end

  it "runs invocations from several threads at once without crossing their answers" do
    # Sized to the thread count so every run gets a free child immediately: the
    # checkout wait has its own test below, and a busy runner should not make
    # this one about a deadline it is not exercising.
    wide = described_class.new(size: 6, logger: Rubotty::Log.null)
    results = 6.times.map do |i|
      Thread.new { wide.run(source: "return rubotty.__internal * 10", arg: i) }
    end.map(&:value)

    expect(results).to eq([0, 10, 20, 30, 40, 50])
  ensure
    wide&.close
  end

  # A child that overran was killed, so putting it back is what keeps the pool from
  # shrinking permanently every time somebody writes a slow script.
  it "returns a child to the pool after it times out, and keeps working" do
    expect { pool.run(source: "while true do end", timeout: 1) }
      .to raise_error(Rubotty::Scripting::Timeout)

    expect(pool.run(source: "return 1")).to eq(1)
    expect(pool.run(source: "return 2")).to eq(2)
  end

  it "refuses rather than queueing forever when every child is busy" do
    tight = described_class.new(size: 1, logger: Rubotty::Log.null, checkout_timeout: 0.2)
    blocker = Thread.new { tight.run(source: "while true do end", timeout: 2) rescue nil }
    sleep 0.3

    expect { tight.run(source: "return 1") }.to raise_error(Rubotty::Scripting::Unavailable, /busy/)

    blocker.join
    tight.close
  end

  # close used to grab every child straight off @children and kill it, whether or
  # not a request thread had it checked out. A child's pid, stdin and stdout have
  # no lock of their own, so that raced a live Child#run: the other thread's read
  # would see its pipe yanked shut mid-invocation instead of a real answer.
  it "waits for an invocation still running before closing its child, rather than killing it mid-flight" do
    solo = described_class.new(size: 1, logger: Rubotty::Log.null)
    registry = Rubotty::Scripting::HostFunctions.registry(handlers: { "log" => ->(_t) { sleep 0.3; true } })

    runner = Thread.new { solo.run(source: "rubotty.log('x') return 'done'", registry: registry, timeout: 5) }
    sleep 0.05
    solo.close

    expect(runner.value).to eq("done")
  end

  # One pool serves every community, so its size is how much of the host the whole
  # scripting feature may use at once, and a size of one makes any slow script a stall.
  describe ".configured_size" do
    it "defaults to something above one, so a slow script cannot stall everything" do
      expect(described_class.configured_size({})).to be > 1
    end

    it "takes what the environment asks for" do
      expect(described_class.configured_size({ "RUBOTTY_SCRIPT_POOL_SIZE" => "8" })).to eq(8)
    end

    it "clamps an unreasonable ask rather than spawning that many processes" do
      expect(described_class.configured_size({ "RUBOTTY_SCRIPT_POOL_SIZE" => "5000" }))
        .to eq(described_class::MAX_SIZE)
    end

    it "keeps at least one child when asked for none" do
      expect(described_class.configured_size({ "RUBOTTY_SCRIPT_POOL_SIZE" => "0" })).to eq(1)
    end

    it "falls back rather than raising on something that is not a number" do
      expect(described_class.configured_size({ "RUBOTTY_SCRIPT_POOL_SIZE" => "plenty" }))
        .to eq(described_class::DEFAULT_SIZE)
    end
  end
end
