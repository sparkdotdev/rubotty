# frozen_string_literal: true

require "spec_helper"

# The broadcast cap has to cover every call that puts something in front of people, not
# just notify: post, whisper and react fell through to the shipped classification's :read
# default, so a script could make fifty of them in one run while the docs published a limit
# of five.
RSpec.describe "the shipped broadcast classification reaches every call that reaches people (#392)" do
  let(:served) { Hash.new { |h, k| h[k] = [] } }

  # Every function the cap should cover, wired to a handler that records rather
  # than sends, and built through the real HostFunctions.registry so the cost
  # comes from BY_COST.
  def registry_for(*names)
    handlers = names.to_h { |name| [name, ->(*args) { served[name] << args; true }] }
    Rubotty::Scripting::HostFunctions.registry(handlers: handlers, max_broadcasts: 2, max_calls: 50)
  end

  let(:child) { Rubotty::Scripting::Child.new }

  after { child.close }

  %w[post whisper react].each do |name|
    it "refuses #{name} past the cap the same way it refuses notify" do
      registry = registry_for(name)
      source = <<~LUA
        local last, why
        for i = 1, 5 do last, why = rubotty.#{name}("call " .. i) end
        return { ok = last, why = why, ran = "to the end" }
      LUA

      answer = child.run(source: source, registry: registry)

      expect(answer["ran"]).to eq("to the end")
      expect(answer["ok"]).to be(false)
      expect(answer["why"]).to include(name)
      expect(served[name].length).to eq(2)
    end
  end

  # The cap is on the whole set, not per function, so a script cannot get five
  # of each by spreading the calls around.
  it "counts every reaching call against one shared allowance" do
    registry = registry_for("notify", "post", "whisper")
    source = <<~LUA
      rubotty.notify("one")
      rubotty.post("two")
      local ok, why = rubotty.whisper("three")
      return { ok = ok, why = why }
    LUA

    answer = child.run(source: source, registry: registry)

    expect(answer["ok"]).to be(false)
    expect(served["notify"].length).to eq(1)
    expect(served["post"].length).to eq(1)
    expect(served["whisper"]).to be_empty
  end

  # edit and delete change something already in front of people, which the
  # catalog comment above `post` has always distinguished, so they stay
  # ordinary and a rule may keep a scoreboard current.
  it "lets a rule edit past the cap, which is what the classification intends" do
    registry = registry_for("edit")
    source = <<~LUA
      local last
      for i = 1, 5 do last = rubotty.edit("handle", "score " .. i) end
      return { ok = last }
    LUA

    answer = child.run(source: source, registry: registry)

    expect(answer["ok"]).to be(true)
    expect(served["edit"].length).to eq(5)
  end
end
