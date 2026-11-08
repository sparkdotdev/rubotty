# frozen_string_literal: true

require "spec_helper"
require "rubotty/scripting"

# A script must not be able to leave a __gc finalizer behind. A finalizer is owned by the
# Lua state rather than by the per-invocation env, and one pooled child serves every
# community, so a finalizer left pending ran inside whatever later invocation triggered a
# collection, its host calls served against another community's room, memory and members.
RSpec.describe "a script's __gc finalizers (#399)" do
  before(:all) do
    skip "no Lua interpreter on PATH" if Rubotty::Scripting::Child.find_binary.nil?
  end

  # One child, so the second invocation really is the same Lua state as the
  # first. That sharing is the whole bug.
  let(:child) { Rubotty::Scripting::Child.new }

  after { child.close }

  # A registry per community, each recording what it was asked to post, so a
  # call served by the wrong one is visible rather than inferred.
  def registry_for(sink)
    Rubotty::Scripting::Registry.new.tap do |r|
      r.register("post", cost: :read) { |text| sink << text; true }
    end
  end

  let(:alpha) { [] }
  let(:beta) { [] }

  # Community A leaves 300 finalizers pending and returns, keeping its own
  # allocation low so nothing collects during its own run.
  PLANTS_FINALIZERS = <<~LUA
    local keep = {}
    for i = 1, 300 do
      keep[i] = setmetatable({ i }, { __gc = function() rubotty.post("posted-by-A") end })
    end
    return "planted"
  LUA

  # Ordinary work that allocates enough to drive a full collection cycle. The
  # table churn is what does it: an arithmetic loop alone leaves the incremental
  # collector short of finishing a cycle, and then the finalizers simply wait
  # for a busier invocation rather than not running at all.
  VICTIM = <<~LUA
    local n = 0
    for i = 1, 500000 do n = n + #tostring(i) end
    local t = {}
    for i = 1, 50000 do t[i] = { i } end
    rubotty.post("posted-by-B")
    return n
  LUA

  it "refuses a metatable carrying __gc rather than accepting it quietly" do
    expect do
      child.run(source: PLANTS_FINALIZERS, registry: registry_for(alpha))
    end.to raise_error(Rubotty::Scripting::Error, /__gc/)
  end

  it "leaves nothing of A's behind for B's invocation to run" do
    begin
      child.run(source: PLANTS_FINALIZERS, registry: registry_for(alpha))
    rescue Rubotty::Scripting::Error
      # Refused, which is the point.
    end

    child.run(source: VICTIM, registry: registry_for(beta))

    expect(beta).to eq(["posted-by-B"])
    expect(alpha).to be_empty
  end

  # The guard is on __gc alone. MoonScript compiles to setmetatable plus
  # rawget, which is why setmetatable is in the sandbox at all, so it has to
  # keep working for everything else.
  it "still allows an ordinary metatable, which compiled MoonScript needs" do
    source = <<~LUA
      local t = setmetatable({}, { __index = function() return "from the metatable" end })
      return t.anything
    LUA

    expect(child.run(source: source, registry: registry_for(alpha))).to eq("from the metatable")
  end

  it "still allows __call and __tostring, which a class emits" do
    source = <<~LUA
      local t = setmetatable({}, { __call = function() return "called" end })
      return t()
    LUA

    expect(child.run(source: source, registry: registry_for(alpha))).to eq("called")
  end

  # Setting __gc after the metatable is attached does not mark the object for
  # finalization in this Lua, so the guard at the door is the whole of it.
  # Asserted rather than assumed, since the fix rests on it.
  it "does not finalize an object whose __gc was added after the fact" do
    source = <<~LUA
      local mt = {}
      local t = setmetatable({}, mt)
      mt.__gc = function() rubotty.post("posted-late") end
      t = nil
      return "done"
    LUA

    child.run(source: source, registry: registry_for(alpha))
    child.run(source: VICTIM, registry: registry_for(beta))

    expect(alpha).to be_empty
    expect(beta).to eq(["posted-by-B"])
  end
end
