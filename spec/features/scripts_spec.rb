# frozen_string_literal: true

require "spec_helper"
require "rubotty/scripting"

# Operator scripts running on real messages: everything else is tested in isolation, so this
# is the seam that proves a script marked live actually does something. What matters here is
# that a rule wakes on the right message, its answer becomes the right pipeline outcome, and
# above all that a broken one cannot take a room's traffic with it.
RSpec.describe Rubotty::Features::Scripts, :control_plane do
  before(:all) do
    skip "no Lua interpreter on PATH" if Rubotty::Scripting::Child.find_binary.nil?
  end

  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:community) { models.community.first }
  # A real Snapshot::Community sharing the DB row's id/slug, for the Context
  # the pipeline would actually build: #command_prefixes reads feature_config
  # off it, which the raw model row above does not answer.
  let(:snapshot_community) do
    Rubotty::ControlPlane::Snapshot::Community.new(
      id: community.id, slug: community.slug, name: community.name, status: community.status,
      settings: {}, topology: Rubotty::Core::Topology.new([]), channels: [],
      operators: Rubotty::Core::Moderation::Directory.new, people: Rubotty::Core::Directory.new
    )
  end
  # The same scope with a directory that says yes, since a permission check
  # reads the community's own directory and nothing beside it.
  def community_saying_yes
    Rubotty::ControlPlane::Snapshot::Community.new(
      id: community.id, slug: community.slug, name: community.name, status: community.status,
      settings: {}, topology: Rubotty::Core::Topology.new([]), channels: [],
      operators: Object.new.tap { |o| def o.resolve(*) = :operator },
      people: Rubotty::Core::Directory.new
    )
  end

  let(:pool) { Rubotty::Scripting::Pool.new(size: 1, logger: Rubotty::Log.null) }
  let(:smoke) { Rubotty::Scripting::SmokeTest.new(pool: pool, logger: Rubotty::Log.null, timeout: SMOKE_TEST_SPEC_TIMEOUT) }
  let(:scripts) do
    Rubotty::ControlPlane::Scripts.new(models: models, logger: Rubotty::Log.null, smoke_test: smoke)
  end
  let(:removed) { [] }
  let(:reposted) { [] }
  let(:removal) do
    Class.new do
      def initialize(log) = @log = log

      def remove_everywhere(message)
        @log << message.body.text
        ["deleted"]
      end

      def notice(**) = nil
    end.new(removed)
  end

  # What /debug-lua answered, as the ephemeral primitive was asked to post it.
  # Only #post is ever reached, and only by that answer.
  let(:answered) { [] }
  let(:ephemeral) do
    Class.new do
      def initialize(log) = @log = log

      def post(body:, **rest)
        @log << { text: body.text }.merge(rest)
        Object.new.tap { |group| def group.any? = false }
      end
    end.new(answered)
  end

  subject(:feature) do
    described_class.new(scripts: scripts, pool: pool, logger: Rubotty::Log.null,
                        removal: removal, poster: ->(_ctx, text) { reposted << text },
                        ephemeral: ephemeral, clock: -> { Time.utc(2026, 7, 28, 22, 0) })
  end

  after { pool.close }

  def live(name:, source:, kind: "processor", trigger_type: "always", trigger_config: {})
    row = scripts.save(community: community, name: name, kind: kind, source: source,
                       trigger_type: trigger_type, trigger_config: trigger_config)
    scripts.verify(community, row.id)
    scripts.enable(community, row.id)
  end

  def context(text, author: "ada", kind: :chat)
    room = models.room.where(community_id: community.id).first
    writer = if author.is_a?(Rubotty::Core::Author)
               author
             else
               Rubotty::Core::Author.new(display_name: author, native_id: author)
             end
    message = Rubotty::Core::Message.new(
      kind: kind, ref: Rubotty::Core::MessageRef.new("tg-general", "m1"),
      origin: endpoint("tg-general"),
      author: writer,
      body: Rubotty::Core::RichText.plain(text)
    )
    Rubotty::Features::Context.new(message: message, community: snapshot_community, channel: room)
  end

  # Just the two readers #room_key looks at, so a channel shape can be varied
  # without standing up a message and a control plane behind it.
  def double_context(channel:, community:)
    Struct.new(:channel, :community).new(channel, community)
  end

  # The per row cache holds two maps: the rule, keyed by script id, and the
  # database row behind it, keyed by the rule's object_id. Only the first was
  # ever pruned, so every edit left the old row object in the second forever.
  describe "the rule cache, over many edits" do
    def cached_rows(feature)
      entry = feature.instance_variable_get(:@cache).values.first
      entry ? entry[:rows].size : 0
    end

    # Stated as an invariant rather than as a count, because the key is an
    # object_id and Ruby hands those out again after a collection, so a count
    # can come out right while the map is still holding what it should not.
    it "holds a row only for a rule it is still holding" do
      row = live(name: "guard", source: 'return { action = "allow" }')
      feature.call(context("hello"))

      10.times do |n|
        scripts.save(community: community, id: row.id, name: "guard", kind: "processor",
                     source: "-- pass #{n}\nreturn { action = \"allow\" }", trigger_type: "always")
        scripts.verify(community, row.id)
        scripts.enable(community, row.id)
        feature.call(context("hello"))
      end

      entry = feature.instance_variable_get(:@cache).values.first
      alive = entry[:rules].each_value.map { |held| held[:rule].object_id }

      expect(entry[:rows].keys - alive).to be_empty
      expect(cached_rows(feature)).to eq(entry[:rules].size)
    end

    it "keeps nothing for a script that was switched off" do
      row = live(name: "guard", source: 'return { action = "allow" }')
      feature.call(context("hello"))
      scripts.disable(community, row.id)
      feature.call(context("hello"))

      expect(cached_rows(feature)).to be_zero
    end
  end

  # A woken invocation: the clock's recurring wake and an endpoint's callback.
  # Neither has a message behind it, and both go out through a room key rather
  # than through a channel, which is the half that had nothing exercising it.
  describe "waking a script with no message behind it" do
    let(:calls) { [] }

    subject(:feature) do
      described_class.new(scripts: scripts, pool: pool, logger: Rubotty::Log.null,
                          removal: removal, poster: ->(_ctx, text) { reposted << text },
                          room_poster: ->(_community, key, text) { reposted << [key, text] },
                          endpoint_runner: ->(_community, key, request) { calls << [key, request] },
                          registry_for: ->(_context, _row) { nil },
                          clock: -> { Time.utc(2026, 7, 28, 22, 0) })
    end

    def row_for(source, kind: "processor", trigger_type: "recurring", config: { "every" => "day" })
      scripts.save(community: community, name: "digest", kind: kind, source: source,
                   trigger_type: trigger_type, trigger_config: config)
    end

    it "speaks into the room it was woken for, since a wake names no channel" do
      feature.wake(community: community, row: row_for('return { reply = "the digest" }'),
                   room_key: "general", kind: Rubotty::Scripting::Context::SCHEDULED)

      expect(reposted).to eq([["general", "the digest"]])
    end

    it "says nothing when the script had nothing to say" do
      feature.wake(community: community, row: row_for("return nil"),
                   room_key: "general", kind: Rubotty::Scripting::Context::SCHEDULED)

      expect(reposted).to be_empty
    end

    it "tells the script which kind of wake this is" do
      feature.wake(community: community, row: row_for("return { reply = rubotty.kind() }"),
                   room_key: "general", kind: Rubotty::Scripting::Context::SCHEDULED)

      expect(reposted.first.last).to eq("scheduled_function")
    end

    it "hands a callback the data and the response it was woken with" do
      source = 'return { reply = rubotty.invocation_data().town .. " " .. tostring(rubotty.response().status) }'
      feature.wake(community: community, row: row_for(source, kind: "callback"),
                   room_key: "general", kind: Rubotty::Scripting::Context::HTTP_CALLBACK,
                   data: { "town" => "Lisbon" }, response: { "status" => 200 })

      expect(reposted.first.last).to eq("Lisbon 200")
    end

    it "carries the room key into the wake, so a reply can find its way back" do
      feature.wake(community: community, row: row_for("return { reply = rubotty.room_key() }"),
                   room_key: "general", kind: Rubotty::Scripting::Context::SCHEDULED)

      expect(reposted.first.last).to eq("general")
    end

    # A woken script may ask for an endpoint call too, and nothing drained
    # that, so a chain stopped dead at its first hop without saying so.
    describe "the calls a woken script asks for" do
      # What the router's own async_http handler does: it records rather than
      # calls, so the reply is already posted when the request goes out.
      def booking_registry
        lambda do |woken, _row|
          Rubotty::Scripting::HostFunctions.registry(
            handlers: { "async_http" => lambda { |spec|
              woken.script_requests << { "endpoint" => spec["endpoint"], "generation" => 1 }
              true
            } }
          )
        end
      end

      subject(:feature) do
        described_class.new(scripts: scripts, pool: pool, logger: Rubotty::Log.null,
                            removal: removal, poster: ->(_ctx, text) { reposted << text },
                            room_poster: ->(_community, key, text) { reposted << [key, text] },
                            endpoint_runner: ->(_community, key, request) { calls << [key, request] },
                            registry_for: booking_registry,
                            clock: -> { Time.utc(2026, 7, 28, 22, 0) })
      end

      it "runs them once the script has finished, rather than dropping them" do
        feature.wake(community: community, room_key: "general",
                     row: row_for('rubotty.async_http({ endpoint = "weather" }); return nil'),
                     kind: Rubotty::Scripting::Context::SCHEDULED)

        expect(calls.map(&:last).map { |request| request["endpoint"] }).to eq(["weather"])
      end

      it "runs them for the room the wake named" do
        feature.wake(community: community, room_key: "general",
                     row: row_for('rubotty.async_http({ endpoint = "weather" }); return nil'),
                     kind: Rubotty::Scripting::Context::SCHEDULED)

        expect(calls.first.first).to eq("general")
      end

      it "posts the reply as well as making the call" do
        feature.wake(community: community, room_key: "general",
                     row: row_for('rubotty.async_http({ endpoint = "weather" }); return { reply = "asked" }'),
                     kind: Rubotty::Scripting::Context::SCHEDULED)

        expect(reposted.first.last).to eq("asked")
        expect(calls.length).to eq(1)
      end

      it "asks for nothing when the script asked for nothing" do
        feature.wake(community: community, row: row_for('return { reply = "quiet" }'),
                     room_key: "general", kind: Rubotty::Scripting::Context::SCHEDULED)

        expect(calls).to be_empty
      end
    end

    it "never lets a failing wake escape into whatever asked for it" do
      expect do
        feature.wake(community: community, row: row_for("error('nope')"),
                     room_key: "general", kind: Rubotty::Scripting::Context::SCHEDULED)
      end.not_to raise_error
    end
  end

  # Tracing (/debug-lua). The point of the command is following an invocation
  # through the pipeline, so what matters is that it shows all three stages and
  # that a member cannot turn it on.
  describe "script tracing" do
    let(:operators) do
      Rubotty::Core::Moderation::Directory.new.tap do |d|
        d.add(adapter: "telegram", native_id: "boss", role: Rubotty::Core::Moderation::Role.new(name: "operator"))
      rescue StandardError
        nil
      end
    end

    def command(text, author: "ada", operator: false)
      base = context(text, author: author)
      scope = operator ? community_saying_yes : base.community
      Rubotty::Features::Context.new(message: base.message, community: scope, channel: base.channel)
    end

    # Simplest possible directory that says yes, since what is under test is the
    # feature's own gate rather than the directory.
    def always_operator = Object.new.tap { |o| def o.resolve(*) = :operator }

    # The answer is a command acknowledgement, so it goes back to whoever typed
    # it rather than out to every platform the room bridges.
    it "refuses a member trying to turn it on" do
      outcome = feature.call(command("/debug-lua on"))

      expect(outcome.status).to eq(:halt)
      expect(answered.last[:text]).to include("Only an operator")
      expect(reposted).to be_empty
    end

    it "confirms to an operator, and says what it exposes" do
      outcome = feature.call(command("/debug-lua on", operator: true))

      expect(outcome.status).to eq(:halt)
      expect(answered.last[:text]).to include("tracing on").and include("source")
      expect(reposted).to be_empty
    end

    it "takes the invocation away with the answer, and gives the answer a horizon" do
      feature.call(command("/debug-lua on", operator: true))

      expect(answered.last[:delete_after]).to eq(Rubotty::Core::CommandAck::DEFAULT_TTL_SECONDS)
      expect(answered.last[:also_delete].map(&:native_id)).to eq(["m1"])
    end

    it "swallows the command rather than relaying it as chat" do
      expect(feature.call(command("/debug-lua off", operator: true)).status).to eq(:halt)
    end

    it "leaves an ordinary message alone" do
      expect(feature.call(context("just talking")).status).to eq(:continue)
    end

    it "posts the payload, the source and the answer once it is on" do
      live(name: "greet", source: 'return { action = "allow" }')
      feature.call(command("/debug-lua on", operator: true))
      reposted.clear

      feature.call(context("hello"))

      trace = reposted.join("\n")
      expect(trace).to include("script trace: greet")
      expect(trace).to include("payload:").and include("source:").and include("returned:")
      expect(trace).to include("hello")
    end

    # A rule that breaks is exactly when somebody is watching, so the error goes
    # to the room rather than only to the editor.
    it "posts the error when a script raises" do
      # Breaks only on a word the smoke probes never send, so it is enableable
      # and still fails for real once a member types it.
      live(name: "broken", source: <<~LUA)
        if string.find(rubotty.text(), "boom", 1, true) then error("typo") end
        return { action = "allow" }
      LUA
      feature.call(command("/debug-lua on", operator: true))
      reposted.clear

      feature.call(context("boom"))

      expect(reposted.join("\n")).to include("(failed)").and include("raised:").and include("typo")
    end

    it "says nothing extra while it is off" do
      live(name: "greet", source: 'return { action = "allow" }')

      feature.call(context("hello"))

      expect(reposted).to be_empty
    end

    # The dashboard's config-string path hands over whatever an operator typed,
    # case and whitespace included, so debug has to read it the same way every
    # other feature's truthy config does.
    it "turns on for a case-varied debug config, not just the literal lowercase word" do
      live(name: "greet", source: 'return { action = "allow" }')
      base = context("hello")
      traced = Rubotty::Features::Context.new(message: base.message, community: base.community,
                                              channel: base.channel, config: { debug: " TRUE " })

      feature.call(traced)

      expect(reposted.join("\n")).to include("script trace: greet")
    end
  end

  # Every other filter exempts operators by default, and a script that rejects
  # or rewrites was hitting moderators with no way to switch that off.
  describe "operators" do
    def as_operator(text)
      base = context(text)
      Rubotty::Features::Context.new(message: base.message, community: community_saying_yes,
                                     channel: base.channel, config: base.config)
    end

    def with_config(text, config)
      base = as_operator(text)
      Rubotty::Features::Context.new(message: base.message, community: base.community,
                                     channel: base.channel, config: config)
    end

    it "leaves an operator's own message alone by default" do
      live(name: "reject-all", source: 'return { action = "reject", reason = "no" }')

      expect(feature.call(as_operator("anything")).status).to eq(:continue)
      expect(removed).to be_empty
    end

    it "subjects them to their own rules once the exemption is switched off" do
      live(name: "reject-all", source: 'return { action = "reject", reason = "no" }')

      feature.call(with_config("anything", { exempt_operators: false }))

      expect(removed).not_to be_empty
    end

    # A dashboard-typed value like "TRUE" has to read as truthy here the same
    # way it would for exempt_operators on every other feature.
    it "reads a case-varied exempt_operators config the same as a real boolean" do
      live(name: "reject-all", source: 'return { action = "reject", reason = "no" }')

      feature.call(with_config("anything", { exempt_operators: "TRUE" }))

      expect(removed).to be_empty
    end

    it "still screens an ordinary member" do
      live(name: "reject-all", source: 'return { action = "reject", reason = "no" }')

      expect(feature.call(context("anything")).status).to eq(:halt)
    end

    # The check used to return before the rules were looked up, so on a default install an
    # operator's own message never reached their own script: they typed the command they
    # had just written and the bot said nothing, with no error anywhere.
    describe "driving your own script, on a default install" do
      it "answers an operator's command" do
        live(name: "greet", kind: "command", source: 'return "hello yourself"',
             trigger_type: "command", trigger_config: { "name" => "greet" })

        expect(feature.call(as_operator("/greet")).value).to eq(["hello yourself"])
      end

      it "answers an operator's ordinary message" do
        live(name: "chatty", source: 'return { action = "allow", reply = "heard you" }')

        expect(feature.call(as_operator("anything")).value).to eq(["heard you"])
      end

      # The half of the exemption that was worth keeping: a moderator does not
      # get their own word filter applied to them.
      it "still refuses to remove or rewrite what they said" do
        live(name: "rewrite-all", source: 'return { action = "rewrite", text = "changed" }')

        expect(feature.call(as_operator("anything")).status).to eq(:continue)
        expect(removed).to be_empty
      end

      # A rejected message that also had something to say still says it. An
      # exempt operator is spared the action and keeps the words.
      it "keeps the reply from a verdict it spared" do
        live(name: "reject-loudly",
             source: 'return { action = "reject", reason = "no", reply = "not that one" }')

        expect(feature.call(as_operator("anything")).value).to eq(["not that one"])
        expect(removed).to be_empty
      end
    end
  end

  # Core::Message::KINDS has carried :edit all along and Scripts observed only :chat, so a
  # rule that scored a guess of 1200 went on scoring 1200 while the room could see it had
  # been edited to 9999.
  describe "message edits" do
    it "is offered edits by the pipeline at all" do
      expect(described_class.observes).to include(:edit)
    end

    it "leaves a script that did not ask for them entirely alone" do
      live(name: "counter", source: 'return { action = "allow", reply = "counted" }')

      expect(feature.call(context("9999", kind: :edit)).value).to eq([])
    end

    it "wakes a script that asked" do
      live(name: "counter", source: 'return { action = "allow", reply = "counted" }',
           trigger_config: { "edits" => "true" })

      expect(feature.call(context("9999", kind: :edit)).value).to eq(["counted"])
    end

    # An edit is its own kind rather than another message, because a script that
    # asked for them nearly always wants to treat them differently.
    it "says so in rubotty.kind()" do
      live(name: "peek", kind: "command", source: "return rubotty.kind()",
           trigger_type: "always", trigger_config: { "edits" => "true" })

      expect(feature.call(context("9999", kind: :edit)).value).to eq(["message_edit"])
    end
  end

  # One script, two conditions, one set of memos. Everything that had to hear a command AND
  # free text used to be two scripts, and memos are scoped per script, so the two could
  # share nothing they knew.
  describe "a script carrying several conditions" do
    def declared_both
      live(name: "game", kind: "command", source: "return rubotty.trigger()",
           trigger_type: "command",
           trigger_config: { "name" => "deal", "triggers" => ["always"] })
    end

    it "wakes on the command" do
      declared_both

      expect(feature.call(context("/deal")).value).to eq(["command"])
    end

    it "wakes on ordinary talk too, and says which condition did it" do
      declared_both

      expect(feature.call(context("just talking")).value).to eq(["always"])
    end

    # Not once per matching condition: two invocations that cannot see each
    # other's memos, for what the script reads as one event.
    it "runs once for a message both conditions match" do
      declared_both

      expect(feature.call(context("/deal")).value.length).to eq(1)
    end
  end

  # rubotty.kind() is what a script branches on to tell an ordinary message from a
  # command, a timer or an answer coming back. It is always present, because
  # inferring "this is a message" from the field being absent is the sort of
  # thing that works until a new kind is added.
  describe "what kind of invocation this is" do
    def kind_seen_by(source, text, rule_kind: :processor, trigger: "always", config: {})
      seen = nil
      live(name: "peek", source: source, kind: rule_kind.to_s,
           trigger_type: trigger, trigger_config: config)
      allow(pool).to receive(:run).and_wrap_original do |original, **args|
        seen = args[:arg]["kind"]
        original.call(**args)
      end
      feature.call(context(text))
      seen
    end

    it "names an ordinary message" do
      expect(kind_seen_by('return { action = "allow" }', "hello")).to eq("message")
    end

    it "names a command separately from a message" do
      seen = kind_seen_by('return "hi"', "/greet", rule_kind: :command,
                          trigger: "command", config: { "name" => "greet" })

      expect(seen).to eq("command_invocation")
    end

    it "offers a name for every kind it can produce" do
      expect(Rubotty::Scripting::Context::KINDS)
        .to contain_exactly("message", "message_edit", "command_invocation",
                            "scheduled_function", "http_callback")
    end
  end

  # A windowed trigger keeps its ring on the rule object, so throwing that object away
  # resets the count. The cache used to be signed with every active row at once, so any
  # write in the community, even just recording one script's failure, quietly reset every
  # other rule's window.
  describe "trigger state across an unrelated write" do
    def flood_rule
      live(name: "flood", kind: "processor",
           trigger_type: "recent_contains",
           trigger_config: { "words" => ["http"], "window" => 10, "count" => 3 },
           source: 'return { action = "reject", reason = "too many" }')
    end

    it "counts to three across messages" do
      flood_rule

      expect(feature.call(context("http one")).status).to eq(:continue)
      expect(feature.call(context("http two")).status).to eq(:continue)
      expect(feature.call(context("http three")).status).to eq(:halt)
    end

    it "keeps counting when another script in the community is written to" do
      flood_rule
      other = scripts.save(community: community, name: "unrelated", kind: "processor",
                           source: 'return { action = "allow" }', trigger_type: "always")

      feature.call(context("http one"))
      feature.call(context("http two"))
      # Exactly what recording a failure does, and what used to wipe the ring.
      scripts.record_error(other, "something went wrong")

      expect(feature.call(context("http three")).status).to eq(:halt)
    end

    it "still picks up an edit to the rule itself" do
      row = flood_rule
      feature.call(context("http one"))

      scripts.save(community: community, id: row.id, name: "flood", kind: "processor",
                   source: 'return { action = "allow" }', trigger_type: "recent_contains",
                   trigger_config: { "words" => ["http"], "window" => 10, "count" => 3 })

      # Edited, so it is off until verified again, and its ring is gone with it.
      expect(feature.call(context("http two")).status).to eq(:continue)
    end
  end

  describe "when nothing is live" do
    it "passes the message through untouched" do
      expect(feature.call(context("hello")).status).to eq(:continue)
      expect(removed).to be_empty
    end
  end

  describe "a processor that allows" do
    it "leaves the message alone" do
      live(name: "watcher", source: 'return { action = "allow" }')

      expect(feature.call(context("hello")).status).to eq(:continue)
      expect(removed).to be_empty
    end
  end

  describe "a processor that rejects" do
    it "removes the message everywhere and stops the chain" do
      live(name: "no links", source: <<~LUA, trigger_type: "contains", trigger_config: { "words" => ["http"] })
        return { action = "reject", reason = "no links here" }
      LUA

      outcome = feature.call(context("look http://spam.example"))

      expect(outcome.status).to eq(:halt)
      expect(removed).to eq(["look http://spam.example"])
    end

    it "leaves a message its trigger did not match" do
      live(name: "no links", source: <<~LUA, trigger_type: "contains", trigger_config: { "words" => ["http"] })
        return { action = "reject", reason = "no links here" }
      LUA

      expect(feature.call(context("perfectly ordinary")).status).to eq(:continue)
      expect(removed).to be_empty
    end
  end

  describe "a processor that rewrites" do
    # Delete then repost, because no platform lets a bot edit somebody else's
    # message and rewriting only the relayed copies would leave the origin
    # showing the original text.
    it "removes the original and posts the replacement" do
      live(name: "softener", source: <<~LUA)
        return { action = "rewrite", text = string.gsub(rubotty.text(), "shut up", "hear them out") }
      LUA

      outcome = feature.call(context("shut up and read"))

      expect(outcome.status).to eq(:halt)
      expect(removed).to eq(["shut up and read"])
      expect(reposted).to eq(["hear them out and read"])
    end

    # A room seeing both the original and the replacement is worse than one
    # seeing the original alone, so a failed delete abandons the rewrite.
    it "abandons the rewrite when the original cannot be removed" do
      stubborn = Class.new do
        def remove_everywhere(_message) = []

        def notice(**) = nil
      end.new
      feature = described_class.new(scripts: scripts, pool: pool, logger: Rubotty::Log.null,
                                    removal: stubborn, poster: ->(_ctx, text) { reposted << text })
      live(name: "softener", source: 'return { action = "rewrite", text = "replaced" }')

      expect(feature.call(context("original")).status).to eq(:continue)
      expect(reposted).to be_empty
    end
  end

  # The property that matters most: an operator's typo must not stop a room relaying, so
  # every one of these carries on. Each script here passes the smoke test and then fails on
  # one particular input, which is exactly the gap the gate cannot close: probes catch
  # "always broken" and miss "broken on the message that matters".
  describe "when a script misbehaves" do
    it "carries on when it raises" do
      live(name: "broken", source: <<~LUA)
        if rubotty.text() == "boom" then error("typo") end
        return { action = "allow" }
      LUA

      expect(feature.call(context("boom")).status).to eq(:continue)
      expect(removed).to be_empty
    end

    it "carries on when it never finishes" do
      live(name: "slow", source: <<~LUA)
        if rubotty.text() == "hang" then while true do end end
        return { action = "allow" }
      LUA

      expect(feature.call(context("hang")).status).to eq(:continue)
    end

    it "records the failure on the row so the editor can show it" do
      live(name: "broken", source: <<~LUA)
        if rubotty.text() == "boom" then error("typo") end
        return { action = "allow" }
      LUA

      feature.call(context("boom"))

      row = scripts.find_by_name(community, "broken")
      expect(row.last_error.to_s).to include("typo")
      expect(row.consecutive_failures).to be >= 1
    end
  end

  describe "which scripts run at all" do
    it "ignores one that is saved but never turned on" do
      scripts.save(community: community, name: "draft", kind: "processor",
                   source: 'return { action = "reject" }', trigger_type: "always")

      expect(feature.call(context("hello")).status).to eq(:continue)
      expect(removed).to be_empty
    end

    it "ignores one that was edited after being verified" do
      live(name: "watcher", source: 'return { action = "reject", reason = "no" }')
      scripts.save(community: community, name: "watcher", kind: "processor",
                   source: 'return { action = "reject", reason = "edited" }', trigger_type: "always")

      expect(feature.call(context("hello")).status).to eq(:continue)
    end
  end

  describe "a command" do
    it "answers with the reply, without stopping the chain" do
      live(name: "rules", kind: "command", trigger_type: "command",
           trigger_config: { "name" => "rules" }, source: 'return "Be kind."')

      outcome = feature.call(context("/rules"))

      expect(outcome.status).to eq(:continue)
      expect(outcome.value).to eq(["Be kind."])
    end
  end

  # The wiring is as easy to get half right as the feature: a nil registry means
  # rubotty.classify is simply absent, and a nil poster means every rewrite is
  # abandoned. Both were nil the first time round, so these pin them.
  describe "the host functions a wired script actually gets" do
    let(:registry) do
      classifier = Rubotty::Scripting::Classifier.new(config: { "custom" => ["pineapple"] },
                                                      logger: Rubotty::Log.null)
      Rubotty::Scripting::HostFunctions.registry(handlers: {
        "classify" => ->(text) { classifier.classify(text) },
        "offending_spans" => ->(text) { classifier.spans(text) },
        "log" => ->(_text) { true }
      })
    end

    subject(:feature) do
      described_class.new(scripts: scripts, pool: pool, logger: Rubotty::Log.null,
                          removal: removal, poster: ->(_ctx, text) { reposted << text },
                          registry_for: ->(_ctx, _row = nil) { registry },
                          clock: -> { Time.utc(2026, 7, 28, 22, 0) })
    end

    it "can classify without ever being handed the word list" do
      live(name: "classifier", source: <<~LUA)
        return { action = "rewrite", text = rubotty.classify(rubotty.text()) }
      LUA

      feature.call(context("I hate pineapple"))

      expect(reposted).to eq(["community"])
    end

    it "can replace what the filter caught, using the spans it is given" do
      live(name: "swapper", source: <<~LUA)
        local out, last = "", 1
        for _, s in ipairs(rubotty.offending_spans(rubotty.text())) do
          out = out .. string.sub(rubotty.text(), last, s.from) .. "pudding"
          last = s.to + 1
        end
        if out == "" then return { action = "allow" } end
        return { action = "rewrite", text = out .. string.sub(rubotty.text(), last) }
      LUA

      feature.call(context("I hate pineapple on pizza"))

      expect(reposted).to eq(["I hate pudding on pizza"])
    end
  end

  # Saying something back used to mean calling notify as a side effect and then returning a
  # verdict separately, so the simplest rule anybody wants was the most awkward shape in the
  # feature.
  describe "a processor that answers" do
    it "posts a reply returned alongside allow, the way a command's answer is" do
      live(name: "greeter", source: <<~LUA)
        if string.find(rubotty.text(), "hello") then
          return { action = "allow", reply = "hello yourself" }
        end
        return { action = "allow" }
      LUA

      outcome = feature.call(context("well hello there"))

      expect(outcome.value).to eq(["hello yourself"])
    end

    it "says nothing when the rule returns no reply" do
      live(name: "quiet", source: 'return { action = "allow" }')

      expect(feature.call(context("anything")).value).to eq([])
    end

    it "keeps the reply when the same answer also rewrites" do
      live(name: "both", source: <<~LUA)
        return { action = "rewrite", text = "tidied", reply = "cleaned that up" }
      LUA

      outcome = feature.call(context("messy"))

      expect(outcome.value).to eq(["cleaned that up"])
      expect(reposted).to eq(["tidied"])
    end

    # Rejecting and saying why in one answer is the case notify still exists
    # for, so a script using the new shape to do it must not lose the words.
    it "keeps the reply when the answer rejects, and still halts" do
      live(name: "strict", source: <<~LUA)
        return { action = "reject", reason = "no", reply = "that is not allowed here" }
      LUA

      outcome = feature.call(context("bad"))

      expect(outcome.value).to eq(["that is not allowed here"])
      expect(outcome).to be_halt
    end
  end

  # The callback kind: never run by traffic, only ever woken by another script
  # through schedule or as an async_http answer.
  describe "a callback" do
    let(:room_poster) { [] }

    subject(:feature) do
      described_class.new(scripts: scripts, pool: pool, logger: Rubotty::Log.null,
                          removal: removal, poster: ->(_ctx, text) { reposted << text },
                          room_poster: ->(_community, room, text) { room_poster << [room, text] },
                          clock: -> { Time.utc(2026, 7, 28, 22, 0) })
    end

    def callback(name:, source:)
      row = scripts.save(community: community, name: name, kind: "callback", language: "lua",
                         source: source, trigger_type: "always")
      scripts.verify(community, row.id)
      scripts.enable(community, row.id)
    end

    it "never runs on a message, however the room is talking" do
      callback(name: "handler", source: 'return { action = "reject", reason = "should not happen" }')

      expect(feature.call(context("anything")).status).to eq(:continue)
      expect(removed).to be_empty
    end

    it "runs when something wakes it, and its answer reaches the room" do
      callback(name: "handler", source: <<~LUA)
        return { action = "allow", reply = "woken as " .. tostring(rubotty.kind()) }
      LUA
      row = scripts.find_by_name(community, "handler")

      feature.wake(community: community, row: row, room_key: "general",
                   kind: Rubotty::Scripting::Context::SCHEDULED)

      expect(room_poster.last).to eq(["general", "woken as scheduled_function"])
    end

    # Guarded, because the save gate probes a wake with no data at all, which
    # is the shape a callback really can arrive in.
    it "is handed the data whoever woke it passed" do
      callback(name: "handler", source: <<~LUA)
        local who = rubotty.invocation_data() and rubotty.invocation_data().who or "nobody"
        return { action = "allow", reply = "for " .. tostring(who) }
      LUA
      row = scripts.find_by_name(community, "handler")

      feature.wake(community: community, row: row, room_key: "general",
                   kind: Rubotty::Scripting::Context::SCHEDULED, data: { "who" => "ada" })

      expect(room_poster.last.last).to eq("for ada")
    end
  end

  describe "the circuit breaker" do
    it "clears the failure count after a run that worked" do
      live(name: "flaky", source: <<~LUA)
        if string.find(rubotty.text(), "boom", 1, true) then error("typo") end
        return { action = "allow" }
      LUA
      row = scripts.find_by_name(community, "flaky")

      feature.call(context("boom"))
      expect(row.refresh.consecutive_failures).to eq(1)

      feature.call(context("perfectly fine"))
      expect(row.refresh.consecutive_failures).to eq(0)
    end

    # Breaks only on a word the smoke probes never send, so it is enableable
    # and then fails for real, the same trick the tracing spec uses.
    it "still switches one off once the failures really are consecutive" do
      live(name: "broken", source: <<~LUA)
        if string.find(rubotty.text(), "boom", 1, true) then error("always") end
        return { action = "allow" }
      LUA
      row = scripts.find_by_name(community, "broken")

      6.times { feature.call(context("boom")) }

      expect(row.refresh.disabled_at).not_to be_nil
    end
  end

  describe "what a script is handed" do
    it "carries the clock and the room, and nothing bulky" do
      live(name: "peek", source: <<~LUA)
        return { action = "rewrite", text = rubotty.now().hour .. "|" .. rubotty.room_key() .. "|" ..
                 tostring(rubotty.__internal.events) .. "|" .. tostring(rubotty.author_is_operator()) }
      LUA

      feature.call(context("anything"))

      expect(reposted.first).to eq("22|general|nil|false")
    end

    # What actually reaches a live bot is a Snapshot::Channel, which has no room_key of its
    # own: it carries route_key, the platform side id, which differs per channel inside one
    # room. Asking only the channel meant every payload, trace and cache key got an object
    # address that said nothing and changed on restart.
    it "places a channel that cannot name its own room through the community" do
      channel = Struct.new(:endpoint_key).new("tg-general")
      placed = Class.new do
        def room_key_of(chan) = chan.endpoint_key == "tg-general" ? "general" : nil
      end.new

      key = feature.send(:room_key, double_context(channel: channel, community: placed))

      expect(key).to eq("general")
    end

    it "says nothing rather than an object address when no room can be found" do
      channel = Struct.new(:endpoint_key).new("orphan")
      placed = Class.new do
        def room_key_of(_chan) = nil
      end.new

      key = feature.send(:room_key, double_context(channel: channel, community: placed))

      expect(key).to eq("")
    end

    # Telegram leaves display_name nil for anybody who has set only a first
    # name or a username, so the author reached every script as an empty
    # string. any_name is the same fallback the cross platform sender label
    # uses, so a script sees the person the room sees.
    it "names an author who has no display name" do
      live(name: "who", source: <<~LUA)
        return { action = "rewrite", text = rubotty.author() }
      LUA

      feature.call(context("anything", author: Rubotty::Core::Author.new(username: "sample_owner")))

      expect(reposted.first).to eq("sample_owner")
    end
  end

  # Core::Message was carrying all three of these and the payload was dropping them, so a
  # rule could see that somebody had posted and not that they had posted four images in
  # answer to the pinned rules.
  describe "what the message was already carrying" do
    let(:photo) do
      Rubotty::Core::Attachment.new(kind: :photo, filename: "cat.png", size: 2048,
                                    mime_type: "image/png", native_ref: "tg-file-1",
                                    url: "https://example.test/cat.png")
    end

    def context_with(**changes)
      base = context("anything")
      Rubotty::Features::Context.new(message: base.message.with(**changes),
                                     community: base.community, channel: base.channel)
    end

    it "hands over the files that came with the message" do
      live(name: "files", source: <<~LUA)
        local one = rubotty.attachments()[1]
        if not one then return { action = "allow" } end
        return { action = "rewrite",
                 text = #rubotty.attachments() .. "|" .. one.kind .. "|" .. one.filename .. "|" ..
                        one.bytes .. "|" .. one.content_type .. "|" .. one.ref }
      LUA

      feature.call(context_with(attachments: [photo]))

      expect(reposted.first).to eq("1|photo|cat.png|2048|image/png|tg-file-1")
    end

    # A file posted to a room was posted to that room, rather than to whoever a
    # rule might hand a link to.
    it "hands over no way to fetch the file" do
      live(name: "leak", source: <<~LUA)
        if not rubotty.attachments()[1] then return { action = "allow" } end
        local fields = {}
        for key in pairs(rubotty.attachments()[1]) do fields[#fields + 1] = key end
        table.sort(fields)
        return { action = "rewrite", text = table.concat(fields, ",") }
      LUA

      feature.call(context_with(attachments: [photo]))

      expect(reposted.first).to eq("bytes,content_type,filename,kind,ref")
    end

    # Empty rather than missing, so a rule asking "did they post a file" does
    # not have to guard for nil first.
    it "hands over an empty list when nothing came with it" do
      live(name: "none", source: <<~LUA)
        return { action = "rewrite", text = "count " .. #rubotty.attachments() }
      LUA

      feature.call(context("anything"))

      expect(reposted.first).to eq("count 0")
    end

    it "hands over what the message was answering" do
      preview = Rubotty::Core::ReplyPreview.new(
        author: Rubotty::Core::Author.new(username: "ada"),
        body: Rubotty::Core::RichText.plain("the original")
      )

      live(name: "answers", source: <<~LUA)
        if not rubotty.reply_to() then return { action = "allow" } end
        return { action = "rewrite", text = rubotty.reply_to().author .. ": " .. rubotty.reply_to().text }
      LUA

      feature.call(context_with(reply_to: Rubotty::Core::MessageRef.new("tg-general", "m0"),
                                reply_preview: preview))

      expect(reposted.first).to eq("ada: the original")
    end

    # Absent rather than empty, because "is this a reply" is exactly the
    # question, and a table of empty strings answers it wrongly.
    it "leaves the reply out entirely when the message answers nothing" do
      live(name: "unanswered", source: <<~LUA)
        return { action = "rewrite", text = tostring(rubotty.reply_to()) }
      LUA

      feature.call(context("anything"))

      expect(reposted.first).to eq("nil")
    end

    # The handle is a string so that this works at all: a memo holds strings,
    # and a memo is the only thing that survives between two invocations.
    it "hands over a handle a memo can hold and hand back" do
      live(name: "handle", source: <<~LUA)
        return { action = "rewrite", text = rubotty.handle() }
      LUA

      feature.call(context("anything"))

      expect(Rubotty::Scripting::Handle.refs(reposted.first).map(&:native_id)).to eq(["m1"])
    end
  end

  # The failure counter and the error history said whether a rule was falling
  # over. Nothing said whether it was doing anything at all.
  describe "counting what a script actually ran" do
    it "counts a run for a message the rule was handed" do
      row = live(name: "watcher", source: 'return { action = "allow" }')

      2.times { feature.call(context("hello")) }

      expect(scripts.run_totals(row)).to eq({ runs: 2, failures: 0 })
    end

    # A rejection is the rule doing its job, so it counts exactly as an allow
    # does rather than reading as a run that never happened.
    it "counts a message the rule rejected" do
      row = live(name: "no links", source: <<~LUA, trigger_type: "contains", trigger_config: { "words" => ["http"] })
        return { action = "reject", reason = "no links here" }
      LUA

      feature.call(context("look http://spam.example"))

      expect(scripts.run_totals(row)[:runs]).to eq(1)
    end

    it "counts nothing for a message the trigger never matched" do
      row = live(name: "no links", source: <<~LUA, trigger_type: "contains", trigger_config: { "words" => ["http"] })
        return { action = "reject", reason = "no links here" }
      LUA

      feature.call(context("perfectly ordinary"))

      expect(scripts.run_totals(row)).to eq({ runs: 0, failures: 0 })
    end

    it "counts a run that raised as a run and as a failure" do
      # Breaks only on a word the smoke probes never send, so it is enableable
      # and still fails for real once a member types it.
      row = live(name: "broken", source: <<~LUA)
        if string.find(rubotty.text(), "boom", 1, true) then error("typo") end
        return { action = "allow" }
      LUA

      feature.call(context("hello"))
      feature.call(context("boom"))

      expect(scripts.run_totals(row)).to eq({ runs: 2, failures: 1 })
    end

    it "counts a wake apart from traffic" do
      row = live(name: "watcher", source: 'return { action = "allow" }')

      feature.call(context("hello"))
      feature.wake(community: community, row: row, room_key: "general",
                   kind: Rubotty::Scripting::Context::SCHEDULED)

      expect(scripts.runs_for(row).map { |entry| [entry[:source], entry[:runs]] })
        .to contain_exactly(["message", 1], ["wake", 1])
    end

    # Nothing a counter does may reach the room. A store that cannot count has
    # to leave the rule's own verdict standing, rather than losing a rejection
    # on the way out through the pipeline's safety net.
    it "keeps the rule's verdict when the count cannot be taken" do
      live(name: "no links", source: <<~LUA, trigger_type: "contains", trigger_config: { "words" => ["http"] })
        return { action = "reject", reason = "no links here" }
      LUA
      allow(scripts).to receive(:record_run).and_raise(Sequel::DatabaseError, "gone")

      expect(feature.call(context("look http://spam.example")).status).to eq(:halt)
      expect(removed).to eq(["look http://spam.example"])
    end
  end
end
