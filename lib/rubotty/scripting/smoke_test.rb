# frozen_string_literal: true

module Rubotty
  module Scripting
    # The gate a script has to pass before it is allowed into the database:
    # it runs the script against a handful of deliberately awkward inputs,
    # and refuses the save if any crash or answer something a rule can't
    # mean (a table with no action, a rewrite with nothing to rewrite to).
    # At message time a bad answer silently degrades to "allow"; at save
    # time that same silence would let an operator ship a rule that looks
    # fine and does nothing, so it is reported instead. Each probe is a
    # fresh sandbox, and a script broken only on the input that matters in production can still sail through.
    class SmokeTest
      # The texts every script is run against: empty, one word, a long
      # many-worded string (length matters for a loop over words),
      # punctuation soup, and non ASCII text; the last two are malformed Lua
      # patterns (a trailing percent, an unclosed bracket) that catch
      # string.find/string.gsub used without the plain flag. Lua only
      # raises once the matcher reaches the malformed part, so these catch
      # text matching itself or close to it, not every misuse, and
      # punctuation soup alone catches neither since it happens to parse as a valid pattern.
      PROBE_TEXTS = [
        "",
        "hello",
        (["the quick brown fox jumps over the lazy dog"] * 40).join(" "),
        "%s%d[]()^$.*+-? \\\\ '\"`~!@#$%^&*()_+{}|:<>?,./;'[]\\\\",
        "ola \u{1F3E6} ção   mixed",
        "that is 100%",
        "look at array[0 and see"
      ].freeze

      # Deliberately tighter than the runtime budget. A script that needs four
      # seconds on the word "hello" will time out under real load, so leaving it
      # the full production budget here just moves the failure somewhere less
      # convenient.
      DEFAULT_TIMEOUT = 1

      Failure = Struct.new(:probe, :message, keyword_init: true) do
        def to_s = "#{probe}: #{message}"
      end

      Result = Struct.new(:failures, :host_calls, keyword_init: true) do
        def ok? = failures.empty?

        def to_s = ok? ? "no obvious errors" : failures.map(&:to_s).join("; ")
      end

      # @param pool [Pool] where probes run
      # @param logger [#warn, nil]
      # @param timeout [Numeric] per probe
      # The clock every probe sees, frozen so a rule that branches on the
      # hour gives the same answer on every run and a failure can be looked
      # at twice. This is the whole reason time is injected rather than read from os.
      PROBE_CLOCK = -> { Time.utc(2026, 1, 1, 12, 0, 0) }

      # What a probe pretends is going on in the room. Every script has been
      # probed against QUIET since the gate existed, and it is the only scene a
      # script that never asks about a session ever sees.
      QUIET = "nothing running"

      # The scene a participation script exists for: a rule that reads a
      # round branches on finding one, and both branches run in production,
      # since the first invocation of a game finds nothing and every later
      # one finds a round. A script probed under one scene alone therefore
      # either fails the gate on its own main path or passes with that path never reached.
      LIVE = "a round open"

      # The names that make a script worth probing twice.
      PARTICIPATION = %w[session open_session close_session round open_round close_round].freeze

      # The handle every probe message carries: a real message always has
      # one, so handing a probe an empty string would fail a rule that
      # reacts to the message in hand for a reason that could never happen
      # in production. Attachments and the reply are left out instead, since
      # most messages really do have neither and a rule has to cope with that.
      PROBE_HANDLE = Handle.of(Handle::Ref.new(endpoint_id: "smoke-test", native_id: "probe"))

      def initialize(pool:, logger: nil, timeout: DEFAULT_TIMEOUT, clock: PROBE_CLOCK)
        @pool = pool
        @logger = logger
        @timeout = timeout
        @context = Context.new(room_key: "smoke-test", clock: clock)
      end

      # @param trigger [Triggers::Base, Array<Triggers::Base>] shapes the probe
      #   payloads. A script may carry several conditions and each hands the
      #   script a different set of keys, so each one's payloads are probed:
      #   gating on the first alone would pass a script that breaks on the
      #   shape its second condition really produces.
      # @param yaml_data [Object, nil] this script's parsed data file, so a rule
      #   that decides from a list is probed against the list it will really
      #   have rather than against nothing
      def run(kind:, source:, trigger:, yaml_data: nil)
        failures = []
        counter = CountingRegistry.new(yaml_data: yaml_data, woken: woken_only?(kind, trigger))
        all_payloads(trigger, kind, source).each do |label, payload, text, scene|
          # One counter across every probe, so the reported call count is the
          # whole check, and the scene moves under it per probe.
          counter.scene = scene
          failure = probe(kind: kind, source: source, payload: payload, registry: counter,
                          label: label, input: text)
          failures << failure if failure
        end
        Result.new(failures: failures, host_calls: counter.count)
      end

      # Run the script once against text the operator typed, and hand back
      # what it answered: the check proves a script does not fall over, but
      # this answers what somebody actually needs while writing a rule,
      # given THIS message. Host functions are the same stubs the check
      # uses, so the answer is real but the side effects are not.
      #
      # @return [Array(Boolean, Object)] whether the trigger matched, and either
      #   the script's answer or the error it raised
      def try(kind:, source:, trigger:, text:, data: nil, yaml_data: nil)
        triggers = Array(trigger)
        # A recurring script and a callback are never woken by traffic, so
        # observe answers nil for both, and Run now could only ever say
        # "that did not match". They are run against the shape they will
        # really see instead, matching what the check itself already does.
        if triggers.empty? || triggers.all? { |one| woken_only?(kind, one) }
          return try_woken(kind: kind, source: source, data: data, yaml_data: yaml_data)
        end

        # One message per line, fed to the SAME triggers in order. A windowed
        # condition ("the third link in ten minutes") counts across messages,
        # so a harness that only showed it one could never demonstrate the
        # rule it was built for.
        event = nil
        fired = nil
        lines(text).each do |line|
          event = Triggers::Event.new(text: line, author_name: "you", handle: PROBE_HANDLE,
                                      author_is_operator: true, origin_platform: "dashboard")
          # Every condition is folded in, so a windowed one keeps its count even
          # when an earlier condition is the one that answers. The first match
          # in declared order is what gets reported, which is what the live
          # pipeline picks too.
          fired = triggers.filter_map do |one|
            payload = one.observe(event)
            payload.nil? ? nil : [one, payload]
          end.first
        end
        return [false, nil] if fired.nil? || event.nil?

        payload = @context.decorate(fired.last, message: event, trigger: fired.first.class.type_name,
                                    kind: kind.to_sym == :command ? Context::COMMAND : Context::MESSAGE)
        [true, @pool.run(source: source, arg: payload,
                         registry: preview_registry(yaml_data), timeout: @timeout)]
      rescue Scripting::Timeout
        [true, "took longer than #{@timeout}s"]
      rescue Scripting::Error => e
        [true, e.message]
      end

      private

      # Run now shows somebody what THIS message does, so it is played against a
      # room with a round open. Every preview of a game answering "nothing is
      # running here" would be the one answer nobody is asking for.
      def preview_registry(yaml_data, woken: false)
        CountingRegistry.new(yaml_data: yaml_data, woken: woken, scene: LIVE)
      end

      # Every trigger's probes are labelled by the condition they came from
      # once there is more than one, so a failure says which condition's
      # payload the script fell over on. A script never woken BY a message
      # is probed with the shape it will really see instead, since an
      # author and origin platform would pass a callback or recurring
      # script reading rubotty.author() that then fails on its first real
      # wake; a callback is probed once, everything else per condition.
      def all_payloads(trigger, kind, source = "")
        triggers = Array(trigger)
        scenes = scenes_for(source)
        return woken_payloads(kind, scenes) if kind.to_sym == :callback

        triggers.flat_map do |one|
          named = triggers.length > 1 ? "#{one.class.type_name} " : ""
          probes = woken_only?(kind, one) ? woken_payloads(kind, scenes) : payloads(one, kind, scenes)
          probes.map { |label, payload, text, scene| ["#{named}#{label}", payload, text, scene] }
        end
      end

      # Which scenes this script is worth playing against. Only a script that
      # asks about a session pays for the second pass, so every other script is
      # probed exactly as many times as it always was.
      def scenes_for(source)
        text = source.to_s
        return [QUIET, LIVE] if PARTICIPATION.any? { |name| text.include?("rubotty.#{name}") }

        [QUIET]
      end

      # Which scene a failure came from, named only when there was more than
      # one, so an ordinary script's probes keep the labels they always had.
      def note(scenes, scene) = scenes.length > 1 ? " (#{scene})" : ""

      # What was typed, as the messages it stands for. A blank box is still one
      # message, since a rule can match on emptiness.
      def lines(text)
        found = text.to_s.split("\n").map(&:strip).reject(&:empty?)
        found.empty? ? [text.to_s] : found
      end

      # One wake, with whatever the operator typed read as the data a caller
      # would have passed. Anything that is not a table reads as no data,
      # rather than refusing: the box is free text on a page about trying
      # things out.
      def try_woken(kind:, source:, data: nil, yaml_data: nil)
        wake_kind = kind.to_sym == :callback ? Context::HTTP_CALLBACK : Context::SCHEDULED
        payload = @context.decorate({ "invocation_data" => data }, kind: wake_kind)
        [true, @pool.run(source: source, arg: payload,
                         registry: preview_registry(yaml_data, woken: true),
                         timeout: @timeout)]
      rescue Scripting::Timeout
        [true, "took longer than #{@timeout}s"]
      rescue Scripting::Error => e
        [true, e.message]
      end

      # Probes are decorated exactly the way a live invocation is, or a script
      # reading rubotty.now() would fail verification and pass in production, which
      # is the worst way round for a gate to be wrong. That includes the trigger,
      # which is how a script carrying several conditions tells them apart.
      def payloads(trigger, kind = :processor, scenes = [QUIET])
        kinds = probe_kinds(trigger, kind)
        scenes.flat_map do |scene|
          PROBE_TEXTS.flat_map.with_index do |text, index|
            trigger.probe_payloads(text).flat_map.with_index do |payload, variant|
              kinds.map do |probe_kind|
                edited = probe_kind == Context::EDIT
                event = Triggers::Event.new(text: text, author_name: "smoke-test", handle: PROBE_HANDLE,
                                            author_is_operator: false, origin_platform: "smoke",
                                            edited: edited)
                label = "probe #{index + 1}#{variant.positive? ? "b" : ""}" \
                        "#{edited ? " on an edit" : ""}#{note(scenes, scene)}"
                [label,
                 @context.decorate(payload, message: event, kind: probe_kind,
                                   trigger: trigger.class.type_name), text, scene]
              end
            end
          end
        end
      end

      # Which rubotty.kind() branches this condition really reaches: a
      # command script's probes say so, the way the live pipeline does,
      # rather than falling to the MESSAGE default. A condition that
      # opted into edits reaches the EDIT branch too, whatever else it is,
      # since Features::Scripts#payload_kind answers EDIT first, before it
      # asks whether the rule is a command.
      def probe_kinds(trigger, kind)
        base = kind.to_sym == :command ? Context::COMMAND : Context::MESSAGE
        return [base] unless trigger.respond_to?(:hears_edits?) && trigger.hears_edits?

        [base, Context::EDIT]
      end

      # True for an invocation that never arrives with a message behind it.
      # A script may carry several conditions, so this asks about all of
      # them: one ordinary condition anywhere means a message can reach the
      # script and the probes must include its shapes, so only a script
      # whose every condition is a clock is woken-only.
      def woken_only?(kind, trigger)
        return true if kind.to_sym == :callback

        Array(trigger).all? { |one| one.class.type_name == "recurring" }
      end

      # What Features::Scripts#wake really builds: no text, no author, and
      # rubotty.kind() saying which wake it is, probed with and without data
      # since a callback reading rubotty.invocation_data().thing on an empty
      # payload is exactly the error this catches. Under LIVE, wake_reason is
      # also set to what a round's close_after wakes an on_close script with,
      # since a round_close style script branches on it first and probing it
      # only unset would pass the branch that never runs.
      def woken_payloads(kind, scenes = [QUIET])
        wake_kind = kind.to_sym == :callback ? Context::HTTP_CALLBACK : Context::SCHEDULED
        scenes.flat_map do |scene|
          suffix = note(scenes, scene)
          reason = scene == LIVE ? Rubotty::ControlPlane::Participation::ROUND_CLOSE_REASON : nil
          [
            ["woken probe 1#{suffix}",
             @context.decorate({ "invocation_data" => nil, "wake_reason" => reason }.compact,
                               kind: wake_kind), "", scene],
            ["woken probe 2#{suffix}",
             @context.decorate({ "invocation_data" => { "probe" => true }, "wake_reason" => reason }.compact,
                               kind: wake_kind), "", scene],
            ["woken probe 3#{suffix}",
             @context.decorate({ "invocation_data" => {}, "response" => { "status" => 200, "body" => {} } },
                               kind: wake_kind), "", scene]
          ]
        end
      end

      def probe(kind:, source:, payload:, registry:, label:, input: "")
        answer = @pool.run(source: source, arg: payload, registry: registry, timeout: @timeout)
        message = complaint(kind, answer, input)
        message && Failure.new(probe: label, message: message)
      rescue Scripting::Timeout
        Failure.new(probe: label, message: "took longer than #{@timeout}s, which will time out under load")
      rescue Scripting::Error => e
        Failure.new(probe: label, message: e.message)
      end

      # What is wrong with the answer, or nil when it is fine. This is the half
      # that has no runtime equivalent: at message time a bad answer is read as
      # "allow" and forgotten, and here it has to be said out loud.
      def complaint(kind, answer, input = "")
        return command_complaint(answer) if kind.to_sym == :command

        processor_complaint(answer, input)
      end

      def command_complaint(answer)
        return nil if answer.is_a?(String) || answer.nil?

        "a command has to return a string to post, and this returned #{describe(answer)}"
      end

      def processor_complaint(answer, input = "")
        return "a processor has to return a table, and this returned #{describe(answer)}" unless answer.is_a?(Hash)

        action = answer["action"].to_s
        unless %w[allow reject rewrite].include?(action)
          return "action was #{action.empty? ? "missing" : action.inspect}, " \
                 "and it has to be allow, reject or rewrite"
        end
        return nil unless action == "rewrite"
        return nil unless answer["text"].to_s.empty?
        # An empty rewrite of an empty message is not a mistake: a script that
        # substitutes into the text will legitimately produce nothing when there
        # was nothing. Only an empty rewrite of real text is a bug worth
        # refusing, and flagging the other case failed good scripts.
        return nil if input.to_s.empty?

        "a rewrite has to carry the replacement text, and this one had none"
      end

      def describe(value)
        case value
        when nil then "nothing"
        when String then "a string"
        when Numeric then "a number"
        when true, false then "a boolean"
        when Array then "a list"
        else value.class.name.downcase
        end
      end

      # Host functions are stubbed during a probe, so a script under test
      # never fires a real webhook at real people; the call count is
      # reported back, since a script that calls out on every input,
      # including the empty one, is usually wrong even when it doesn't
      # crash. Each stub answers with the shape the real function answers
      # with, so a script using these is actually checked, and the
      # participation half below answers differently depending on whether
      # anything is running, checking the documented `if not ok then` branch.
      SCENES = {
        QUIET => {
          "session" => nil,
          "round" => nil,
          "open_session" => true,
          "close_session" => Answer.refuse("nothing is running in this room"),
          "open_round" => Answer.refuse("nothing is running in this room"),
          "close_round" => Answer.refuse("no round is open in this room")
        },
        LIVE => {
          "session" => { "kind" => "trivia", "label" => "smoke test", "state" => "open",
                         "opened_at" => PROBE_CLOCK.call.to_i, "rounds" => 2 },
          "round" => { "id" => 2, "position" => 2, "opened_at" => PROBE_CLOCK.call.to_i,
                       "closes_at" => PROBE_CLOCK.call.to_i + 60, "data" => { "probe" => true } },
          "open_session" => Answer.refuse("something is already running in this room"),
          "close_session" => true,
          "open_round" => true,
          "close_round" => true
        }
      }.freeze

      STUBS = {
        "classify" => "clean",
        "link_verdict" => "clean",
        "offending_spans" => [],
        "rooms" => [],
        "platforms" => [],
        "features" => [],
        "events" => [],
        "feature_enabled" => false,
        # A room with nothing bridged into it, which is the careful branch and
        # therefore the one worth probing. The length is what a room spanning no
        # platform gets from Markup, so a script doing arithmetic on it works.
        "room_capabilities" => {
          "reactions" => false, "edit" => false, "delete" => false, "reply" => false,
          "threads" => false, "private_message" => false,
          "longest_message" => Markup::DEFAULT_LIMIT
        },
        # Nothing was remembered during a probe, so recall finds nothing. A stub
        # that always answered would hide the branch a rule takes on a miss,
        # which is the branch that runs the first time it ever fires.
        "recall" => nil,
        "remember" => true,
        "forget" => false,
        # A kept total nobody has touched yet, which is what a probe really
        # meets and the branch a script has to survive: `add` opens a key at
        # zero, so zero is the honest answer rather than a made up score.
        "add" => 0,
        "move" => true,
        "top" => [],
        "keys" => [],
        "entries" => [],
        "count_keys" => 0,
        # A tag, because that is what a real schedule answers and a script is
        # meant to hold onto it for unschedule.
        "schedule" => "smoke-test",
        "unschedule" => 0,
        # Shaped like a real answer, so a script reading response.ok or
        # response.data is checked rather than tripping over a boolean.
        "increment_stat" => true,
        "record_stat" => true,
        "community_stats" => {},
        # A name that matches nobody is a real answer, and so is a name that
        # matches two people, which is the whole reason this function refuses
        # to guess. Stubbing a hit would hide the branch every careful script
        # has to have.
        "resolve_participant" => nil,
        "mention_participant" => "@smoke-test",
        "name_participants" => {},
        "whisper" => true,
        # Shaped like a real handle rather than any old string, so a script that
        # stores one in a memo and reads it back is checked against the length
        # and the character set it will really see.
        "post" => Handle.of(Handle::Ref.new(endpoint_id: "smoke-test", native_id: "1")),
        "edit" => true,
        "delete" => true,
        "react" => true,
        "build" => { "version" => Rubotty::VERSION, "commit" => "smoke-test" }
      }.freeze

      # What participant() answers during a probe. A table on a run that has a
      # message behind it, and nil on a woken one, because that is what the
      # real function does and a gate that says otherwise passes a script that
      # then fails on its first real wake.
      PARTICIPANT = { "id" => "person:1", "display" => "smoke-test",
                      "platform" => "smoke", "is_operator" => false }.freeze

      # The seed every probe's randomness comes from. Fixed, so a check that
      # fails can be looked at twice and a rule that deals a hand deals the same
      # hand on every run of the gate.
      PROBE_SEED = 20_320

      # Styling, escaping, truncation, folding and randomness need no services
      # at all, so the probe runs the real ones. Stubbing them would hand a
      # script a boolean where a string belongs and fail the gate for a fault
      # entirely of the gate's own, and a stubbed random{} answering one number
      # would fail every script that loops over the list.
      def self.pure_handlers(generator: Random.new(PROBE_SEED))
        handlers = HostFunctions.markup_handlers
        handlers["escape"] = ->(text) { Markup.strip(text) }
        handlers["truncate"] = ->(text) { Markup.truncate(text, []) }
        handlers["fold"] = HostFunctions.fold_handler
        handlers["chars"] = HostFunctions.chars_handler
        handlers["random"] = HostFunctions.random_handler(generator: generator)
        handlers["shuffle"] = HostFunctions.shuffle_handler(generator: generator)
        handlers
      end

      class CountingRegistry < Registry
        # @param yaml_data [Object, nil] the script's own data file, served as
        #   itself rather than stubbed. A stub would be the wrong answer here:
        #   the data is real, known, and the whole reason a rule reading it
        #   decides anything, so probing against a fake one would check a branch
        #   the script never takes.
        # @param woken [Boolean] whether these probes are the shape a script
        #   gets with no message behind it, which is what decides whether there
        #   is anybody for participant() to answer with
        def initialize(yaml_data: nil, woken: false, scene: QUIET)
          super()
          @count = 0
          @yaml_data = yaml_data
          @woken = woken
          @scene = scene
          # Built per registry rather than shared, so each check starts from the
          # same seed and two runs of the gate over the same script agree.
          @pure = SmokeTest.pure_handlers
        end

        attr_reader :count

        # Moved between probes by {SmokeTest#run}, so one counter serves the
        # whole check while what it answers changes underneath.
        attr_accessor :scene

        # Everything a registry can be asked to serve, which is the catalog
        # minus the getters: those are answered inside the child out of the
        # payload, so a probe that offered them here would send a frame for
        # something the child already had.
        def names = HostFunctions.callable_names

        # Charged exactly the way production charges, or the gate would pass
        # a script that runs out of broadcasts the first time it really
        # fires. Nothing is registered here, so the inherited lookup would
        # answer :read for everything.
        def cost_of(name) = HostFunctions.cost_of(name)

        def call(name, args)
          @count += 1
          return @yaml_data if name.to_s == "yaml_data"
          return @woken ? nil : PARTICIPANT if name.to_s == "participant"

          handler = @pure[name.to_s]
          return handler.call(*args) if handler

          answers = SCENES.fetch(@scene, SCENES[QUIET])
          return answers[name.to_s] if answers.key?(name.to_s)

          STUBS.fetch(name.to_s, true)
        end
      end
    end
  end
end
