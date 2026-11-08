# frozen_string_literal: true

require "spec_helper"
require "rubotty/scripting"

# What wakes a script. Ruby decides at this layer, so no interpreter is involved. The
# property every one of these asserts is that state stays bounded and content free: a
# rule remembers whether something matched, or who spoke, never what anybody wrote.
RSpec.describe Rubotty::Scripting::Triggers do
  def event(text, author: "ada", id: nil)
    described_class::Event.new(text: text, author_id: id || author, author_name: author, room_key: "general")
  end

  describe described_class::Ring do
    it "keeps only the last N and forgets the rest" do
      ring = described_class.new(3)
      5.times { |i| ring.push(i) }

      expect(ring.to_a).to eq([2, 3, 4])
      expect(ring.length).to eq(3)
    end

    it "never grows past its size however much it is fed" do
      ring = described_class.new(2)
      1_000.times { |i| ring.push(i) }

      expect(ring.length).to eq(2)
    end
  end

  describe "always" do
    it "wakes on every message" do
      trigger = Rubotty::Scripting::Triggers.build("always")

      expect(trigger.observe(event("anything"))).to include("text" => "anything")
    end
  end

  describe "contains" do
    subject(:trigger) { Rubotty::Scripting::Triggers.build("contains", "words" => %w[crypto airdrop]) }

    it "wakes and reports which words matched" do
      expect(trigger.observe(event("free airdrop here"))).to include("matched" => ["airdrop"])
    end

    it "stays asleep when nothing matches" do
      expect(trigger.observe(event("morning all"))).to be_nil
    end

    it "ignores case unless asked not to" do
      expect(trigger.observe(event("CRYPTO"))).not_to be_nil
      cased = Rubotty::Scripting::Triggers.build("contains", "words" => ["Crypto"], "case_sensitive" => true)
      expect(cased.observe(event("crypto"))).to be_nil
    end
  end

  describe "recent_contains" do
    subject(:trigger) do
      Rubotty::Scripting::Triggers.build("recent_contains", "words" => ["http"], "window" => 5, "count" => 3)
    end

    it "stays asleep until the window holds enough hits" do
      expect(trigger.observe(event("http one"))).to be_nil
      expect(trigger.observe(event("http two"))).to be_nil
      expect(trigger.observe(event("http three"))).to include("hits" => 3)
    end

    it "only wakes on a message that itself matched" do
      3.times { |i| trigger.observe(event("http #{i}")) }

      expect(trigger.observe(event("nothing here"))).to be_nil
    end

    it "forgets hits that fall out of the window" do
      3.times { |i| trigger.observe(event("http #{i}")) }
      5.times { trigger.observe(event("quiet")) }

      expect(trigger.observe(event("http again"))).to be_nil
    end
  end

  describe "recent_senders" do
    subject(:trigger) do
      Rubotty::Scripting::Triggers.build("recent_senders", "names" => %w[ada grace], "window" => 4)
    end

    it "wakes once every named person is in the window" do
      expect(trigger.observe(event("hi", author: "ada"))).to be_nil
      expect(trigger.observe(event("hello", author: "grace"))).not_to be_nil
    end

    it "stays asleep when one of them has aged out" do
      trigger.observe(event("hi", author: "ada"))
      4.times { trigger.observe(event("chatter", author: "someone")) }

      expect(trigger.observe(event("hello", author: "grace"))).to be_nil
    end
  end

  describe "author_repeat" do
    subject(:trigger) do
      Rubotty::Scripting::Triggers.build("author_repeat", "window" => 6, "count" => 3)
    end

    it "wakes when one person dominates the window" do
      expect(trigger.observe(event("1", author: "ada"))).to be_nil
      expect(trigger.observe(event("2", author: "ada"))).to be_nil
      expect(trigger.observe(event("3", author: "ada"))).to include("count" => 3)
    end

    it "does not count other people towards it" do
      trigger.observe(event("1", author: "ada"))
      trigger.observe(event("2", author: "bob"))

      expect(trigger.observe(event("3", author: "ada"))).to be_nil
    end
  end

  describe "new_voice" do
    subject(:trigger) { Rubotty::Scripting::Triggers.build("new_voice", "window" => 5) }

    it "wakes the first time somebody speaks" do
      expect(trigger.observe(event("hello", author: "newcomer"))).not_to be_nil
    end

    it "stays asleep for their next message" do
      trigger.observe(event("hello", author: "newcomer"))

      expect(trigger.observe(event("again", author: "newcomer"))).to be_nil
    end
  end

  describe "command" do
    subject(:trigger) { Rubotty::Scripting::Triggers.build("command", "name" => "roll") }

    it "wakes on either prefix and hands over the arguments" do
      expect(trigger.observe(event("/roll 2d6"))).to include("command" => "roll", "args" => "2d6")
      expect(trigger.observe(event("!roll"))).to include("args" => "")
    end

    it "tolerates the @botname suffix Telegram adds" do
      expect(trigger.observe(event("/roll@rubotty 2d6"))).to include("args" => "2d6")
    end

    it "stays asleep for ordinary text and for a different command" do
      expect(trigger.observe(event("roll it"))).to be_nil
      expect(trigger.observe(event("/weather"))).to be_nil
    end
  end

  it "refuses a trigger type that is not in the catalog" do
    expect { Rubotty::Scripting::Triggers.build("arbitrary_lookback") }
      .to raise_error(Rubotty::Scripting::Failed, /no trigger type/)
  end
