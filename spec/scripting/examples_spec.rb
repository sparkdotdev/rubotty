# frozen_string_literal: true

require "spec_helper"
require "rubotty/scripting"

# The shipped example scripts, run for real. These exist so the examples are executable
# rather than illustrative: an example in a doc rots the moment the payload shape changes,
# one that runs in CI cannot. Every script here is loaded from examples/scripting, woken
# through its documented trigger, and asserted on its actual answer.
RSpec.describe "the example scripts" do
  before(:all) do
    skip "no Lua interpreter on PATH" if Rubotty::Scripting::Child.find_binary.nil?
  end

  # Qualified so a worktree run resolves against this checkout's own root.
  EXAMPLES_ROOT = File.expand_path("../../examples/scripting", __dir__)

  let(:sent) { [] }

  # The real classifier against the shipped word list, so an example that
  # replaces swearing is asserted on what the base list actually holds rather
  # than on a stub agreeing with it.
  let(:classifier) { Rubotty::Scripting::Classifier.new(config: {}) }

  # Seeded, so an example that picks at random picks the same thing twice, the same reason
  # the smoke test hands over a seeded generator. Built fresh on each call rather than
  # shared, because two runs off one generator draw different numbers and comparing
  # dialects needs them equal.
  def build_registry
    Rubotty::Scripting::Registry.new.tap do |r|
      # The mode is captured, not just the text: an example that means to wake
      # somebody and quietly records instead would otherwise pass this suite.
      r.register("alert") { |text, mode = nil| sent << ["alert", text, mode || "quiet"]; true }
      r.register("notify") { |text| sent << ["notify", text]; true }
      r.register("rooms") { ["general", "banking", "visas and residency"] }
      r.register("classify") { |text| classifier.classify(text) }
      r.register("offending_spans") { |text| classifier.spans(text) }
      r.register("random", &Rubotty::Scripting::HostFunctions.random_handler(generator: Random.new(1)))
      # An example that reads a data file ships one beside it, so the suite runs
      # it against the document an operator would be given rather than against a
      # list this file invented.
      r.register("yaml_data") { yaml_data }
    end
  end

  # The data file the example under test ships, parsed the way the store parses
  # it. Nil for every example that needs none, which is what a script with no
  # data file really sees.
  let(:yaml_data) { nil }

  def example_data(id)
    Rubotty::ControlPlane::Scripts.parse_yaml_data(Rubotty::Scripting::Examples.find(id).data)
  end

  let(:registry) { build_registry }
  let(:pool) { Rubotty::Scripting::Pool.new(size: 1, logger: Rubotty::Log.null) }

  after { pool.close }

  def source(kind, name) = File.read(File.join(EXAMPLES_ROOT, kind, "#{name}.lua"))

  # moonc is not installed in CI (moonscript drags in lpeg and luafilesystem,
  # both C extensions), so the MoonScript half compiles here only when a
  # developer has it. The pairing and the header checks still run everywhere.
  def self.moonc? = system("command -v moonc > /dev/null 2>&1")

  def compile_moon(path)
    out = `moonc -p #{path.shellescape} 2>&1`
    raise "moonc failed for #{path}: #{out}" unless $CHILD_STATUS.success?

    out
  end

  # A config that satisfies each trigger's own validation. The smoke gate cares
  # what shape the payload is, not which words are in it, so one per type is
  # enough and beats parsing the Lua table out of each example's header.
  def trigger_config_for(type)
    case type
    when "contains" then { "words" => ["scam"] }
    when "recent_contains" then { "words" => ["scam"], "window" => 20, "count" => 3 }
    when "recent_senders" then { "names" => %w[ada grace], "window" => 12 }
    when "author_repeat" then { "window" => 8, "count" => 4 }
    when "command" then { "name" => "probe" }
    else {}
    end
  end

  def event(text, author: "ada", id: nil)
    Rubotty::Scripting::Triggers::Event.new(
      text: text, author_id: id || author, author_name: author, room_key: "general"
    )
  end

  # Build the rule the way the dashboard would, run the messages through it, and
  # hand back what the last one decided.
  def run(kind:, name:, trigger:, config: {}, messages:, rule_kind: :processor)
    rule = Rubotty::Scripting::Rule.from_config(
      name: name, kind: rule_kind, source: source(kind, name),
      trigger_type: trigger, trigger_config: config
    )
    set = Rubotty::Scripting::RuleSet.new(rules: [rule], pool: pool, registry: registry,
                                          logger: Rubotty::Log.null,
                                          context: Rubotty::Scripting::Context.new(room_key: "general"))
    last = nil
    Array(messages).each do |message|
      last = rule_kind == :command ? set.replies(message) : set.screen(message)
    end
    last
  end

  describe "commands" do
    it "roll answers a dice expression and refuses a malformed one" do
      rolled = run(kind: "commands", name: "roll", trigger: "command", config: { "name" => "roll" },
                   rule_kind: :command, messages: [event("/roll 2d6")]).first
      expect(rolled).to match(/ada rolled \d+, \d+  \(total \d+\)/)

      usage = run(kind: "commands", name: "roll", trigger: "command", config: { "name" => "roll" },
                  rule_kind: :command, messages: [event("/roll nonsense")]).first
      expect(usage).to eq("Usage: /roll 2d6")
    end

    # A recursive descent parser, which is what a language with no eval needs.
    # load() is absent from the sandbox on purpose, so member-typed arithmetic
    # is parsed rather than executed and can only ever produce a number.
    it "calculate evaluates an expression with correct precedence and brackets" do
      answers = {
        "(5*(4+12))/6" => "13.3333",
        "2+3*4" => "14",
        "10/4" => "2.5",
        "-3 + 10" => "7"
      }

      answers.each do |expression, expected|
        reply = run(kind: "commands", name: "calculate", trigger: "command",
                    config: { "name" => "calculate" }, rule_kind: :command,
                    messages: [event("/calculate #{expression}")]).first

        expect(reply).to eq("#{expression} = #{expected}"), "#{expression} gave #{reply}"
      end
    end

    it "calculate refuses anything that is not arithmetic, without quoting it back" do
      reply = run(kind: "commands", name: "calculate", trigger: "command",
                  config: { "name" => "calculate" }, rule_kind: :command,
                  messages: [event("/calculate rm -rf /")]).first

      expect(reply).to eq("I only do numbers and + - * / % and brackets.")
      expect(reply).not_to include("rm -rf")
    end

    it "calculate reports a division by zero without leaking a line number" do
      reply = run(kind: "commands", name: "calculate", trigger: "command",
                  config: { "name" => "calculate" }, rule_kind: :command,
                  messages: [event("/calculate 1/0")]).first

      expect(reply).to eq("I could not read that: division by zero")
    end

    it "calculate gives usage for a bare invocation" do
      reply = run(kind: "commands", name: "calculate", trigger: "command",
                  config: { "name" => "calculate" }, rule_kind: :command,
                  messages: [event("/calculate")]).first

      expect(reply).to include("Usage:")
    end

    it "rules posts the canned house rules" do
      reply = run(kind: "commands", name: "rules", trigger: "command", config: { "name" => "rules" },
                  rule_kind: :command, messages: [event("/rules")]).first

      expect(reply).to include("House rules:").and include("Be kind")
    end

    it "whereis searches the room list it is handed by the host" do
      reply = run(kind: "commands", name: "whereis", trigger: "command", config: { "name" => "whereis" },
                  rule_kind: :command, messages: [event("/whereis visas")]).first

      expect(reply).to eq("Try: visas and residency")
    end

    it "whereis says so when nothing matches" do
      reply = run(kind: "commands", name: "whereis", trigger: "command", config: { "name" => "whereis" },
                  rule_kind: :command, messages: [event("/whereis quidditch")]).first

      expect(reply).to include("Nothing here matches")
    end
  end

  describe "processors that rewrite" do
    # Swaps against the real base list rather than words named in the script, so
    # what it replaces follows whatever the operator configured.
    it "company_of_heroes swaps the word and leaves the sentence standing" do
      verdict = run(kind: "processors", name: "company_of_heroes", trigger: "always",
                    messages: [event("that is shit and I am fucking done")])

      expect(verdict).to be_rewrite
      expect(verdict.text).to match(/\Athat is \w+ and I am \w+ done\z/)
      expect(verdict.text).not_to include("shit")
      expect(verdict.text).not_to include("fucking")
    end

    # A noun becomes a noun and an adjective an adjective, or the sentence stops
    # parsing. This is what the parts of speech in the base list are for.
    it "company_of_heroes replaces each word with its own part of speech" do
      verdict = run(kind: "processors", name: "company_of_heroes", trigger: "always",
                    messages: [event("what a shitty pile of bollocks")])
      nouns = %w[pudding bicycle hedgehog kerfuffle trombone biscuit]
      plurals = %w[puddings bicycles hedgehogs trombones biscuits]
      adjectives = %w[delightful splendid fluffy marvellous]

      expect(verdict).to be_rewrite
      expect(verdict.text).to match(/\Awhat a (#{adjectives.join("|")}) pile of (#{plurals.join("|")})\z/),
                              "got #{verdict.text.inspect}"
      expect(nouns).not_to include(verdict.text.split.last)
    end

    it "company_of_heroes leaves a word that merely contains one alone" do
      verdict = run(kind: "processors", name: "company_of_heroes", trigger: "always",
                    messages: [event("shiitake mushrooms")])

      expect(verdict).to be_allow
    end

    # Dressing a slur up as something comic would be the wrong answer, so this
    # one is removed rather than rewritten.
    it "company_of_heroes removes a slur rather than making it funny" do
      verdict = run(kind: "processors", name: "company_of_heroes", trigger: "always",
                    messages: [event("you absolute faggot")])

      expect(verdict).to be_reject
    end

    # The offsets are bytes, and Lua's string.sub counts bytes, so an accent
    # earlier in the line must not shift where the cut lands.
    it "company_of_heroes cuts in the right place when the line has accents" do
      verdict = run(kind: "processors", name: "company_of_heroes", trigger: "always",
                    messages: [event("olá cariño, that is shit")])

      expect(verdict).to be_rewrite
      expect(verdict.text).to start_with("olá cariño, that is ")
      expect(verdict.text).not_to include("shit")
    end

    it "shouting turns a long all caps message down" do
      verdict = run(kind: "processors", name: "shouting", trigger: "always",
                    messages: [event("WHY IS NOBODY ANSWERING ME")])

      expect(verdict).to be_rewrite
      expect(verdict.text).to eq("Why is nobody answering me")
    end

    it "shouting leaves a short exclamation alone" do
      verdict = run(kind: "processors", name: "shouting", trigger: "always", messages: [event("OK GREAT")])

      expect(verdict).to be_allow
    end

    it "invisible_text strips a zero width space" do
      verdict = run(kind: "processors", name: "invisible_text", trigger: "always",
                    messages: [event("bad​word")])

      expect(verdict).to be_rewrite
      expect(verdict.text).to eq("badword")
    end

    it "invisible_text rejects a message that was only invisible characters" do
      verdict = run(kind: "processors", name: "invisible_text", trigger: "always",
                    messages: [event("​​")])

      expect(verdict).to be_reject
    end
  end

  describe "processors that reject" do
    it "link_flood rejects once the window holds enough links" do
      messages = 3.times.map { |i| event("look https://example.com/#{i}") }
      verdict = run(kind: "processors", name: "link_flood", trigger: "recent_contains",
                    config: { "words" => ["http://", "https://"], "window" => 10, "count" => 3 },
                    messages: messages)

      expect(verdict).to be_reject
      expect(verdict.reason).to include("3 links in the last 10 messages")
    end

    it "link_flood allows an ordinary single link" do
      verdict = run(kind: "processors", name: "link_flood", trigger: "recent_contains",
                    config: { "words" => ["https://"], "window" => 10, "count" => 3 },
                    messages: [event("here you go https://example.com")])

      expect(verdict).to be_allow
    end

    it "newcomer_links holds a first message that is a link" do
      verdict = run(kind: "processors", name: "newcomer_links", trigger: "new_voice",
                    config: { "window" => 200 }, messages: [event("https://buy-now.example", author: "fresh")])

      expect(verdict).to be_reject
      expect(verdict.reason).to include("first message")
    end

    it "newcomer_links lets a first message that is a greeting through" do
      verdict = run(kind: "processors", name: "newcomer_links", trigger: "new_voice",
                    config: { "window" => 200 }, messages: [event("hello everyone", author: "fresh")])

      expect(verdict).to be_allow
    end
  end

  describe "processors that alert without blocking" do
    it "monologue_alert alerts the operators and allows the message" do
      messages = 4.times.map { |i| event("thought #{i}", author: "ada") }
      verdict = run(kind: "processors", name: "monologue_alert", trigger: "author_repeat",
                    config: { "window" => 8, "count" => 4 }, messages: messages)

      expect(verdict).to be_allow
      expect(sent.last.first).to eq("alert")
      expect(sent.last[1]).to include("ada has sent 4 of the last 8 messages")
    end

    it "crosstalk_alert fires once both named people are in the window" do
      verdict = run(kind: "processors", name: "crosstalk_alert", trigger: "recent_senders",
                    config: { "names" => %w[ada grace], "window" => 12 },
                    messages: [event("hi", author: "ada"), event("hello", author: "grace")])

      expect(verdict).to be_allow
      expect(sent.last[1]).to include("Both ada and grace are active")
    end

    it "repeated_question points at the FAQ and lets the question stand" do
      messages = 3.times.map { |i| event("another visa question #{i}") }
      verdict = run(kind: "processors", name: "repeated_question", trigger: "recent_contains",
                    config: { "words" => %w[visa d7 ari], "window" => 30, "count" => 3 },
                    messages: messages)

      expect(verdict).to be_allow
      expect(sent.last[1]).to include("pinned FAQ").and include("visa")
    end
  end

  # The two delivery modes, which is the whole point of alert taking one. Each
  # of these asserts the mode the example asked for, because "recorded it" and
  # "recorded it and woke somebody" are the difference the feature exists for.
  describe "slur_alert, which uses both alert modes" do
    it "wakes an operator loudly for a slur, and refuses the message" do
      verdict = run(kind: "processors", name: "slur_alert", trigger: "always",
                    messages: [event("you absolute faggot")])

      expect(verdict).to be_reject
      expect(sent.last).to eq(["alert", "ada used a slur in general.", "loud"])
    end

    it "notes ordinary swearing quietly and lets it stand" do
      verdict = run(kind: "processors", name: "slur_alert", trigger: "always",
                    messages: [event("that is shit")])

      expect(verdict).to be_allow
      expect(sent.last).to eq(["alert", "ada tripped the word filter in general.", "quiet"])
    end

    it "raises nothing at all for a message the filter is happy with" do
      verdict = run(kind: "processors", name: "slur_alert", trigger: "always",
                    messages: [event("morning everyone")])

      expect(verdict).to be_allow
      expect(sent).to be_empty
    end
  end

  # The worked example for a script's own data file. Its whole point is that the list lives
  # outside the code, so what is asserted is that the same Lua decides differently when the
  # data changes and does nothing at all when there is none.
  describe "blocklist, which reads its own data file" do
    let(:yaml_data) { example_data("processors/blocklist") }

    it "rejects a phrase from the shipped list, with the reason the file gives" do
      verdict = run(kind: "processors", name: "blocklist", trigger: "always",
                    messages: [event("free mint tonight, dm me")])

      expect(verdict).to be_reject
      expect(verdict.reason).to include("not welcome here")
    end

    it "leaves a message the list says nothing about alone" do
      verdict = run(kind: "processors", name: "blocklist", trigger: "always",
                    messages: [event("anybody know a good bakery")])

      expect(verdict).to be_allow
    end

    # The property the data file exists for: a word is added by editing data
    # while the code stays exactly as it was.
    context "with a different list, and the same code" do
      let(:yaml_data) { { "words" => ["bakery"], "reason" => "no bakeries" } }

      it "follows the file rather than anything written into the script" do
        verdict = run(kind: "processors", name: "blocklist", trigger: "always",
                      messages: [event("anybody know a good bakery")])

        expect(verdict).to be_reject
        expect(verdict.reason).to eq("no bakeries")
      end
    end

    # What every script gets before anybody fills the Data tab in, and what the
    # save time check probes it with, so it has to be a passing shape.
    context "with no data file at all" do
      let(:yaml_data) { nil }

      it "allows everything rather than falling over" do
        verdict = run(kind: "processors", name: "blocklist", trigger: "always",
                      messages: [event("free mint tonight, dm me")])

        expect(verdict).to be_allow
      end
    end
  end

  # The version of Company of Heroes mode that asks rubotty rather than carrying
  # its own copy of the word list.
  describe "filter_replace, which uses classify and offending_spans" do
    let(:classifier) do
      Rubotty::Scripting::Classifier.new(config: { "custom" => %w[pineapple] }, logger: Rubotty::Log.null)
    end
    let(:registry) do
      Rubotty::Scripting::HostFunctions.registry(handlers: {
        "classify" => ->(text) { classifier.classify(text) },
        "offending_spans" => ->(text) { classifier.spans(text) },
        "log" => ->(text) { sent << ["log", text]; true }
      })
    end

    it "leaves clean text alone" do
      verdict = run(kind: "processors", name: "filter_replace", trigger: "always",
                    messages: [event("a perfectly nice sentence")])

      expect(verdict).to be_allow
    end

    it "swaps what the filter caught, without ever seeing the list" do
      verdict = run(kind: "processors", name: "filter_replace", trigger: "always",
                    messages: [event("I hate pineapple on pizza")])

      expect(verdict).to be_rewrite
      expect(verdict.text).to eq("I hate pudding on pizza")
    end

    it "refuses to make a joke out of a slur" do
      verdict = run(kind: "processors", name: "filter_replace", trigger: "always",
                    messages: [event("this is shit")])

      expect(verdict).to be_rewrite
    end
  end


  # The four capabilities that arrived with this branch. The editor tells
  # somebody every example is run in the suite, so a shipped example with no
  # test behind it makes that claim false.
  describe "the newer capabilities" do
    it "link_rate speaks up once the words arrive quickly enough" do
      config = { "words" => ["http://"], "count" => 2, "minutes" => 10 }
      verdict = run(kind: "processors", name: "link_rate", trigger: "contains_rate", config: config,
                    messages: [event("see http://one"), event("and http://two")])

      expect(verdict).to be_allow
      expect(verdict.reply).to include("2 links in 10 minutes")
    end

    it "link_rate stays quiet below the rate" do
      config = { "words" => ["http://"], "count" => 5, "minutes" => 10 }
      verdict = run(kind: "processors", name: "link_rate", trigger: "contains_rate", config: config,
                    messages: [event("see http://one")])

      expect(verdict.reply).to be_nil
    end

    # A recurring script is woken on a clock, so it is run here the way the runtime wakes
    # one: no message, and rubotty.kind() saying which wake it was. Registered with the
    # shape the real handler produces, since a stub returning a shape the handler cannot
    # is how an example that always reads zero passes its own test.
    it "daily_digest reads the community numbers and answers without a message" do
      registry.register("community_stats") { { "members_active" => 12, "members_total" => 30 } }
      registry.register("increment_stat") { |_stat, _row| true }
      registry.register("bold") { |text| text }

      answer = pool.run(source: source("processors", "daily_digest"),
                        arg: Rubotty::Scripting::Context.new(room_key: "general")
                               .decorate({ "invocation_data" => nil }, kind: Rubotty::Scripting::Context::SCHEDULED),
                        registry: registry, timeout: 5)

      expect(answer["action"]).to eq("allow")
      expect(answer["reply"]).to include("Active people lately: 12")
    end

    it "weather_reply says so when the call failed" do
      registry.register("bold") { |text| text }
      answer = pool.run(source: source("callbacks", "weather_reply"),
                        arg: Rubotty::Scripting::Context.new(room_key: "general").decorate(
                          { "invocation_data" => { "city" => "Lisbon" },
                            "response" => { "ok" => false, "status" => 0 } },
                          kind: Rubotty::Scripting::Context::HTTP_CALLBACK
                        ),
                        registry: registry, timeout: 5)

      expect(answer["reply"]).to include("could not reach the weather service for Lisbon")
    end

    it "weather_reply reports the answer when the call worked" do
      registry.register("bold") { |text| text }
      answer = pool.run(source: source("callbacks", "weather_reply"),
                        arg: Rubotty::Scripting::Context.new(room_key: "general").decorate(
                          { "invocation_data" => { "city" => "Lisbon" },
                            "response" => { "ok" => true, "data" => { "summary" => "sunny" } } },
                          kind: Rubotty::Scripting::Context::HTTP_CALLBACK
                        ),
                        registry: registry, timeout: 5)

      expect(answer["reply"]).to eq("Lisbon: sunny")
    end

    # A leaderboard comes back sorted, so the example only has to number the
    # rows. Asserting on the order is what would catch it sorting again in Lua
    # and undoing the one thing `top` is for.
    it "scoreboard ranks a kept bucket, and says so when it is empty" do
      registry.register("top") do |bucket, limit|
        next [] unless bucket == "scores"

        [{ "key" => "grace", "value" => 9 }, { "key" => "ada", "value" => 3 }].first(limit)
      end
      registry.register("bold") { |text| text }

      reply = run(kind: "commands", name: "scoreboard", trigger: "command",
                  config: { "name" => "scoreboard" }, rule_kind: :command,
                  messages: [event("/scoreboard")]).first
      expect(reply).to eq("1. grace 9\n2. ada 3")

      registry.register("top") { |_bucket, _limit| [] }
      empty = run(kind: "commands", name: "scoreboard", trigger: "command",
                  config: { "name" => "scoreboard" }, rule_kind: :command,
                  messages: [event("/scoreboard")]).first
      expect(empty).to eq("Nobody has scored yet.")
    end
  end

  # Trivia, a poll and a timed close, run against the real store rather than
  # against stubs that agree with them. These are the samples the participation
  # storage exists for, and a room's whole game is three of them talking to one
  # session, so anything less than the real thing would prove nothing.
  describe "the participation examples", :control_plane do
    let(:seeded) { seeded_sample }
    let(:models) { seeded[1] }
    let(:community) { models.community.first }
    let(:runs) { Rubotty::ControlPlane::Participation.new(models: models, logger: Rubotty::Log.null) }
    let(:memory) { Rubotty::Scripting::Memory.new(models: models, logger: Rubotty::Log.null) }

    # The row rubotty.add and friends charge against. Any script in the
    # community shares the same kept buckets, so one row stands in for all
    # three games' worth of Lua.
    let(:script_row) do
      models.community_script.create(
        community_id: community.id, name: "game", kind: "processor", language: "lua",
        source: "return nil", compiled: "return nil", trigger_type: "always",
        enabled: false, consecutive_failures: 0, created_at: Time.now, updated_at: Time.now
      )
    end

    let(:yaml_data) { example_data("commands/trivia") }
    let(:registry) { game_registry }

    def room = { community: community, room_key: "general" }

    def refusable(result) = result == true ? true : Rubotty::Scripting::Answer.refuse(result[1])

    # The same handlers the router builds, over the same store, so a change that
    # broke a shipped game would break here first.
    def game_registry
      build_registry.tap do |r|
        r.register("session") { runs.session(**room) }
        r.register("round") { runs.round(**room) }
        r.register("close_session") { refusable(runs.close_session(**room)) }
        r.register("open_session") do |spec|
          refusable(runs.open_session(**room, kind: spec["kind"], label: spec["label"].to_s))
        end
        # open_round answers the round id on success, not a bare true, but a
        # script only ever reads its `ok` half: the router does the same,
        # booking the close before handing Lua back a plain true.
        r.register("open_round") do |spec|
          table = spec || {}
          result = runs.open_round(**room, close_after: table["close_after"], on_close: table["on_close"],
                                   data: table["data"])
          result.is_a?(Array) ? refusable(result) : true
        end
        r.register("close_round") do |spec = nil|
          table = spec || {}
          refusable(runs.close_round(**room, data: table["data"]))
        end
        # The store, over the community's real kept and working rows, the
        # same shape Router's own handlers hand a script.
        r.register("add") do |spec|
          table = spec || {}
          by = table.key?("by") ? table["by"] : 1
          result = if by.is_a?(Hash)
                     memory.add_many(script_row, bucket: table["bucket"], by: by,
                                     floor: table["floor"], ceiling: table["ceiling"])
                   else
                     memory.add(script_row, bucket: table["bucket"], key: table["key"], by: by,
                                floor: table["floor"], ceiling: table["ceiling"])
                   end
          result.is_a?(Array) ? refusable(result) : result
        end
        r.register("top") do |bucket, limit|
          memory.top(script_row, bucket, limit || Rubotty::Scripting::Memory::DEFAULT_TOP_LIMIT)
        end
        r.register("entries") do |bucket, prefix, limit|
          memory.entries(script_row, bucket, prefix.to_s, limit || Rubotty::Scripting::Memory::DEFAULT_KEYS_LIMIT)
        end
        r.register("remember") do |spec|
          table = spec || {}
          refusable(memory.remember(script_row, "general", bucket: table["bucket"], key: table["key"],
                                    value: table["value"], ttl: table["ttl"]))
        end
        r.register("recall") do |spec|
          table = spec || {}
          memory.recall(script_row, "general", bucket: table["bucket"], key: table["key"])
        end
      end
    end

    # One command invocation of +body+, whichever dialect it was compiled from.
    def reply(body, text, command, who: "ada")
      rule = Rubotty::Scripting::Rule.from_config(name: "sample", kind: :command, source: body,
                                                  trigger_type: "command",
                                                  trigger_config: { "name" => command })
      set = Rubotty::Scripting::RuleSet.new(rules: [rule], pool: pool, registry: registry,
                                            logger: Rubotty::Log.null,
                                            context: Rubotty::Scripting::Context.new(room_key: "general"))
      set.replies(event(text, author: who)).first
    end

    def trivia(args, who: "ada", body: source("commands", "trivia"))
      reply(body, "/trivia #{args}".strip, "trivia", who: who)
    end

    def poll(args, who: "ada", body: source("commands", "poll"))
      reply(body, "/poll #{args}".strip, "poll", who: who)
    end

    # Counts what crossed the pipe. "Five host calls" is the property the close
    # exists to demonstrate, and a room with four players in it has to cost the
    # same five as a room with four hundred.
    def counting(inner)
      Struct.new(:inner, :count) do
        def names = inner.names

        def max_calls = inner.max_calls

        def max_broadcasts = inner.max_broadcasts

        def cost_of(name) = inner.cost_of(name)

        def call(name, args)
          self.count += 1
          inner.call(name, args)
        end
      end.new(inner, 0)
    end

    # The timed close, woken the way rubotty.schedule wakes it: no message
    # behind it, and what a right answer pays read off the round's own data
    # rather than a data file of round_close's own.
    def close_round(body: source("callbacks", "round_close"), on: nil)
      pool.run(source: body,
               arg: Rubotty::Scripting::Context.new(room_key: "general")
                      .decorate({ "invocation_data" => nil }, kind: Rubotty::Scripting::Context::SCHEDULED),
               registry: on || game_registry, timeout: 5)
    end

    describe "trivia" do
      it "says so before anybody has started one" do
        expect(trivia("scores")).to eq("No quiz is running here. /trivia start begins one.")
      end

      it "asks the first question off its own data file" do
        expect(trivia("start")).to eq("Question 1. Which city is the capital of Portugal?")
      end

      it "refuses a second quiz in the same room, in words" do
        trivia("start")

        expect(trivia("start")).to include("already running in this room")
      end

      it "takes an answer without telling the room what it was" do
        trivia("start")

        answered = trivia("answer Lisbon")
        expect(answered).to eq("Answer noted. Nobody sees it until the round closes.")
        expect(answered).not_to include("Lisbon")
      end

      it "scores two people apart on the same question" do
        trivia("start")
        trivia("answer Lisbon", who: "ada")
        trivia("answer Porto", who: "grace")
        close_round

        expect(trivia("scores")).to eq("ada: 10\ngrace: 0")
      end

      # Asking again works off how many rounds the session has held, which is
      # why the closed round does not have to be remembered anywhere.
      it "moves to the next question after the last one closed" do
        trivia("start")
        close_round

        expect(trivia("next")).to eq("Question 2. What does HTTP stand for?")
      end

      it "runs out of questions rather than falling over" do
        trivia("start")
        4.times { trivia("next") }

        expect(trivia("next")).to include("That was the last one")
      end

      it "posts the final scores and lets a fresh quiz start" do
        trivia("start")
        trivia("answer Lisbon")
        close_round

        expect(trivia("stop")).to eq("Final scores.\nada: 10")
        expect(trivia("start")).to eq("Question 1. Which city is the capital of Portugal?")
      end

      it "reports where the quiz is when it is asked nothing in particular" do
        trivia("start")
        trivia("answer Lisbon")

        expect(trivia("")).to start_with("Question 1, 1 playing.")
      end
    end

    # The five call close. Every number in this test is the point of it: a room
    # can hold hundreds of players, and this speaks to all of them at once.
    describe "round_close" do
      it "pays everybody who was right and posts one message" do
        trivia("start")
        trivia("answer Lisbon", who: "ada")
        trivia("answer lisbon ", who: "grace")
        trivia("answer Porto", who: "kwame")

        answer = close_round
        expect(answer["reply"]).to eq("Round 1 is closed.\nRight: ada, grace\nLeading: ada on 10.")
      end

      it "says nobody got it rather than posting an empty line" do
        trivia("start")
        trivia("answer Porto")

        expect(close_round["reply"]).to include("Nobody got that one.")
      end

      # Woken on a timer that outlived the quiz, which is the ordinary way this
      # runs into nothing at all.
      it "does nothing at all when no round is open" do
        expect(close_round).to eq({ "action" => "allow" })
      end

      it "closes a round in five host calls, whatever the room holds" do
        trivia("start")
        %w[ada grace kwame quinn].each { |who| trivia("answer Lisbon", who: who) }

        counter = counting(game_registry)
        close_round(on: counter)

        expect(counter.count).to eq(5)
      end
    end

    describe "poll" do
      let(:yaml_data) { nil }

      it "asks for the shape it wants rather than opening an empty poll" do
        expect(poll("ask just a question")).to start_with("Usage:")
      end

      it "opens a poll with its choices" do
        expect(poll("ask Which night? | Tuesday | Wednesday"))
          .to eq("Which night?\nTuesday / Wednesday\nVote with /poll vote <choice>.")
      end

      it "counts votes without minding how they were capitalised" do
        poll("ask Which night? | Tuesday | Wednesday")
        poll("vote Tuesday", who: "ada")
        poll("vote tuesday", who: "grace")

        expect(poll("")).to eq("Which night?\nTuesday: 2\nWednesday: 0")
      end

      it "lets somebody change their mind rather than voting twice" do
        poll("ask Which night? | Tuesday | Wednesday")
        poll("vote Tuesday", who: "ada")
        poll("vote Wednesday", who: "ada")

        expect(poll("")).to eq("Which night?\nTuesday: 0\nWednesday: 1")
      end

      it "closes with the result, and stops taking votes" do
        poll("ask Which night? | Tuesday | Wednesday")
        poll("vote Tuesday")

        expect(poll("close")).to eq("Poll closed. Which night?\nTuesday: 1\nWednesday: 0")
        expect(poll("vote Wednesday")).to include("No poll is running here")
      end
    end

    # Every dialect has to run the same game, or "write it in whichever you
    # like" is a lie. Compiled here rather than committed, the same way the
    # comparison below does it.
    describe "the dialects agreeing" do
      let(:compiler) { Rubotty::Scripting::Compiler.new }

      Rubotty::Scripting::Dialects::ALL.reject(&:native?).each do |dialect|
        context "in #{dialect.label}", if: Rubotty::Scripting::Dialects.installed?(dialect.binary) do
          def compiled(dialect, id)
            compiler.compile(Rubotty::Scripting::Examples.find(id).source(dialect.name),
                             language: dialect.name)
          end

          it "runs a whole quiz the way the Lua does" do
            body = compiled(dialect, "commands/trivia")

            expect(trivia("start", body: body)).to eq("Question 1. Which city is the capital of Portugal?")
            trivia("answer Lisbon", who: "ada", body: body)
            trivia("answer Porto", who: "grace", body: body)
            expect(close_round(body: compiled(dialect, "callbacks/round_close"))["reply"])
              .to eq("Round 1 is closed.\nRight: ada\nLeading: ada on 10.")
            expect(trivia("scores", body: body)).to eq("ada: 10\ngrace: 0")
          end

          it "runs a whole poll the way the Lua does" do
            body = compiled(dialect, "commands/poll")

            poll("ask Which night? | Tuesday | Wednesday", body: body)
            poll("vote Tuesday", who: "ada", body: body)
            expect(poll("", body: body)).to eq("Which night?\nTuesday: 1\nWednesday: 0")
          end
        end
      end
    end
  end

  # The picker in the editor reads these, so what it offers has to line up with
  # what is on disk and with what the specs above actually ran.
  describe "the shipped example catalog" do
    it "finds every example the directories hold" do
      # Read from the loader's own directory map, so adding a kind cannot leave
      # this counting two thirds of what ships.
      dirs = Rubotty::Scripting::Examples::DIRS.values.join(",")
      on_disk = Dir[File.join(EXAMPLES_ROOT, "{#{dirs}}", "*.lua")].length

      expect(Rubotty::Scripting::Examples.all.length).to eq(on_disk)
    end

    # These are the reference implementation every community forks, and a fork inherits
    # whatever is in them. A script is handed nothing now, so an example still reading the
    # old vararg would not merely be out of date: it would hand somebody a rule that fails
    # its own save gate.
    it "reads nothing off the table a script used to be handed" do
      Dir[File.join(EXAMPLES_ROOT, "*", "*.{lua,moon,fnl,tl}")].sort.each do |path|
        body = File.read(path)

        expect(body).not_to match(/^\s*(local )?m = \.\.\./), "#{path} still takes the old vararg"
        expect(body.scan(/\bm\.[a-z_]+/)).to be_empty, "#{path} still reads a field off m"
      end
    end

    # Somebody writing any supported dialect should only ever be shown that dialect, so
    # every example exists in all of them, hand written. This is what stops one dialect
    # quietly falling behind when a new example is added.
    it "has every example hand written in every dialect" do
      Rubotty::Scripting::Examples.all.each do |example|
        expect(example.languages.sort).to eq(Rubotty::Scripting::Dialects.names.sort),
                                          "#{example.id} is missing a dialect"
      end
    end

    # Every shipped example has to pass the same gate an operator's own script
    # must pass before it can be enabled. An example that cannot be turned on is
    # not an example, and this catches one that breaks on empty input, garbage
    # punctuation or an accent long before anybody copies it.
    it "passes the smoke test every operator script has to pass" do
      smoke = Rubotty::Scripting::SmokeTest.new(pool: pool, logger: Rubotty::Log.null,
                                                timeout: SMOKE_TEST_SPEC_TIMEOUT)

      Rubotty::Scripting::Examples.all.each do |example|
        trigger = Rubotty::Scripting::Triggers.build(example.trigger_type,
                                                     trigger_config_for(example.trigger_type))
        # Gated against its own shipped data, exactly as an operator's script is
        # gated against theirs, so an example that reads a list is checked on
        # the branch it actually takes.
        result = smoke.run(kind: example.kind.to_sym, source: example.source("lua"), trigger: trigger,
                           yaml_data: Rubotty::ControlPlane::Scripts.parse_yaml_data(example.data))

        expect(result).to be_ok, "#{example.id} fails the smoke gate: #{result}"
      end
    end

    it "never offers compiler output as an example" do
      expect(Dir[File.join(EXAMPLES_ROOT, "**", "*.lua")].map { |p| File.read(p) })
        .to all(satisfy { |body| !body.include?("local _class_0") })
    end

    it "reads each one's trigger out of its own header rather than guessing" do
      Rubotty::Scripting::Examples.all.each do |example|
        expect(Rubotty::Scripting::Triggers.type_names).to include(example.trigger_type),
                                                           "#{example.id} names an unknown trigger"
      end
    end

    it "gives every example a summary and a body in each dialect" do
      Rubotty::Scripting::Examples.all.each do |example|
        expect(example.summary).not_to be_empty, "#{example.id} has no summary"
        example.languages.each do |language|
          expect(example.source(language)).not_to be_empty, "#{example.id} has no #{language} source"
        end
      end
    end

    it "declares the same trigger in every dialect it ships in" do
      Rubotty::Scripting::Examples.all.each do |example|
        example.languages.each do |language|
          dialect = Rubotty::Scripting::Dialects.find(language)
          declared = example.source(language)[dialect.trigger_pattern, 1]
          expect(declared).to eq(example.trigger_type),
                              "#{example.id} names a different trigger in #{language}"
        end
      end
    end
  end

  # Every dialect has to decide the same thing, or "write it in whichever you like" is a
  # lie. This is also the only place that proves a transpiler's emitted prelude survives
  # the sandbox: MoonScript's class emit needed setmetatable and rawget added to the
  # whitelist, and each new dialect can want its own.
  describe "the dialects agreeing" do
    PAYLOADS = {
      "processors/shouting" => { "text" => "WHY IS NOBODY ANSWERING ME", "author" => "ada" },
      "processors/newcomer_links" => { "text" => "https://buy-now.example", "author" => "fresh" },
      "processors/company_of_heroes" => { "text" => "that is shit", "author" => "ada" },
      "processors/softener" => { "text" => "shut up and read the pins", "author" => "ada" },
      "processors/spam_score" => { "text" => "airdrop! dm me https://t.me/x", "author" => "fresh" },
      # Reads its own data file, so every dialect has to reach the same list
      # through the same call and reject on the same phrase.
      "processors/blocklist" => { "text" => "free mint tonight, dm me", "author" => "fresh" },
      # Carries a room key because the example names the room in what it
      # raises, and the loud branch is the one worth comparing: the second
      # argument is the new syntax, so it is the one a dialect can get wrong.
      "processors/slur_alert" => { "text" => "you absolute faggot", "author" => "ada",
                                   "room_key" => "general" },
      "commands/calculate" => { "text" => "/calculate (5*(4+12))/6", "author" => "ada",
                                "command" => "calculate", "args" => "(5*(4+12))/6" }
    }.freeze

    let(:compiler) { Rubotty::Scripting::Compiler.new }
    # blocklist is the one example here that reads a data file, and comparing
    # dialects on "everybody allowed it because nobody had a list" would prove
    # nothing.
    let(:yaml_data) { example_data("processors/blocklist") }

    def verdict_for(body, payload)
      Rubotty::Scripting::Verdict.from_script(
        pool.run(source: body, arg: payload, registry: build_registry, timeout: 5)
      )
    end

    # Transpilers are not all installed everywhere, so each dialect's block runs
    # only where its compiler exists. Lua is the reference and needs no block.
    Rubotty::Scripting::Dialects::ALL.reject(&:native?).each do |dialect|
      context "in #{dialect.label}", if: Rubotty::Scripting::Dialects.installed?(dialect.binary) do
        PAYLOADS.each do |id, payload|
          it "#{id} decides what the Lua does" do
            example = Rubotty::Scripting::Examples.find(id)
            written = example.source(dialect.name)
            skip "#{id} has no #{dialect.name} source yet" if written == example.source("lua")

            expected = verdict_for(example.source("lua"), payload)
            actual = verdict_for(compiler.compile(written, language: dialect.name), payload)

            expect(actual.action).to eq(expected.action)
            expect(actual.text).to eq(expected.text)
          end
        end
      end
    end
  end

  # The safety property behind every one of the above: a script that breaks must
  # not take the room's traffic with it.
  describe "when a script is broken" do
    it "lets the message through rather than swallowing it" do
      rule = Rubotty::Scripting::Rule.new(
        name: "broken", kind: :processor, source: 'error("typo")',
        trigger: Rubotty::Scripting::Triggers.build("always")
      )
      set = Rubotty::Scripting::RuleSet.new(rules: [rule], pool: pool, registry: registry,
                                            logger: Rubotty::Log.null)

      expect(set.screen(event("ordinary message"))).to be_allow
    end

    it "lets the message through when the script never returns a verdict" do
      rule = Rubotty::Scripting::Rule.new(
        name: "silent", kind: :processor, source: "return nil",
        trigger: Rubotty::Scripting::Triggers.build("always")
      )
      set = Rubotty::Scripting::RuleSet.new(rules: [rule], pool: pool, registry: registry,
                                            logger: Rubotty::Log.null)

      expect(set.screen(event("ordinary message"))).to be_allow
    end
  end

  # #screen's own comment promises a rewrite reaches the next rule, matching
  # Features::Scripts#decide, the live pipeline it exists to validate against.
  describe "when a rule rewrites the message" do
    it "hands the rewritten text to the next rule in the chain" do
      first = Rubotty::Scripting::Rule.new(
        name: "rewriter", kind: :processor,
        source: 'return { action = "rewrite", text = "seen it" }',
        trigger: Rubotty::Scripting::Triggers.build("always")
      )
      second = Rubotty::Scripting::Rule.new(
        name: "checks-rewrite", kind: :processor,
        source: 'if rubotty.text() == "seen it" then return { action = "reject", reason = "chained" } end',
        trigger: Rubotty::Scripting::Triggers.build("always")
      )
      set = Rubotty::Scripting::RuleSet.new(rules: [first, second], pool: pool, registry: registry,
                                            logger: Rubotty::Log.null)

      verdict = set.screen(event("original message"))

      expect(verdict.reject?).to be(true)
      expect(verdict.reason).to eq("chained")
    end
  end
end
