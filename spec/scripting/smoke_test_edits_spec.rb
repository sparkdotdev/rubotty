# frozen_string_literal: true

require "spec_helper"
require "rubotty/scripting"

# The save-time gate has to probe the message_edit branch. probe_kind only ever answered
# COMMAND or MESSAGE, so a script that opted into edits and branched on rubotty.kind() was
# checked on the branch it never takes: it passed with "no obvious errors" and then raised
# on the first real edit.
RSpec.describe Rubotty::Scripting::SmokeTest, "probing the edit branch" do
  before(:all) do
    skip "no Lua interpreter on PATH" if Rubotty::Scripting::Child.find_binary.nil?
  end

  let(:pool) { Rubotty::Scripting::Pool.new(size: 1, logger: Rubotty::Log.null) }
  subject(:smoke) { described_class.new(pool: pool, logger: Rubotty::Log.null, timeout: 2) }

  after { pool.close }

  def trigger(config) = Rubotty::Scripting::Triggers.build("always", config)

  def check(source, config)
    smoke.run(kind: :processor, source: source, trigger: trigger(config))
  end

  # Broken only on the edit branch: nil arithmetic that the message branch
  # never reaches.
  BREAKS_ON_EDIT = <<~LUA
    if rubotty.kind() == "message_edit" then
      return { action = "allow", text = 1 + nil }
    end
    return { action = "allow" }
  LUA

  it "catches a script that only breaks on an edit when edits are enabled" do
    result = check(BREAKS_ON_EDIT, { "edits" => true })

    expect(result).not_to be_ok
    expect(result.failures.map(&:probe)).to include(a_string_including("on an edit"))
  end

  it "leaves that same script alone when it never hears edits" do
    result = check(BREAKS_ON_EDIT, {})

    expect(result).to be_ok
  end

  it "still passes a script that handles both branches" do
    source = <<~LUA
      if rubotty.kind() == "message_edit" then return { action = "allow" } end
      return { action = "allow" }
    LUA

    expect(check(source, { "edits" => true })).to be_ok
  end

  # rubotty.kind() has to answer message_edit on those probes, or the gate is
  # running the message branch twice under a different label.
  it "tells the script it is an edit rather than an ordinary message" do
    source = <<~LUA
      if rubotty.kind() ~= "message_edit" then return { action = "allow" } end
      return { action = "allow", text = 1 + nil }
    LUA

    expect(check(source, { "edits" => true })).not_to be_ok
  end

  # A command script that hears edits reaches the edit branch too, because
  # Features::Scripts#payload_kind answers EDIT before it asks about commands.
  it "probes the edit branch of a command script that hears edits" do
    source = <<~LUA
      if rubotty.kind() == "message_edit" then return 1 + nil end
      return "fine"
    LUA
    result = smoke.run(
      kind: :command, source: source,
      trigger: Rubotty::Scripting::Triggers.build("command", { "name" => "echo", "edits" => true })
    )

    expect(result).not_to be_ok
  end
end
