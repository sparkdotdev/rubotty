# frozen_string_literal: true

require "spec_helper"
require "rubotty/scripting"

# The store: two places to put something and one vocabulary over both, so most of what
# matters here is which store a call reached and what each one refuses.
RSpec.describe Rubotty::Scripting::Memory, :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:community) { models.community.first }
  let(:now) { Time.utc(2026, 7, 28, 12, 0) }
  let(:room) { "general" }

  subject(:memory) { described_class.new(models: models, logger: Rubotty::Log.null, clock: -> { now }) }

  def build_script(name)
    models.community_script.create(
      community_id: community.id, name: name, kind: "processor", language: "lua",
      source: "return nil", compiled: "return nil", trigger_type: "always",
      enabled: false, consecutive_failures: 0, created_at: now, updated_at: now
    )
  end

  let(:script) { build_script("guard") }
  let(:other) { build_script("other") }

  describe "remembering and recalling" do
    it "round trips a value" do
      expect(memory.remember(script, room, key: "seen:ada", value: { "count" => 2 })).to be(true)
      expect(memory.recall(script, room, key: "seen:ada")).to eq({ "count" => 2 })
    end

    it "returns nil for a key nobody set" do
      expect(memory.recall(script, room, key: "nothing")).to be_nil
    end

    it "overwrites rather than adding a second row" do
      memory.remember(script, room, key: "k", value: 1)
      memory.remember(script, room, key: "k", value: 2)

      expect(memory.recall(script, room, key: "k")).to eq(2)
      expect(memory.count(script, room)).to eq(1)
    end

    it "forgets on request" do
      memory.remember(script, room, key: "k", value: 1)

      expect(memory.forget(script, room, key: "k")).to be(true)
      expect(memory.recall(script, room, key: "k")).to be_nil
    end
  end

  # The half about shape rather than retention: scripts were packing a bingo card into
  # "5|12|33" and a ranked ballot into "a|b|c" because there was nowhere to put a table and
  # no serialiser in the sandbox.
  describe "a value that is a table" do
    it "round trips a list without the script packing it into a string" do
      card = [5, 12, 33, 47, 61]

      expect(memory.remember(script, room, key: "card", value: card)).to be(true)
      expect(memory.recall(script, room, key: "card")).to eq(card)
    end

    it "round trips a nested table, which is what a real structure looks like" do
      ballot = { "first" => "ada", "rest" => %w[grace alan], "rounds" => { "1" => 3 } }

      memory.remember(script, room, key: "ballot", value: ballot)

      expect(memory.recall(script, room, key: "ballot")).to eq(ballot)
    end

    it "refuses a table over the size cap, since this is still not file storage" do
      ok, why = memory.remember(script, room, key: "big", value: Array.new(2000) { "x" * 10 })

      expect(ok).to be(false)
      expect(why).to match(/under #{described_class::MAX_VALUE_BYTES} bytes/)
    end
  end

  describe "expiry" do
    it "reads as absent once it has expired, and clears itself on the way past" do
      memory.remember(script, room, key: "k", value: 1, ttl: 60)
      later = described_class.new(models: models, logger: Rubotty::Log.null,
                                  clock: -> { now + 120 })

      expect(later.recall(script, room, key: "k")).to be_nil
      expect(later.count(script, room)).to eq(0)
    end

    # Compared against a known reference rather than an absolute instant,
    # because Sequel's timezone is not pinned in this project and reads a
    # DateTime back in local time. The interval is what this is asserting.
    def expiry_after(ttl)
      memory.forget(script, room, key: "probe")
      memory.remember(script, room, key: "probe", value: 1, ttl: ttl)
      models.script_memo.where(key: "probe").first.expires_at.to_time
    end

    it "defaults to a day when a script does not say" do
      expect(expiry_after(nil) - expiry_after(60)).to be_within(2).of(described_class::DEFAULT_TTL - 60)
    end

    # Asking to remember something for a year is optimistic rather than wrong,
    # so it is clamped and keeps working with a shorter memory.
    it "clamps a ttl beyond the ceiling instead of refusing it" do
      decade = 10 * 365 * 24 * 60 * 60

      expect(expiry_after(decade) - expiry_after(60)).to be_within(2).of(described_class::MAX_TTL - 60)
    end

    it "sweeps everything already expired" do
      memory.remember(script, room, key: "a", value: 1, ttl: 60)
      memory.remember(script, room, key: "b", value: 1, ttl: 60)

      expect(described_class.new(models: models, clock: -> { now + 120 }).sweep).to eq(2)
    end
  end

  describe "the working store's caps" do
    before { stub_const("#{described_class}::MAX_KEYS", 3) }

    # A rule that silently lost memory it believes it has is worse than one that
    # can see the write failed, so this answers rather than evicting.
    it "refuses a write past the key cap and says so, keeping what is there" do
      described_class::MAX_KEYS.times do |i|
        expect(memory.remember(script, room, key: "k#{i}", value: i)).to be(true)
      end

      ok, why = memory.remember(script, room, key: "one-too-many", value: 1)
      expect(ok).to be(false)
      expect(why).to match(/already holding/)
      expect(memory.count(script, room)).to eq(described_class::MAX_KEYS)
      expect(memory.recall(script, room, key: "k0")).to eq(0)
    end

    it "still lets an existing key be overwritten at the cap" do
      described_class::MAX_KEYS.times { |i| memory.remember(script, room, key: "k#{i}", value: i) }

      expect(memory.remember(script, room, key: "k0", value: "changed")).to be(true)
      expect(memory.recall(script, room, key: "k0")).to eq("changed")
    end

    it "refuses an empty key" do
      ok, why = memory.remember(script, room, key: "  ", value: 1)

      expect(ok).to be(false)
      expect(why).to match(/needs a key/)
    end
  end

  describe "scoping" do
    # The examples teach keying on a person, so under the old per-community cap one busy
    # room spent the entire allowance and every write in every other room answered false
    # from then on. A rule like "warn this person once a day" stopped working exactly when a
    # community got busy enough to need it.
    it "gives each room its own allowance, so a busy one cannot starve the rest" do
      stub_const("#{described_class}::MAX_KEYS", 3)
      3.times { |i| expect(memory.remember(script, "busy", key: "warned:#{i}", value: i)).to be(true) }

      expect(memory.remember(script, "busy", key: "one-too-many", value: 1).first).to be(false)
      expect(memory.remember(script, "quiet", key: "warned:0", value: 0)).to be(true)
    end

    it "keeps the same key in two rooms apart" do
      memory.remember(script, "kitchen", key: "warned:ada", value: "kitchen note")
      memory.remember(script, "garden", key: "warned:ada", value: "garden note")

      expect(memory.recall(script, "kitchen", key: "warned:ada")).to eq("kitchen note")
      expect(memory.recall(script, "garden", key: "warned:ada")).to eq("garden note")
    end

    it "does not forget another room's memo of the same name" do
      memory.remember(script, "kitchen", key: "k", value: 1)
      memory.remember(script, "garden", key: "k", value: 2)

      memory.forget(script, "kitchen", key: "k")

      expect(memory.recall(script, "garden", key: "k")).to eq(2)
    end

    it "keeps one script's memory out of another's" do
      memory.remember(script, room, key: "k", value: "mine")

      expect(memory.recall(other, room, key: "k")).to be_nil
    end
  end

  # An optional bucket, so one rule can write a tally and another read it. The
  # default stays private, and privacy is the property worth pinning hardest:
  # the stored scope is "s:<id>" or "b:<name>", and a bucket may not contain a
  # colon, so a script cannot type a name that reaches another script's memory.
  describe "working buckets" do
    def bucket(name) = described_class.bucket_scope(name)

    it "lets two scripts share a named bucket" do
      memory.remember(script, room, bucket: "scores", key: "tally", value: 1)

      expect(memory.recall(other, room, bucket: "scores", key: "tally")).to eq(1)
    end

    it "lets the other script write it too, which is the point" do
      memory.remember(script, room, bucket: "scores", key: "tally", value: 1)
      memory.remember(other, room, bucket: "scores", key: "tally", value: 2)

      expect(memory.recall(script, room, bucket: "scores", key: "tally")).to eq(2)
    end

    it "keeps a bucket apart from the private memory of the same name" do
      memory.remember(script, room, key: "tally", value: "mine")
      memory.remember(script, room, bucket: "scores", key: "tally", value: "ours")

      expect(memory.recall(script, room, key: "tally")).to eq("mine")
      expect(memory.recall(script, room, bucket: "scores", key: "tally")).to eq("ours")
    end

    it "keeps two buckets apart" do
      memory.remember(script, room, bucket: "one", key: "k", value: "a")
      memory.remember(script, room, bucket: "two", key: "k", value: "b")

      expect(memory.recall(script, room, bucket: "one", key: "k")).to eq("a")
    end

    # The guarantee, stated as a test: a private scope is not a name a bucket
    # can have, so there is no bucket argument that reaches one.
    it "refuses a bucket name that would resolve to a private scope" do
      expect(bucket("s:#{script.id}")).to be_nil
      expect(bucket("b:anything")).to be_nil
      expect(bucket("has:colon")).to be_nil
    end

    it "refuses a bucket name that is empty or absurdly long" do
      expect(bucket("")).to be_nil
      expect(bucket("x" * 200)).to be_nil
    end

    it "answers false for a bucket name it will not take, rather than writing somewhere else" do
      ok, why = memory.remember(script, room, bucket: "has:colon", key: "k", value: 1)

      expect(ok).to be(false)
      expect(why).to match(/not a bucket name/)
    end

    it "treats a bucket name as one thing whatever case it was typed in" do
      memory.remember(script, room, bucket: "Scores", key: "k", value: "v")

      expect(memory.recall(other, room, bucket: "scores", key: "k")).to eq("v")
    end

    it "gives a bucket its own allowance rather than spending the script's" do
      stub_const("#{described_class}::MAX_KEYS", 2)
      2.times { |i| memory.remember(script, room, key: "k#{i}", value: i) }

      expect(memory.remember(script, room, key: "one-too-many", value: 1).first).to be(false)
      expect(memory.remember(script, room, bucket: "scores", key: "fresh", value: 1)).to be(true)
    end

    it "forgets only within the scope it was asked about" do
      memory.remember(script, room, key: "k", value: "private")
      memory.remember(script, room, bucket: "scores", key: "k", value: "shared")

      memory.forget(script, room, bucket: "scores", key: "k")

      expect(memory.recall(script, room, key: "k")).to eq("private")
      expect(memory.recall(script, room, bucket: "scores", key: "k")).to be_nil
    end
  end

  # The other half about retention: a balance has to outlive thirty days, and every write to
  # the working store pushed its expiry out, so a total lasted exactly as long as somebody
  # kept playing.
  describe "kept totals" do
    def keep(key, value, bucket: "wallet")
      memory.remember(script, room, bucket: bucket, key: key, value: value, ttl: "never")
    end

    it "keeps a whole number and reads it back through the same recall" do
      expect(keep("ada", 100)).to be(true)
      expect(memory.recall(script, room, bucket: "wallet", key: "ada")).to eq(100)
    end

    it "never expires, however far the clock moves" do
      keep("ada", 100)
      decades = described_class.new(models: models, clock: -> { now + (100 * 365 * 24 * 60 * 60) })

      expect(decades.recall(script, room, bucket: "wallet", key: "ada")).to eq(100)
      expect(decades.sweep).to eq(0)
    end

    # Community scoped rather than room scoped, because a wallet that differs
    # per room is not a wallet. This is the one place the two stores disagree.
    it "reads the same in every room, unlike a working bucket" do
      keep("ada", 100)

      expect(memory.recall(script, "elsewhere", bucket: "wallet", key: "ada")).to eq(100)
    end

    it "is shared by every script in the community" do
      keep("ada", 100)

      expect(memory.recall(other, "elsewhere", bucket: "wallet", key: "ada")).to eq(100)
    end

    # The restriction is the privacy design: something with no expiry is what
    # would otherwise fill up with message content.
    it "refuses anything that is not a whole number, and says why" do
      ok, why = keep("ada", "a whole sentence somebody typed")

      expect(ok).to be(false)
      expect(why).to match(/whole number/)
    end

    it "refuses a fraction as well as a sentence" do
      expect(keep("ada", 1.5).first).to be(false)
    end

    it "refuses a table, which the working store takes happily" do
      expect(keep("ada", { "a" => 1 }).first).to be(false)
    end

    # It bounds values and not keys, which are script authored, and saying so
    # out loud is part of the design rather than an omission.
    it "takes any key a script writes, including one naming a person" do
      expect(keep("ada@example.com", 1)).to be(true)
    end

    it "needs a bucket, since a total nobody else may read is not a total" do
      ok, why = memory.remember(script, room, key: "ada", value: 1, ttl: "never")

      expect(ok).to be(false)
      expect(why).to match(/needs a bucket/)
    end

    it "refuses a number beyond what the column holds" do
      expect(keep("ada", described_class::MAX_KEPT_VALUE + 1).first).to be(false)
    end

    it "forgets through the same call the working store uses" do
      keep("ada", 100)

      expect(memory.forget(script, room, bucket: "wallet", key: "ada")).to be(true)
      expect(memory.recall(script, room, bucket: "wallet", key: "ada")).to be_nil
    end

    it "refuses a write past the community cap rather than dropping something older" do
      stub_const("#{described_class}::MAX_KEPT_KEYS", 2)
      2.times { |i| expect(keep("k#{i}", i)).to be(true) }

      ok, why = keep("one-too-many", 1)
      expect(ok).to be(false)
      expect(why).to match(/already keeping/)
      expect(memory.count_keys(script)).to eq(2)
    end

    it "counts one bucket, or everything the community keeps" do
      keep("ada", 1)
      keep("grace", 2)
      keep("first", 3, bucket: "seats")

      expect(memory.count_keys(script, "wallet")).to eq(2)
      expect(memory.count_keys(script)).to eq(3)
    end
  end

  # One bucket and key names one value, so recall never has to pick a store.
  describe "keeping one name in one store" do
    it "refuses to remember with a ttl what is already kept" do
      memory.remember(script, room, bucket: "wallet", key: "ada", value: 1, ttl: "never")

      ok, why = memory.remember(script, room, bucket: "wallet", key: "ada", value: "note", ttl: 60)
      expect(ok).to be(false)
      expect(why).to match(/is kept/)
    end

    it "refuses to keep what is already remembered with a ttl, in any room" do
      memory.remember(script, "elsewhere", bucket: "wallet", key: "ada", value: "note", ttl: 60)

      ok, why = memory.remember(script, room, bucket: "wallet", key: "ada", value: 1, ttl: "never")
      expect(ok).to be(false)
      expect(why).to match(/remembered with a ttl/)
    end

    # A private key carries the script's own scope, which no kept row can have,
    # so there is nothing for it to collide with.
    it "leaves a private key alone, since no kept row can carry that scope" do
      memory.remember(script, room, bucket: "wallet", key: "ada", value: 1, ttl: "never")

      expect(memory.remember(script, room, key: "ada", value: "note")).to be(true)
      expect(memory.recall(script, room, key: "ada")).to eq("note")
    end

    it "lets a name move stores once it has been forgotten" do
      memory.remember(script, room, bucket: "wallet", key: "ada", value: 1, ttl: "never")
      memory.forget(script, room, bucket: "wallet", key: "ada")

      expect(memory.remember(script, room, bucket: "wallet", key: "ada", value: "note", ttl: 60)).to be(true)
    end
  end

  describe "adding to a kept total" do
    it "opens a key at zero the first time it is touched" do
      expect(memory.add(script, bucket: "wallet", key: "ada", by: 5)).to eq(5)
    end

    it "counts up by one when nothing says otherwise" do
      memory.add(script, bucket: "wallet", key: "ada")

      expect(memory.add(script, bucket: "wallet", key: "ada")).to eq(2)
    end

    it "takes away on a negative step" do
      memory.add(script, bucket: "wallet", key: "ada", by: 10)

      expect(memory.add(script, bucket: "wallet", key: "ada", by: -4)).to eq(6)
    end

    # The bound is part of the same statement, so nothing can slip between a
    # check and the write and carry a balance past it.
    it "refuses a change that would go below the floor, leaving the total alone" do
      memory.add(script, bucket: "wallet", key: "ada", by: 3)

      ok, why = memory.add(script, bucket: "wallet", key: "ada", by: -5, floor: 0)
      expect(ok).to be(false)
      expect(why).to match(/below 0/)
      expect(memory.recall(script, room, bucket: "wallet", key: "ada")).to eq(3)
    end

    it "refuses a change that would go above the ceiling" do
      memory.add(script, bucket: "wallet", key: "ada", by: 9)

      expect(memory.add(script, bucket: "wallet", key: "ada", by: 5, ceiling: 10).first).to be(false)
    end

    it "refuses a step that is not a whole number" do
      expect(memory.add(script, bucket: "wallet", key: "ada", by: "lots").first).to be(false)
    end

    it "refuses a bucket name it will not take" do
      expect(memory.add(script, bucket: "has:colon", key: "ada", by: 1).first).to be(false)
    end

    it "leaves nothing behind when the cap refuses a key it would have opened" do
      stub_const("#{described_class}::MAX_KEPT_KEYS", 1)
      memory.add(script, bucket: "wallet", key: "ada", by: 1)

      expect(memory.add(script, bucket: "wallet", key: "grace", by: 1).first).to be(false)
      expect(memory.count_keys(script)).to eq(1)
    end

    it "reads back through recall, and is community wide like anything kept" do
      memory.add(script, bucket: "wallet", key: "ada", by: 7)

      expect(memory.recall(other, "elsewhere", bucket: "wallet", key: "ada")).to eq(7)
    end
  end

  describe "adding to several kept totals at once" do
    it "credits every key named, opening one at zero the first time" do
      memory.add(script, bucket: "wallet", key: "ada", by: 5)

      expect(memory.add_many(script, bucket: "wallet", by: { "ada" => 5, "grace" => 3 })).to be(true)
      expect(memory.recall(script, room, bucket: "wallet", key: "ada")).to eq(10)
      expect(memory.recall(script, room, bucket: "wallet", key: "grace")).to eq(3)
    end

    it "refuses the whole batch, and credits nobody, when one key would cross the floor" do
      memory.add(script, bucket: "wallet", key: "ada", by: 5)
      memory.add(script, bucket: "wallet", key: "grace", by: 1)

      ok, why = memory.add_many(script, bucket: "wallet", by: { "ada" => 5, "grace" => -5 }, floor: 0)
      expect(ok).to be(false)
      expect(why).to match(/below 0/)
      expect(memory.recall(script, room, bucket: "wallet", key: "ada")).to eq(5)
      expect(memory.recall(script, room, bucket: "wallet", key: "grace")).to eq(1)
    end

    it "refuses an empty batch" do
      expect(memory.add_many(script, bucket: "wallet", by: {}).first).to be(false)
    end

    it "refuses a bucket name it will not take" do
      expect(memory.add_many(script, bucket: "has:colon", by: { "ada" => 1 }).first).to be(false)
    end
  end

  describe "moving between two kept totals" do
    before { memory.add(script, bucket: "wallet", key: "ada", by: 10) }

    it "takes from one side and puts it on the other" do
      expect(memory.move(script, bucket: "wallet", from: "ada", to: "grace", amount: 4)).to be(true)
      expect(memory.recall(script, room, bucket: "wallet", key: "ada")).to eq(6)
      expect(memory.recall(script, room, bucket: "wallet", key: "grace")).to eq(4)
    end

    # Half a transfer is the failure worth designing against, so the refusal has
    # to leave both sides exactly as they were.
    it "changes neither side when the giving one cannot afford it" do
      ok, why = memory.move(script, bucket: "wallet", from: "ada", to: "grace", amount: 99)

      expect(ok).to be(false)
      expect(why).to match(/does not have 99/)
      expect(memory.recall(script, room, bucket: "wallet", key: "ada")).to eq(10)
      expect(memory.recall(script, room, bucket: "wallet", key: "grace")).to be_nil
    end

    it "will not go below zero unless a script asks for a lower floor" do
      expect(memory.move(script, bucket: "wallet", from: "ada", to: "grace", amount: 15).first).to be(false)
      expect(memory.move(script, bucket: "wallet", from: "ada", to: "grace",
                                 amount: 15, floor: -10)).to be(true)
      expect(memory.recall(script, room, bucket: "wallet", key: "ada")).to eq(-5)
    end

    it "refuses to move something onto itself" do
      expect(memory.move(script, bucket: "wallet", from: "ada", to: "ada", amount: 1).first).to be(false)
    end

    it "refuses an amount that is not a whole number" do
      expect(memory.move(script, bucket: "wallet", from: "ada", to: "grace",
                                 amount: "some").first).to be(false)
    end

    # A negative amount flips which side is actually being debited, but the
    # floor the caller passed always applied to `from`. Without this refusal
    # a negative amount drained `to` straight past its floor, since apply_move
    # never gave the target side a floor at all.
    it "refuses a negative amount rather than letting it drain the target" do
      ok, why = memory.move(script, bucket: "wallet", from: "ada", to: "grace",
                                    amount: -4, floor: 0)

      expect(ok).to be(false)
      expect(why).to match(/positive/)
      expect(memory.recall(script, room, bucket: "wallet", key: "ada")).to eq(10)
      expect(memory.recall(script, room, bucket: "wallet", key: "grace")).to be_nil
    end

    # move used to apply neither of the bounds add enforces: it credited the target
    # unconditionally and took its floor straight from the script, so one host call put a
    # total a thousand times past the documented cap and another the same distance below it.
    describe "the store's own bounds" do
      let(:cap) { Rubotty::Scripting::Memory::MAX_KEPT_VALUE }

      it "refuses an amount larger than a kept number can be" do
        ok, why = memory.move(script, bucket: "wallet", from: "nobody", to: "ada",
                                      amount: cap * 1000, floor: -(cap * 1000))

        expect(ok).to be(false)
        expect(why).to match(/under #{cap}/)
      end

      it "leaves both sides untouched when it refuses" do
        memory.move(script, bucket: "wallet", from: "nobody", to: "ada",
                            amount: cap * 1000, floor: -(cap * 1000))

        expect(memory.recall(script, room, bucket: "wallet", key: "ada")).to eq(10)
        expect(memory.recall(script, room, bucket: "wallet", key: "nobody")).to be_nil
      end

      it "will not credit a target past the ceiling add respects" do
        memory.add(script, bucket: "wallet", key: "rich", by: cap)
        memory.add(script, bucket: "wallet", key: "donor", by: 500)

        ok, why = memory.move(script, bucket: "wallet", from: "donor", to: "rich", amount: 500)

        expect(ok).to be(false)
        expect(why).to match(/#{cap}/)
        expect(memory.recall(script, room, bucket: "wallet", key: "rich")).to eq(cap)
        expect(memory.recall(script, room, bucket: "wallet", key: "donor")).to eq(500)
      end

      # A floor below the store's range cannot take a total past it. Set up on
      # the edge, because that is the only place the clamp is observable.
      it "clamps a floor the script asked for to the store's own range" do
        memory.add(script, bucket: "wallet", key: "owing", by: -(cap - 5))

        ok, = memory.move(script, bucket: "wallet", from: "owing", to: "grace",
                                  amount: 100, floor: -(cap * 1000))

        expect(ok).to be(false)
        expect(memory.recall(script, room, bucket: "wallet", key: "owing")).to eq(-(cap - 5))
      end

      # The ordinary overdraft a script asks for still works, so the clamp is a
      # ceiling on how far the floor may go rather than a removal of the floor.
      it "still honours a floor inside the range" do
        expect(memory.move(script, bucket: "wallet", from: "ada", to: "grace",
                                   amount: 15, floor: -10)).to be(true)
      end
    end
  end

  describe "reading a kept bucket whole" do
    before do
      { "ada" => 30, "grace" => 50, "alan" => 10, "team:red" => 5 }.each do |key, value|
        memory.remember(script, room, bucket: "scores", key: key, value: value, ttl: "never")
      end
    end

    it "answers the highest first, which is what makes a leaderboard one call" do
      expect(memory.top(script, "scores", 2)).to eq([{ "key" => "grace", "value" => 50 },
                                                     { "key" => "ada", "value" => 30 }])
    end

    it "answers the whole bucket when there is less than the limit" do
      expect(memory.top(script, "scores").length).to eq(4)
    end

    it "refuses to answer more rows than the ceiling" do
      expect(memory.top(script, "scores", 10_000).length).to eq(4)
    end

    it "never reaches another bucket" do
      memory.remember(script, room, bucket: "wallet", key: "ada", value: 999, ttl: "never")

      expect(memory.top(script, "scores").map { |row| row["value"] }).not_to include(999)
    end

    it "lists the names under a prefix" do
      expect(memory.keys(script, "scores", "team:")).to eq(["team:red"])
    end

    it "reads an empty prefix as the whole bucket" do
      expect(memory.keys(script, "scores").length).to eq(4)
    end

    # The prefix test is done in Ruby precisely so it cannot mean one thing on
    # SQLite, where LIKE folds ASCII case, and another on MariaDB, where the
    # binary collation does not.
    it "matches the prefix exactly, case and all, on every backend alike" do
      memory.remember(script, room, bucket: "scores", key: "TEAM:blue", value: 1, ttl: "never")

      expect(memory.keys(script, "scores", "team:")).to eq(["team:red"])
    end

    it "answers nothing at all for a bucket name it will not take" do
      expect(memory.top(script, "has:colon")).to eq([])
      expect(memory.keys(script, "has:colon")).to eq([])
      expect(memory.count_keys(script, "has:colon")).to eq(0)
    end

    it "answers key and value together, in key order rather than highest first" do
      expect(memory.entries(script, "scores")).to eq(
        [{ "key" => "ada", "value" => 30 }, { "key" => "alan", "value" => 10 },
         { "key" => "grace", "value" => 50 }, { "key" => "team:red", "value" => 5 }]
      )
    end

    it "filters entries to a prefix the same way keys does" do
      expect(memory.entries(script, "scores", "team:")).to eq([{ "key" => "team:red", "value" => 5 }])
    end

    it "answers nothing for a bucket name it will not take" do
      expect(memory.entries(script, "has:colon")).to eq([])
    end
  end
end