end

# Everything else in the catalog folds in a message. This one is woken on a clock, so
# what matters is that it never fires on traffic and that its next run lands where an
# operator would expect.
RSpec.describe Rubotty::Scripting::Triggers::Recurring do
  def build(config) = Rubotty::Scripting::Triggers.build("recurring", config)

  it "never wakes on a message, whatever the message says" do
    trigger = build({ "every" => "day" })
    event = Rubotty::Scripting::Triggers::Event.new(text: "anything at all", author_name: "ada")

    expect(trigger.observe(event)).to be_nil
  end

  it "takes the cadence from the form, defaulting to a day" do
    expect(build({ "every" => "hour" }).interval).to eq(60 * 60)
    expect(build({ "every" => "week" }).interval).to eq(7 * 24 * 60 * 60)
    expect(build({}).interval).to eq(24 * 60 * 60)
  end

  describe "the next run" do
    let(:noon) { Time.utc(2026, 7, 29, 12, 0) }

    it "is today when the time of day is still ahead" do
      expect(build({ "every" => "day", "at" => "18:30" }).next_run(noon))
        .to eq(Time.utc(2026, 7, 29, 18, 30))
    end

    it "is tomorrow once the time of day has passed" do
      expect(build({ "every" => "day", "at" => "09:00" }).next_run(noon))
        .to eq(Time.utc(2026, 7, 30, 9, 0))
    end

    # A bare Integer("09") is read as octal and is invalid, so every time before 10:00
    # silently became "no time set".
    it "reads a leading zero hour as the hour, not as octal" do
      expect(build({ "every" => "day", "at" => "09:00" }).next_run(Time.utc(2026, 7, 29, 8, 0)))
        .to eq(Time.utc(2026, 7, 29, 9, 0))
    end

    it "ignores a time of day for an hourly one, which has no day to sit in" do
      expect(build({ "every" => "hour", "at" => "09:00" }).next_run(noon))
        .to eq(Time.utc(2026, 7, 29, 13, 0))
    end

    # Was "one interval from now", which a restart moved every time.
    it "falls back to the next boundary when no time was set" do
      expect(build({ "every" => "day" }).next_run(noon)).to eq(Time.utc(2026, 7, 30))
    end
  end
end

# "Third link in ten minutes". Every other windowed trigger counts messages, which is
# the wrong unit for pace: twenty messages is a minute in a busy room and a week in a
# quiet one.
RSpec.describe Rubotty::Scripting::Triggers::ContainsRate do
  let(:now) { Time.utc(2026, 7, 29, 12, 0) }

  def trigger(clock)
    Rubotty::Scripting::Triggers.build(
      "contains_rate", { "words" => ["http"], "count" => 3, "minutes" => 10 }, clock
    )
  end

  def link(text = "see http://example.com")
    Rubotty::Scripting::Triggers::Event.new(text: text, author_name: "ada")
  end

  it "stays asleep until the count is reached inside the window" do
    at = now
    rule = trigger(-> { at })

    expect(rule.observe(link)).to be_nil
    expect(rule.observe(link)).to be_nil
    expect(rule.observe(link)).to include("count" => 3, "minutes" => 10)
  end

  it "ignores a message that does not contain the words at all" do
    rule = trigger(-> { now })

    expect(rule.observe(Rubotty::Scripting::Triggers::Event.new(text: "just talking"))).to be_nil
  end

  # The whole point of a time window: two hits an hour apart are not a rate.
  it "forgets a hit once it has aged out of the window" do
    at = now
    rule = trigger(-> { at })

    rule.observe(link)
    rule.observe(link)
    at = now + (11 * 60)

    expect(rule.observe(link)).to be_nil
  end

  it "fires again once three land inside the window after an old one aged out" do
    at = now
    rule = trigger(-> { at })
    rule.observe(link)
    at = now + (11 * 60)

    expect(rule.observe(link)).to be_nil
    expect(rule.observe(link)).to be_nil
    expect(rule.observe(link)).to include("count" => 3)
  end

  # Instants only, never text or authorship, which is what lets the privacy claim
  # survive a time window.
  it "keeps no message text, only when a match happened" do
    at = now
    rule = trigger(-> { at })
    rule.observe(link("a secret link http://x"))

    kept = rule.instance_variable_get(:@ring).instance_variable_get(:@times)
    expect(kept).to all(be_a(Time))
  end
