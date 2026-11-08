# frozen_string_literal: true

require "spec_helper"
require "rubotty/scripting"

# The Lua runtime, driven end to end against a real interpreter, which is why these
# need lua on PATH and skip without it. What is worth asserting is what a real child
# does: the sandbox empty of io and os, an infinite loop killed on time, a host call
# coming back.
RSpec.describe Rubotty::Scripting::Child do
  before(:all) do
    skip "no Lua interpreter on PATH" if described_class.find_binary.nil?
  end

  subject(:child) { described_class.new(logger: Rubotty::Log.null) }

  after { child.close }

  describe "running a chunk" do
    it "returns what the script returned" do
      expect(child.run(source: "return 2 + 3")).to eq(5)
    end

    # The payload is bound to rubotty.__internal and read back through the getters built
    # beside it, so this is the whole of how a script sees what it was sent.
    it "hands the payload over as the getters that read it" do
      result = child.run(source: "return string.upper(rubotty.text())", arg: { "text" => "hi" })

      expect(result).to eq("HI")
    end

    it "passes the chunk nothing at all, so the old vararg reads as nil" do
      expect(child.run(source: "return tostring((...))", arg: { "text" => "hi" })).to eq("nil")
    end

    it "carries a table back as ordinary Ruby data" do
      expect(child.run(source: "return {ok = true, list = {1, 2, 3}}"))
        .to eq({ "ok" => true, "list" => [1, 2, 3] })
    end

    # A pipe inherits Encoding.default_external, which is US-ASCII without a UTF-8
    # locale, and a container commonly has none. Left alone this raises on the first
    # accented word, while passing on any developer machine with a UTF-8 locale.
    it "carries non ASCII text both ways whatever the locale" do
      text = "ol\u00E1 \u{1F3E6}"

      expect(child.run(source: 'return rubotty.__internal.s .. "!"', arg: { "s" => text }))
        .to eq("#{text}!")
    end

    it "carries a newline inside a string without breaking the framing" do
      expect(child.run(source: "return #rubotty.__internal.s", arg: { "s" => "a\nb" })).to eq(3)
    end

    it "reports a chunk that will not compile as the operator's problem" do
      expect { child.run(source: "this is not lua") }
        .to raise_error(Rubotty::Scripting::Failed, /would not compile/)
    end

    it "reports a raise inside the script with its message" do
      expect { child.run(source: 'error("nope")') }.to raise_error(Rubotty::Scripting::Failed, /nope/)
    end
  end

  # The sandbox is built from an empty table for every invocation, so these are absent
  # rather than merely blocked. Losing any one is a real escape: io and os reach the
  # filesystem, debug reaches a metatable or an upvalue the script never made, and load
  # can build a chunk from bytecode that crashes the VM.
  describe "the sandbox" do
    %w[io os package require dofile loadfile debug load].each do |name|
      it "has no #{name}" do
        expect(child.run(source: "return type(#{name})")).to eq("nil")
      end
    end

    # Compiled MoonScript needs these two and nothing else.
    it "has the two globals a compiled MoonScript class needs" do
      expect(child.run(source: "return type(setmetatable) .. type(rawget)")).to eq("functionfunction")
    end

    # With getmetatable a script could reach the metatable Lua shares across all
    # strings and rewrite string.upper for every later script in this pooled child,
    # including another community's.
    it "gives a script no route to the shared string metatable" do
      expect(child.run(source: "return type(getmetatable)")).to eq("nil")
    end

    it "cannot poison the string library for the next invocation" do
      attempt = <<~LUA
        local ok = pcall(function()
          local mt = getmetatable("")
          mt.__index.upper = function() return "poisoned" end
        end)
        return ok
      LUA
      expect(child.run(source: attempt)).to be(false)

      expect(child.run(source: 'return string.upper("clean")')).to eq("CLEAN")
    end

    it "still has the parts a script actually needs" do
      expect(child.run(source: "return string.upper('a') .. tostring(math.floor(1.5)) .. #({1,2})"))
        .to eq("A12")
    end

    it "does not leak state from one invocation into the next" do
      child.run(source: "leaked = 'yes'; return true")

      expect(child.run(source: "return type(leaked)")).to eq("nil")
    end
  end

  describe "the time budget" do
    it "kills an infinite loop and says so" do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      expect { child.run(source: "while true do end", timeout: 1) }
        .to raise_error(Rubotty::Scripting::Timeout)
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 3
    end

    # The next invocation has to work, or one bad script takes the slot out of
    # service permanently.
    it "serves the next invocation on a fresh child" do
      expect { child.run(source: "while true do end", timeout: 1) }.to raise_error(Rubotty::Scripting::Timeout)

      expect(child.run(source: "return 7")).to eq(7)
    end

    # A slow host call used to have nothing bounding it at all: the deadline was
    # only ever checked inside read_exact's IO.select, so a handler blocked on
    # the Ruby side (a database row lock, in the real case this covers) ran past
    # the invocation's own timeout with the pool slot wedged the whole time.
    it "kills the child rather than waiting forever on a handler that blocks past the deadline" do
      registry = Rubotty::Scripting::Registry.new.tap { |r| r.register("stuck") { sleep 5 } }
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      expect { child.run(source: "rubotty.stuck()", registry: registry, timeout: 1) }
        .to raise_error(Rubotty::Scripting::Timeout)
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 3

      expect(child.run(source: "return 9")).to eq(9)
    end
  end

  describe "host functions" do
    let(:calls) { [] }
    let(:registry) do
      Rubotty::Scripting::Registry.new(max_calls: 3).tap do |r|
        r.register("webhook") { |name| calls << name; "queued:#{name}" }
        r.register("rooms") { %w[general offtopic] }
        r.register("boom") { raise "handler exploded" }
      end
    end

    it "calls back into Ruby and returns the answer to the script" do
      result = child.run(source: 'return rubotty.webhook("ops-alert")', registry: registry)

      expect(result).to eq("queued:ops-alert")
      expect(calls).to eq(["ops-alert"])
    end

    it "carries a list back into Lua as a table" do
      expect(child.run(source: 'local r = rubotty.rooms(); return r[1] .. "/" .. r[2]', registry: registry))
        .to eq("general/offtopic")
    end

    # A failing handler is the script's to catch, so one webhook that will not send
    # does not read as a broken script.
    it "surfaces a raising handler to the script as a catchable error" do
      expect(child.run(source: "local ok = pcall(boom); return ok", registry: registry)).to be(false)
    end

    it "never installs a stub for a function nobody registered" do
      source = 'local ok, e = pcall(function() return rubotty.exfiltrate() end); return tostring(e)'

      expect(child.run(source: source, registry: registry)).to include("nil value")
    end

    # Host calls live under one table because a script declaring a local with the same
    # name used to shadow the real function silently.
    it "leaves the bare name free for a script to use as its own" do
      source = 'local rooms = { "mine" }; return rooms[1] .. "/" .. rubotty.rooms()[1]'

      expect(child.run(source: source, registry: registry)).to eq("mine/general")
    end

    it "cuts off a script that loops over a host call" do
      expect { child.run(source: 'for _ = 1, 50 do rubotty.webhook("x") end', registry: registry) }
        .to raise_error(Rubotty::Scripting::Failed, /more than 3 host calls/)
    end

    # An operator used to get a dead script and an error naming no function at all, which
    # left them reading their whole rule to find the loop.
    it "names the function that ran the budget out" do
      expect { child.run(source: 'for _ = 1, 50 do rubotty.webhook("x") end', registry: registry) }
        .to raise_error(Rubotty::Scripting::Failed, /webhook/)
    end

    it "tells a script that called a host function when none were offered" do
      expect(child.run(source: "local ok = pcall(webhook); return ok")).to be(false)
    end
  end

  # Two ceilings rather than one: the total is a runaway guard, while the small one is on
  # the calls that actually reach people, and blowing it has to be something a script can
  # carry on from.
  describe "the two budgets" do
    let(:posted) { [] }
    let(:registry) do
      Rubotty::Scripting::Registry.new(max_calls: 50, max_broadcasts: 2).tap do |r|
        r.register("bold", cost: :free) { |text| "*#{text}*" }
        r.register("notify", cost: :broadcast) { |text| posted << text; true }
      end
    end

    # The complaint this came from: a script blew its budget inside the render
    # function, halfway through drawing a board, on formatting.
    it "charges nothing for formatting, however much of it there is" do
      source = 'local out = "" for i = 1, 200 do out = out .. rubotty.bold("x") end return #out'

      expect(child.run(source: source, registry: registry)).to eq(600)
    end

    # Refused rather than fatal, and refused in the shape the documentation
    # teaches, so `if not ok then` is what catches it.
    it "refuses a broadcast past the cap rather than killing the invocation" do
      source = <<~LUA
        local last, why
        for i = 1, 5 do last, why = rubotty.notify("post " .. i) end
        return { ok = last, why = why, ran = "to the end" }
      LUA

      answer = child.run(source: source, registry: registry)

      expect(answer["ran"]).to eq("to the end")
      expect(answer["ok"]).to be(false)
      expect(answer["why"]).to include("notify")
      expect(posted).to eq(["post 1", "post 2"])
    end

    # The handler must not run at all once the cap is gone, or the refusal would
    # be a lie: the room would see the message and the script would be told it
    # had not been sent.
    it "does not reach the handler for a refused broadcast" do
      child.run(source: 'for i = 1, 9 do rubotty.notify("x") end return true', registry: registry)

      expect(posted.length).to eq(2)
    end

    it "leaves an ordinary call working after the broadcasts are gone" do
      registry.register("recall") { "remembered" }
      source = <<~LUA
        rubotty.notify("one") rubotty.notify("two") rubotty.notify("three")
        return rubotty.recall("k")
      LUA

      expect(child.run(source: source, registry: registry)).to eq("remembered")
    end
  end

  describe "without an interpreter" do
    it "is unavailable rather than broken" do
      absent = described_class.new(binary: nil)
      allow(absent).to receive(:available?).and_return(false)

      expect { absent.run(source: "return 1") }.to raise_error(Rubotty::Scripting::Unavailable)
    end
  end

  # A child stopped by its own system call filter is the failure that would
  # otherwise be impossible to read: the pipe closes and nothing is said. The
  # exit status is the only place the reason exists, so it gets read.
  describe "a child that stopped talking" do
    subject(:quiet) { described_class.new(binary: "/usr/bin/lua", logger: Rubotty::Log.null) }

    it "names the filter when SIGSYS is what killed it" do
      status = instance_double(Process::Status, signaled?: true, termsig: Rubotty::Scripting::Seccomp::SIGSYS)
      allow(quiet).to receive(:reap).and_return(status)

      expect(quiet.send(:gone_message)).to match(/system call filter/)
    end

    it "says what a child said on its way down before it ever exec'd" do
      allow(Rubotty::Scripting::Confined).to receive(:failure_note).and_return("Errno::ENOENT: nothing there")

      expect(quiet.send(:gone_message)).to match(/could not run: Errno::ENOENT/)
    end

    it "falls back to the closed pipe when there is nothing more to say" do
      allow(quiet).to receive(:reap).and_return(nil)

      expect(quiet.send(:gone_message)).to match(/closed its pipe/)
    end
  end
