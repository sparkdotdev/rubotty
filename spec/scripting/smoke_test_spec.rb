# frozen_string_literal: true

require "spec_helper"
require "rubotty/scripting"

# The save-time gate, run against a real interpreter so what is asserted is that it
# catches scripts that really do break.
RSpec.describe Rubotty::Scripting::SmokeTest do
  before(:all) do
    skip "no Lua interpreter on PATH" if Rubotty::Scripting::Child.find_binary.nil?
  end

  let(:pool) { Rubotty::Scripting::Pool.new(size: 1, logger: Rubotty::Log.null) }
  subject(:smoke) { described_class.new(pool: pool, logger: Rubotty::Log.null, timeout: SMOKE_TEST_SPEC_TIMEOUT) }

  after { pool.close }

  def trigger(type = "always", config = {}) = Rubotty::Scripting::Triggers.build(type, config)

  def check(source, kind: :processor, trigger_type: "always", config: {})
    smoke.run(kind: kind, source: source, trigger: trigger(trigger_type, config))
  end

  describe "scripts that are fine" do
    it "passes a processor that answers properly on every probe" do
      expect(check('return { action = "allow" }')).to be_ok
    end

    it "passes a command that returns a string" do
      result = check('return "you said " .. rubotty.args()',
                     kind: :command, trigger_type: "command", config: { "name" => "echo" })

      expect(result).to be_ok
    end
  end

  describe "scripts that crash" do
    it "catches indexing a field the payload does not carry" do
      result = check('return { action = "rewrite", text = m.nothing.here }')

      expect(result).not_to be_ok
      expect(result.to_s).to include("nil value")
    end

    # Probes vary the structure as well as the text, because an empty list is the
    # shape a script forgets about.
    it "catches indexing into an empty list" do
      result = check('return { action = "rewrite", text = rubotty.matched()[1] }',
                     trigger_type: "contains", config: { "words" => ["spam"] })

      expect(result).not_to be_ok
    end

    it "catches arithmetic on the message text" do
      expect(check("return { action = 1 + rubotty.text() }")).not_to be_ok
    end

    # Using the message text as a Lua pattern works perfectly until somebody types
    # "100%" or "array[0". The subject has to reach the malformed part for Lua to
    # raise, hence matching the text against itself.
    it "catches a script that uses the message text as a pattern" do
      result = check('local cleaned = string.gsub(rubotty.text(), rubotty.text(), "redacted")
                      return { action = "rewrite", text = cleaned }')

      expect(result).not_to be_ok
      expect(result.to_s).to include("malformed pattern")
    end

    it "passes the same script once it matches literally instead" do
      result = check('local cleaned = string.gsub(rubotty.text(), rubotty.text(), "redacted", 1)
                      if string.find(rubotty.text(), rubotty.text(), 1, true) then cleaned = "redacted" end
                      return { action = "rewrite", text = "ok" }')

      expect(result.failures.map(&:message).join).not_to include("has to return")
    end
  end

  # At message time each of these is read as "allow" and forgotten on purpose. At save
  # time the same silence would ship a rule that quietly does nothing.
  describe "scripts that answer nonsense" do
    it "catches a processor returning a string" do
      result = check('return "reject"')

      expect(result).not_to be_ok
      expect(result.to_s).to include("has to return a table").and include("a string")
    end

    it "catches a processor returning nothing at all" do
      expect(check("return nil").to_s).to include("returned nothing")
    end

    it "catches a table with no action" do
      expect(check('return { text = "hi" }').to_s).to include("action was missing")
    end

    it "catches an action nobody recognises" do
      expect(check('return { action = "delete" }').to_s).to include('"delete"')
    end

    it "catches a rewrite with nothing to rewrite to" do
      expect(check('return { action = "rewrite" }').to_s).to include("carry the replacement text")
    end

    it "catches a command returning a table" do
      result = check('return { action = "allow" }', kind: :command,
                     trigger_type: "command", config: { "name" => "x" })

      expect(result.to_s).to include("has to return a string")
    end
  end

  describe "scripts that are too slow" do
    it "fails a script that will not finish, rather than letting it time out in production" do
      result = check("while true do end")

      expect(result).not_to be_ok
      expect(result.to_s).to include("time out under load")
    end
  end

  describe "host functions during a probe" do
    it "stubs them, so nothing real is sent while testing" do
      result = check('rubotty.log("checking"); return { action = "allow" }')

      expect(result).to be_ok
      expect(result.host_calls).to be > 0
    end
  end

  it "runs every probe rather than stopping at the first failure" do
    result = check('return { action = rubotty.text().missing }')

    expect(result.failures.length).to be > 1
  end

  # A script that reads a round has two branches, and both of them run: the
  # first invocation of a game finds nothing open and every later one finds a
  # round. Probing under one scene alone lets half of that ship unchecked.
  describe "a script that asks what the room is taking part in" do
    it "catches one that assumes a round is always open" do
      result = check('local r = rubotty.round(); return { action = "allow", reply = r.prompt }')

      expect(result).not_to be_ok
      expect(result.to_s).to include("nothing running")
    end

    it "catches one that only works while nothing is running" do
      result = check('local r = rubotty.round()
                      if r then return { action = r.missing.field } end
                      return { action = "allow" }')

      expect(result).not_to be_ok
      expect(result.to_s).to include("a round open")
    end

    it "passes one written for both, and probes it twice over" do
      body = 'local r = rubotty.round()
              if not r then return { action = "allow" } end
              return { action = "allow", reply = r.id .. " " .. #rubotty.entries("scores", "", 10) }'

      expect(check(body)).to be_ok
      # Two calls on every probe under the live scene, one under the quiet one.
      expect(check(body).host_calls).to eq(check('rubotty.round(); return { action = "allow" }').host_calls +
                                           Rubotty::Scripting::SmokeTest::PROBE_TEXTS.length)
    end

    it "leaves a script that never mentions one probed exactly as it was" do
      body = 'return { action = "allow" }'

      expect(check(body).failures).to be_empty
      expect(check('rubotty.log("x"); return { action = "allow" }').host_calls)
        .to eq(Rubotty::Scripting::SmokeTest::PROBE_TEXTS.length)
    end

    # The refusals are real answers, so the branch that reads err is checked
    # rather than skipped past.
    it "answers a refusal with a reason a script can print" do
      result = check('local ok, err = rubotty.close_round{ data = { winner = "ada" } }
                      if not ok then return { action = "allow", reply = "no: " .. err } end
                      return { action = "allow" }')

      expect(result).to be_ok
    end
  end
end

# The stub table is what a script is answered with during verification, so a name in
# it that the runtime does not have means the gate is testing something other than
# production.
RSpec.describe "the smoke test's host stubs" do
  it "stubs nothing the catalog does not offer" do
    stubbed = Rubotty::Scripting::SmokeTest::STUBS.keys

    expect(stubbed - Rubotty::Scripting::HostFunctions::CATALOG.keys).to be_empty
  end

  it "answers nothing from a scene that the catalog does not offer either" do
    named = Rubotty::Scripting::SmokeTest::SCENES.values.flat_map(&:keys).uniq

    expect(named - Rubotty::Scripting::HostFunctions::CATALOG.keys).to be_empty
  end

  # A name answered in one scene and forgotten in the other falls through to the
  # catch all, which hands a script `true` where a table belongs.
  it "answers the same set of names in every scene" do
    sets = Rubotty::Scripting::SmokeTest::SCENES.values.map { |scene| scene.keys.sort }

    expect(sets.uniq.length).to eq(1)
  end

  it "probes twice for every participation name the catalog carries" do
    named = Rubotty::Scripting::SmokeTest::SCENES.values.flat_map(&:keys).uniq

    expect(named.sort).to eq(Rubotty::Scripting::SmokeTest::PARTICIPATION.sort)
  end
end

# Run now. The save-time check answers "does this fall over", while this answers
# "given this input, what does it do".
RSpec.describe Rubotty::Scripting::SmokeTest, "#try" do
  before(:all) do
    skip "no Lua interpreter on PATH" if Rubotty::Scripting::Child.find_binary.nil?
  end

  let(:pool) { Rubotty::Scripting::Pool.new(size: 1, logger: Rubotty::Log.null) }
  subject(:smoke) { described_class.new(pool: pool, logger: Rubotty::Log.null, timeout: SMOKE_TEST_SPEC_TIMEOUT) }

  after { pool.close }

  def trigger(type = "always", config = {}) = Rubotty::Scripting::Triggers.build(type, config)

  it "runs a processor against the text that was typed" do
    matched, answer = smoke.try(kind: :processor, trigger: trigger,
                                source: 'return { action = "allow", reply = rubotty.text() }',
                                text: "hello there")

    expect(matched).to be(true)
    expect(answer["reply"]).to eq("hello there")
  end

  it "says so when the condition would not have matched" do
    matched, answer = smoke.try(kind: :processor, text: "nothing here",
                                trigger: trigger("contains", { "words" => ["airdrop"] }),
                                source: 'return { action = "allow" }')

    expect(matched).to be(false)
    expect(answer).to be_nil
  end

  it "hands a command its own arguments" do
    matched, answer = smoke.try(kind: :command, trigger: trigger("command", { "name" => "roll" }),
                                source: 'return "rolled " .. rubotty.args()', text: "/roll 2d6")

    expect(matched).to be(true)
    expect(answer).to eq("rolled 2d6")
  end

  # Recurring and callback scripts are never woken by traffic, so observe answers nil
  # for both and Run now used to report that nothing matched.
  describe "the kinds nothing in a room can wake" do
    it "runs a recurring script rather than reporting no match" do
      matched, answer = smoke.try(kind: :processor, text: "",
                                  trigger: trigger("recurring", { "every" => "day" }),
                                  source: 'return { action = "allow", reply = "the digest" }')

      expect(matched).to be(true)
      expect(answer["reply"]).to eq("the digest")
    end

    it "tells a recurring script that this is a wake" do
      _matched, answer = smoke.try(kind: :processor, text: "",
                                   trigger: trigger("recurring", { "every" => "day" }),
                                   source: 'return { action = "allow", reply = rubotty.kind() }')

      expect(answer["reply"]).to eq("scheduled_function")
    end

    it "runs a callback, whatever its condition says" do
      matched, answer = smoke.try(kind: :callback, trigger: trigger, text: "",
                                  source: 'return { action = "allow", reply = rubotty.kind() }')

      expect(matched).to be(true)
      expect(answer["reply"]).to eq("http_callback")
    end

    it "hands over the data it was given, since that is what a wake carries" do
      _matched, answer = smoke.try(kind: :callback, trigger: trigger, text: "town: Lisbon",
                                   data: { "town" => "Lisbon" },
                                   source: 'return { action = "allow", reply = rubotty.invocation_data().town }')

      expect(answer["reply"]).to eq("Lisbon")
    end

    it "runs with no data at all, which is what an empty box means" do
      matched, answer = smoke.try(kind: :callback, trigger: trigger, text: "",
                                  source: 'return { action = "allow", reply = tostring(rubotty.invocation_data()) }')

      expect(matched).to be(true)
      expect(answer["reply"]).to eq("nil")
    end
  end
end

# A windowed rule counts across messages, and the harness could only ever show one,
# so the rule it was built for was the one thing it could not demonstrate.
RSpec.describe Rubotty::Scripting::SmokeTest, "#try against a windowed condition" do
  before(:all) do
    skip "no Lua interpreter on PATH" if Rubotty::Scripting::Child.find_binary.nil?
  end

  let(:pool) { Rubotty::Scripting::Pool.new(size: 1, logger: Rubotty::Log.null) }
  subject(:smoke) { described_class.new(pool: pool, logger: Rubotty::Log.null, timeout: SMOKE_TEST_SPEC_TIMEOUT) }

  after { pool.close }

  def windowed
    Rubotty::Scripting::Triggers.build("recent_contains",
                                       { "words" => ["http"], "window" => 10, "count" => 3 })
  end

  def try(text)
    smoke.try(kind: :processor, trigger: windowed, text: text,
              source: 'return { action = "allow", reply = tostring(rubotty.hits()) }')
  end

  it "does not fire on one message, which is the rule working" do
    matched, = try("http://one.example")

    expect(matched).to be(false)
  end

  it "fires once enough messages have been given, one per line" do
    matched, answer = try("http://one.example\nhttp://two.example\nhttp://three.example")

    expect(matched).to be(true)
    expect(answer["reply"]).to eq("3")
  end

  it "counts only the messages that match, not every line" do
    matched, = try("hello\nhttp://one.example\nnothing\nhttp://two.example")

    expect(matched).to be(false)
  end

  it "still takes a single message on one line" do
    matched, = smoke.try(kind: :processor, text: "airdrop now",
                         trigger: Rubotty::Scripting::Triggers.build("contains", { "words" => ["airdrop"] }),
                         source: 'return { action = "allow" }')

    expect(matched).to be(true)
  end
end

# A script may carry several conditions, and each one hands it a different set of keys.
# Gating on the first alone would pass a script that breaks on the shape its second
# condition really produces, which is the sort of gate that reports "no obvious errors"
# about code nobody ran.
RSpec.describe "the gate, on a script with several conditions" do
  before(:all) do
    skip "no Lua interpreter on PATH" if Rubotty::Scripting::Child.find_binary.nil?
  end

  let(:pool) { Rubotty::Scripting::Pool.new(size: 1, logger: Rubotty::Log.null) }
  subject(:smoke) { Rubotty::Scripting::SmokeTest.new(pool: pool, logger: Rubotty::Log.null, timeout: SMOKE_TEST_SPEC_TIMEOUT) }

  after { pool.close }

  def both
    Rubotty::Scripting::Triggers.build_all("command", { "name" => "deal", "triggers" => ["always"] })
  end

  it "passes a script that copes with either shape" do
    source = 'return { action = "allow", reply = rubotty.command() or "no command" }'

    expect(smoke.run(kind: :processor, source: source, trigger: both)).to be_ok
  end

  # The second condition hands over no rubotty.command() at all, so a script that
  # assumes the first one's payload falls over on exactly the messages nobody
  # thought to try.
  it "catches a script that only copes with the first condition's payload" do
    source = 'return { action = "allow", reply = string.upper(rubotty.command()) }'
    result = smoke.run(kind: :processor, source: source, trigger: both)

    expect(result).not_to be_ok
    expect(result.to_s).to include("always")
  end

  it "reports which condition a probe came from, so the failure has a lead" do
    source = 'return { action = "allow", reply = string.upper(rubotty.command()) }'

    expect(smoke.run(kind: :processor, source: source, trigger: both).failures.map(&:probe))
      .to all(start_with("always "))
  end

  # The refusal a broadcast gets past its cap has to look the same at the gate
  # as it does in production, or a script is checked against a world where
  # notify never refuses.
  it "charges the calls that reach people the way production charges them" do
    source = <<~LUA
      local last
      for i = 1, 8 do last = rubotty.notify("post " .. i) end
      return { action = "allow", reply = tostring(last) }
    LUA
    matched, answer = smoke.try(kind: :processor, source: source, text: "anything",
                                trigger: Rubotty::Scripting::Triggers.build("always"))

    expect(matched).to be(true)
    expect(answer["reply"]).to eq("false")
  end
end