end

# The editor's trigger panel is rendered from these class methods, so a wrong
# hands_over tells somebody to read m.words when the payload carries m.matched.
# Compared against what observe returns, since a second hand written list would drift
# the same way.
RSpec.describe "what each trigger says it hands over" do
  # Config, and the messages needed to make it fire.
  CASES = {
    "always" => [{}, ["hi"]],
    "contains" => [{ "words" => ["bad"] }, ["a bad word"]],
    "recent_contains" => [{ "words" => ["bad"], "window" => 5, "count" => 1 }, ["a bad word"]],
    "recent_senders" => [{ "names" => ["ada"], "window" => 5 }, ["hi"]],
    "author_repeat" => [{ "window" => 5, "count" => 1 }, ["hi"]],
    "new_voice" => [{ "window" => 5 }, ["hi"]],
    "command" => [{ "name" => "roll" }, ["/roll 2d6"]],
    "contains_rate" => [{ "words" => ["bad"], "count" => 1, "minutes" => 10 }, ["a bad word"]]
  }.freeze

  def fire(name, config, texts)
    trigger = Rubotty::Scripting::Triggers.build(name, config)
    texts.map do |text|
      trigger.observe(
        Rubotty::Scripting::Triggers::Event.new(text: text, author_id: "ada", author_name: "ada")
      )
    end.compact.last
  end

  CASES.each do |name, (config, texts)|
    it "#{name} hands over exactly what it says it does" do
      payload = fire(name, config, texts)

      expect(payload).not_to be_nil, "#{name} never fired, so this proves nothing"
      expect(payload.keys).to match_array(Rubotty::Scripting::Triggers::BY_NAME[name].hands_over)
    end
  end

  # recurring is woken on a clock and never sees a message, so it has no observe
  # payload to compare against.
  it "covers every trigger that reacts to a message" do
    reactive = Rubotty::Scripting::Triggers.type_names - ["recurring"]

    expect(CASES.keys).to match_array(reactive)
  end
end

# A time of day is a free text field on the editor form, and everything it can
# be given used to reach Time.utc unchecked.
RSpec.describe Rubotty::Scripting::Triggers::Recurring do
  def build(at) = Rubotty::Scripting::Triggers.build("recurring", { "every" => "day", "at" => at })

  let(:now) { Time.utc(2026, 7, 29, 12, 0, 0) }

  it "refuses an hour that is not one" do
    expect { build("25:00") }.to raise_error(Rubotty::Scripting::Failed, /not a time of day/)
  end

  it "refuses a minute that is not one" do
    expect { build("12:70") }.to raise_error(Rubotty::Scripting::Failed, /not a time of day/)
  end

  it "takes a real time, including one before ten, which reads as octal unaided" do
    expect(build("09:30").next_run(now)).to eq(Time.utc(2026, 7, 30, 9, 30))
  end

  # The schedule is rebuilt at every boot, so a cadence measured from startup is
  # pushed out by every restart.
  it "runs a script with no time set on the next boundary, not an interval from now" do
    expect(build("").next_run(Time.utc(2026, 7, 29, 12, 34, 56))).to eq(Time.utc(2026, 7, 30))
  end

  it "runs an hourly one on the hour, whenever this process happened to start" do
    hourly = Rubotty::Scripting::Triggers.build("recurring", { "every" => "hour" })

    expect(hourly.next_run(Time.utc(2026, 7, 29, 12, 34, 56))).to eq(Time.utc(2026, 7, 29, 13))
  end

  # A row saved before the check above is still out there.
  it "does not raise on a stored time it cannot use, so one script fails alone" do
    stored = described_class.new({ "every" => "day", "at" => "25:00" }, nil)

    expect(stored.next_run(now)).to eq(Time.utc(2026, 7, 30))
  end
end