end

# A child whose conversation ended mid frame must not go back into the pool. One pool
# serves the whole deployment, so a child still holding the rest of an unread line
# fails the next invocation and the next, and those belong to other communities.
RSpec.describe "a child left mid conversation", :control_plane do
  before(:all) do
    skip "no Lua interpreter on PATH" if Rubotty::Scripting::Child.find_binary.nil?
  end

  subject(:child) { Rubotty::Scripting::Child.new(logger: Rubotty::Log.null) }

  after { child.close }

  it "recovers on the very next invocation after an oversized answer" do
    expect { child.run(source: "return ('x'):rep(8 * 1024 * 1024)", timeout: 10) }
      .to raise_error(Rubotty::Scripting::Desync, /over/)

    expect(child.run(source: 'return "ok"', timeout: 10)).to eq("ok")
  end

  it "recovers after the host call cap is hit, which leaves the child waiting" do
    registry = Rubotty::Scripting::HostFunctions.registry(handlers: { "log" => ->(_t) { true } })
    allow(registry).to receive(:max_calls).and_return(2)

    expect { child.run(source: "for i = 1, 20 do rubotty.log('x') end return 'no'", registry: registry, timeout: 10) }
      .to raise_error(Rubotty::Scripting::Desync)

    expect(child.run(source: 'return "ok"', timeout: 10)).to eq("ok")
  end

  # The death that matters is the one that arrives as EOF on the pipe while an invocation is
  # in flight: the kernel killing the child, or it exiting on its own. That reads as
  # Unavailable, which used to escape run without the child being killed, so its pid stayed
  # set and the pool handed the dead slot straight back to the next community.
  it "respawns after the child dies part way through an invocation" do
    registry = Rubotty::Scripting::HostFunctions.registry(
      handlers: { "log" => ->(_t) { kill_the_child_shortly(child); true } }
    )

    expect do
      child.run(source: "rubotty.log('go') local x = 0 for i = 1, 5e9 do x = x + i end return x",
                registry: registry, timeout: 20)
    end.to raise_error(Rubotty::Scripting::Unavailable)

    expect(child.run(source: 'return "ok"', timeout: 10)).to eq("ok")
  end

  # Killed from outside a moment after the host call is served, so the parent is
  # parked in read_frame rather than writing when the child goes.
  def kill_the_child_shortly(child)
    pid = child.instance_variable_get(:@pid)
    Thread.new do
      sleep 0.3
      Process.kill("KILL", pid)
    rescue Errno::ESRCH
      nil
    end
  end

  # A script that merely raised leaves a perfectly good child, so respawning on every
  # broken rule would be waste.
  it "keeps the child when the script itself raised" do
    before_pid = child.run(source: 'return "warm"', timeout: 10) && child.instance_variable_get(:@pid)

    expect { child.run(source: 'error("boom")', timeout: 10) }
      .to raise_error(Rubotty::Scripting::Failed, /boom/)

    expect(child.instance_variable_get(:@pid)).to eq(before_pid)
    expect(child.run(source: 'return "ok"', timeout: 10)).to eq("ok")
  end
