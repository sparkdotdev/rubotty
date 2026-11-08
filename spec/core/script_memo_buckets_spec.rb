# frozen_string_literal: true

require "spec_helper"
require "rubotty/scripting"

# The store functions as a script actually calls them, through the router's
# own handlers and real Lua. The Ruby side is covered in memory_spec; what
# this pins is the boundary: whether a table written in Lua arrives as the
# arguments the store expects, and a refusal comes back as values it can read.
RSpec.describe "the store functions a script calls", :control_plane do
  before(:all) do
    skip "no Lua interpreter on PATH" if Rubotty::Scripting::Child.find_binary.nil?
  end

  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:community) { models.community.first }
  let(:now) { Time.utc(2026, 7, 29, 12, 0) }
  let(:pool) { Rubotty::Scripting::Pool.new(size: 1, logger: Rubotty::Log.null) }
  let(:memory) { Rubotty::Scripting::Memory.new(models: models, logger: Rubotty::Log.null, clock: -> { now }) }

  after { pool.close }

  def script(name)
    models.community_script.create(
      community_id: community.id, name: name, kind: "processor", language: "lua",
      source: "return nil", compiled: "return nil", trigger_type: "always",
      enabled: false, consecutive_failures: 0, created_at: now, updated_at: now
    )
  end

  # The real handlers, built the way Core::Router builds them, so the argument
  # parsing under test is the one that ships.
  def registry_for(row)
    router = Rubotty::Core::Router.allocate
    Rubotty::Scripting::HostFunctions.registry(handlers: {
      "remember" => router.send(:script_remember_handler, memory, row, "general"),
      "recall" => router.send(:script_recall_handler, memory, row, "general"),
      "forget" => router.send(:script_forget_handler, memory, row, "general"),
      "add" => router.send(:script_add_handler, memory, row),
      "move" => router.send(:script_move_handler, memory, row),
      "top" => router.send(:script_top_handler, memory, row),
      "keys" => router.send(:script_keys_handler, memory, row),
      "count_keys" => router.send(:script_count_keys_handler, memory, row)
    })
  end

  def run(row, source)
    pool.run(source: source, arg: {}, registry: registry_for(row), timeout: 5)
  end

  describe "the private default" do
    it "round trips a value" do
      row = script("guard")
      run(row, 'rubotty.remember{ key = "k", value = "v" }')

      expect(run(row, 'return tostring(rubotty.recall{ key = "k" })')).to eq("v")
    end

    it "stays out of another script's reach" do
      mine = script("mine")
      theirs = script("theirs")
      run(mine, 'rubotty.remember{ key = "secret", value = "mine" }')

      expect(run(theirs, 'return tostring(rubotty.recall{ key = "secret" })')).to eq("nil")
    end
  end

  describe "a named bucket" do
    it "is shared by two scripts" do
      writer = script("writer")
      reader = script("reader")
      run(writer, 'rubotty.remember{ bucket = "scores", key = "ada", value = 5, ttl = 600 }')

      expect(run(reader, 'return tostring(rubotty.recall{ bucket = "scores", key = "ada" })')).to eq("5")
    end

    it "can be forgotten by the other script" do
      writer = script("writer")
      reader = script("reader")
      run(writer, 'rubotty.remember{ bucket = "scores", key = "ada", value = 5, ttl = 600 }')
      run(reader, 'rubotty.forget{ bucket = "scores", key = "ada" }')

      expect(run(writer, 'return tostring(rubotty.recall{ bucket = "scores", key = "ada" })')).to eq("nil")
    end

    it "answers false and a reason for a name it will not take" do
      row = script("guard")
      answer = run(row, <<~LUA)
        local ok, why = rubotty.remember{ bucket = "has:colon", key = "k", value = "v" }
        return tostring(ok) .. " " .. tostring(why)
      LUA

      expect(answer).to start_with("false ")
      expect(answer).to include("bucket name")
    end

    # The guarantee stated end to end: there is no argument a script can pass
    # that reaches another script's private memory.
    it "cannot reach a private scope by naming it" do
      mine = script("mine")
      theirs = script("theirs")
      run(mine, 'rubotty.remember{ key = "secret", value = "mine" }')

      probe = %(return tostring(rubotty.recall{ bucket = "s:#{mine.id}", key = "secret" }))
      expect(run(theirs, probe)).to eq("nil")
    end
  end

  # Half of what scripts stored was a structure hand packed into a string, and
  # the pipe is where that would break if anywhere did.
  describe "a table as the value" do
    it "comes back a table rather than a string a script has to unpack" do
      row = script("guard")
      run(row, 'rubotty.remember{ key = "card", value = { 5, 12, 33 } }')

      answer = run(row, <<~LUA)
        local card = rubotty.recall{ key = "card" }
        return type(card) .. " " .. #card .. " " .. card[2]
      LUA
      expect(answer).to eq("table 3 12")
    end

    it "keeps the keys of a table that is not a list" do
      row = script("guard")
      run(row, 'rubotty.remember{ key = "ballot", value = { first = "ada", rounds = 3 } }')

      expect(run(row, 'local b = rubotty.recall{ key = "ballot" } return b.first .. " " .. b.rounds'))
        .to eq("ada 3")
    end
  end

  describe "kept totals" do
    it "keeps a number that no clock takes away, reachable from any room" do
      writer = script("writer")
      reader = script("reader")
      run(writer, 'rubotty.remember{ bucket = "wallet", key = "ada", value = 100, ttl = "never" }')

      expect(run(reader, 'return rubotty.recall{ bucket = "wallet", key = "ada" }')).to eq(100)
    end

    it "answers false and a reason when a kept value is not a number" do
      row = script("guard")
      answer = run(row, <<~LUA)
        local ok, why = rubotty.remember{ bucket = "wallet", key = "ada",
                                          value = "a sentence", ttl = "never" }
        return tostring(ok) .. " " .. tostring(why)
      LUA

      expect(answer).to start_with("false ")
      expect(answer).to include("whole number")
    end

    it "answers the new total from add, so a script can post it straight back" do
      row = script("guard")
      run(row, 'rubotty.add{ bucket = "wallet", key = "ada", by = 5 }')

      expect(run(row, 'return rubotty.add{ bucket = "wallet", key = "ada", by = 2 }')).to eq(7)
    end

    it "answers false and a reason when a bound refuses the change" do
      row = script("guard")
      run(row, 'rubotty.add{ bucket = "wallet", key = "ada", by = 1 }')

      answer = run(row, <<~LUA)
        local total, why = rubotty.add{ bucket = "wallet", key = "ada", by = -5, floor = 0 }
        return tostring(total) .. " " .. tostring(why)
      LUA
      expect(answer).to start_with("false ")
    end

    it "moves between two totals in one call" do
      row = script("guard")
      run(row, 'rubotty.add{ bucket = "wallet", key = "ada", by = 10 }')
      run(row, 'rubotty.move{ bucket = "wallet", from = "ada", to = "grace", amount = 4 }')

      expect(run(row, 'return rubotty.recall{ bucket = "wallet", key = "grace" }')).to eq(4)
      expect(run(row, 'return rubotty.recall{ bucket = "wallet", key = "ada" }')).to eq(6)
    end

    # A leaderboard is the shape this exists for, so the list has to arrive as a
    # Lua sequence of tables rather than as something a script has to reshape.
    it "answers top as a list of key and value, highest first" do
      row = script("guard")
      run(row, 'rubotty.add{ bucket = "scores", key = "ada", by = 3 }')
      run(row, 'rubotty.add{ bucket = "scores", key = "grace", by = 9 }')

      answer = run(row, <<~LUA)
        local board = rubotty.top("scores", 2)
        return #board .. " " .. board[1].key .. " " .. board[1].value
      LUA
      expect(answer).to eq("2 grace 9")
    end

    it "lists names under a prefix, and counts what the community keeps" do
      row = script("guard")
      run(row, 'rubotty.add{ bucket = "scores", key = "team:red", by = 1 }')
      run(row, 'rubotty.add{ bucket = "scores", key = "ada", by = 1 }')

      expect(run(row, 'return rubotty.keys("scores", "team:")[1]')).to eq("team:red")
      expect(run(row, 'return rubotty.count_keys("scores")')).to eq(2)
      expect(run(row, "return rubotty.count_keys()")).to eq(2)
    end
  end
end