# A script used to carry exactly one condition, so hearing a command, free text and a
# clock at once used to mean three scripts unable to share what memos (scoped per script)
# knew. The schema was not widened for this: extras ride inside trigger_config under a key
# no trigger reads, so a row written before this existed still builds the one trigger it always did.
RSpec.describe "a script carrying several conditions" do
  def declared(type, config = {}) = Rubotty::Scripting::Triggers.declared(type, config)

  it "reads a row with nothing extra as the one condition it always was" do
    expect(declared("contains", { "words" => ["bad"] }))
      .to eq([["contains", { "words" => ["bad"] }]])
  end

  it "reads a bare name as a second condition sharing the first one's settings" do
    types = declared("command", { "name" => "deal", "triggers" => ["always"] })

    expect(types.map(&:first)).to eq(%w[command always])
    expect(types.last.last).to eq({ "name" => "deal" })
  end

  it "lets an extra carry settings of its own, over the shared ones" do
    types = declared("command",
                     { "name" => "deal", "edits" => "true",
                       "triggers" => [{ "type" => "contains", "words" => %w[bingo] }] })

    expect(types.last).to eq(["contains", { "name" => "deal", "edits" => "true", "words" => %w[bingo] }])
  end

  it "never leaves the list itself in a trigger's settings" do
    types = declared("always", { "triggers" => ["command"] })

    types.each { |_type, config| expect(config).not_to have_key("triggers") }
  end

  it "drops a blank extra rather than refusing the save over it" do
    expect(declared("always", { "triggers" => ["", { "type" => "" }, nil] }).map(&:first)).to eq(["always"])
  end

  # Every condition is folded in on every message, so this bounds per-message
  # work rather than ambition.
  it "refuses more than a script is allowed to carry" do
    too_many = { "triggers" => Array.new(Rubotty::Scripting::Triggers::MAX, "always") }

    expect { declared("always", too_many) }
      .to raise_error(Rubotty::Scripting::Failed, /#{Rubotty::Scripting::Triggers::MAX} triggers/)
  end

  it "builds each one as its own trigger, with its own state" do
    built = Rubotty::Scripting::Triggers.build_all("command", { "name" => "deal", "triggers" => ["always"] })

    expect(built.map { |trigger| trigger.class.type_name }).to eq(%w[command always])
  end

  # The rule tries them in order and stops at the first match, so one message
  # never runs the script twice.
  describe "through a rule" do
    def rule(type, config)
      Rubotty::Scripting::Rule.from_config(name: "game", kind: :processor, source: "return nil",
                                           trigger_type: type, trigger_config: config)
    end

    def event(text)
      Rubotty::Scripting::Triggers::Event.new(text: text, author_id: "ada", author_name: "ada")
    end

    it "wakes on either condition, and says which one did it" do
      built = rule("command", { "name" => "deal", "triggers" => ["always"] })

      expect(built.fire(event("/deal")).first.class.type_name).to eq("command")
      expect(built.fire(event("just talking")).first.class.type_name).to eq("always")
    end

    it "hands over the payload of the condition that matched" do
      built = rule("command", { "name" => "deal", "triggers" => ["always"] })

      expect(built.fire(event("/deal 3")).last).to include("command" => "deal", "args" => "3")
      expect(built.fire(event("just talking")).last).not_to have_key("command")
    end
  end
end

# Core::Message::KINDS has carried :edit all along and no script ever saw one, so a rule
# that scored a guess of 1200 went on scoring 1200 after the author had edited it to 9999
# in front of the whole room.
RSpec.describe "a trigger that hears edits" do
  def event(text, edited: false)
    Rubotty::Scripting::Triggers::Event.new(text: text, author_id: "ada", author_name: "ada",
                                            edited: edited)
  end

  def rule(config)
    Rubotty::Scripting::Rule.from_config(name: "scores", kind: :processor, source: "return nil",
                                         trigger_type: "always", trigger_config: config)
  end

  it "is off unless the script asked for it" do
    expect(Rubotty::Scripting::Triggers.build("always").hears_edits?).to be(false)
    expect(Rubotty::Scripting::Triggers.build("always", { "edits" => "true" }).hears_edits?).to be(true)
  end

  it "never wakes a script that did not ask" do
    expect(rule({}).fire(event("9999", edited: true))).to be_nil
    expect(rule({}).fire(event("9999"))).not_to be_nil
  end

  it "wakes one that did" do
    expect(rule({ "edits" => "true" }).fire(event("9999", edited: true))).not_to be_nil
  end

  # The reason the skip happens before observe rather than after: a windowed
  # condition would otherwise count one message twice for a script that never
  # thought about edits at all.
  it "leaves a windowed condition's count alone for a script that did not ask" do
    counting = Rubotty::Scripting::Rule.from_config(
      name: "flood", kind: :processor, source: "return nil", trigger_type: "author_repeat",
      trigger_config: { "window" => 10, "count" => 3 }
    )

    counting.fire(event("one"))
    4.times { counting.fire(event("one", edited: true)) }
    counting.fire(event("two"))

    expect(counting.fire(event("three")).last).to include("count" => 3)
  end
end