end

# The web process and the bot worker both hold every platform token and DATABASE_URL in
# ENV; the child gets an allow-listed environment instead of a copy of this process's, so
# it never sees them, whether or not sandbox.lua still keeps a running script from
# reaching os itself.
RSpec.describe "the sandbox child's environment" do
  around do |example|
    original = ENV.fetch("RUBOTTY_TEST_TOKEN", nil)
    ENV["RUBOTTY_TEST_TOKEN"] = "do-not-leak-this-token"
    example.run
  ensure
    original.nil? ? ENV.delete("RUBOTTY_TEST_TOKEN") : ENV["RUBOTTY_TEST_TOKEN"] = original
  end

  # A stand-in for the Lua interpreter: a real executable, spawned the same
  # way, that reports what it can see of its own environment rather than
  # running the sandbox. Speaks the real wire protocol by hand instead of
  # pulling in a gem, so the fixture stays dependency free.
  #
  # The shebang names the interpreter's own absolute path rather than
  # `/usr/bin/env ruby`, since that execs twice, and the gated seccomp
  # profile only opens the descriptor for the first exec.
  def fake_interpreter(dir)
    script = File.join(dir, "echo-env")
    File.write(script, <<~RUBY)
      #!#{RbConfig.ruby}
      STDIN.binmode
      STDOUT.binmode
      length = STDIN.read(4).unpack1("N")
      STDIN.read(length) if length.positive?

      value = "TOKEN=\#{ENV["RUBOTTY_TEST_TOKEN"]}|PATH_SET=\#{ENV["PATH"] ? "yes" : ""}"
      fixstr = ->(s) { [0xA0 | s.bytesize, s].pack("Ca*") }
      str8 = ->(s) { [0xD9, s.bytesize, s].pack("CCa*") }
      body = [0x82].pack("C") + fixstr.call("t") + fixstr.call("done") + fixstr.call("v") + str8.call(value)
      STDOUT.write([body.bytesize].pack("N"), body)
    RUBY
    File.chmod(0o755, script)
    # mktmpdir gives 0700, so a run as root drops to the script account and then
    # cannot traverse in. A real interpreter sits somewhere world traversable,
    # so stand the fixture up the same way.
    File.chmod(0o755, dir)
    script
  end

  it "does not hand the sandbox child this process's tokens" do
    Dir.mktmpdir("rubotty-child-env-spec") do |dir|
      child = Rubotty::Scripting::Child.new(binary: fake_interpreter(dir), logger: Rubotty::Log.null)
      begin
        expect(child.run(source: "ignored")).to eq("TOKEN=|PATH_SET=yes")
      ensure
        child.close
      end
    end
  end
end
