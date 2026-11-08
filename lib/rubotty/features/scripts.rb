# frozen_string_literal: true

require "set"

module Rubotty
  module Features
    # Operator authored scripts, run immediately before Bridge and after every
    # built in feature, so a script only sees a message the filters have
    # already acted on. A reject removes the message everywhere and halts; a
    # rewrite deletes then reposts, and is abandoned if the delete fails,
    # since a room seeing both original and replacement is worse than the
    # original alone. Everything fails open: a broken rule is recorded and the
    # circuit breaker eventually switches it off rather than stopping the
    # room's traffic.
    class Scripts < Base
      def self.feature_name = "scripts"

      # The durable-scheduler job kind rubotty.later schedules. Its payload
      # names a community and an endpoint, never a script, so a deferred job
      # can never re-enter Lua.
      LATER_KIND = "script_endpoint_call"

      # A script woken on a clock rather than by traffic. Its own kind so the
      # reconcile below can clear every recurring wake for a community without
      # touching a schedule() call somebody's rule booked.
      RECURRING_KIND = "script_recurring"

      # The word that flips tracing, a constant so the parser below and
      # {DisabledCommandNotice} cannot disagree about its spelling.
      DEBUG_COMMAND = "debug-lua"

      # The sender label the /debug-lua acknowledgement is posted under.
      NOTICE_NAME = "scripts"

      def self.description = "Runs operator written rules against messages, in any supported dialect."

      # Edits are here so a script CAN see one; whether it does is per trigger
      # and off by default, so a rule written before edits existed still folds
      # through untouched, since {Scripting::Rule#fire} skips any trigger that
      # did not ask for one.
      def self.observes = %i[chat edit]

      def self.default_enabled? = false

      # The one word this feature answers, which the registry does not carry.
      def self.command_words = [DEBUG_COMMAND]

      # Tracing is off by default, flipped from chat with /debug-lua, and lives
      # as ordinary per-scope config rather than anything cleverer, so the
      # dashboard can flip it too and a restart doesn't lose it. A trace
      # carries the room's traffic and the script's own source, so it stays
      # until somebody removes it rather than expiring on its own.
      def self.config_schema
        Config::Schema.define do
          field :debug, :boolean, default: false,
                                  desc: "post each invocation's payload, source and answer into the room"
          # Every other filter offers this, and a script that rejects or
          # rewrites was hitting moderators with no way to exempt them.
          field :exempt_operators, :boolean, default: true,
                                             desc: "never remove or rewrite an operator's own message"
          field Core::CommandAck::TTL_FIELD, :integer, default: Core::CommandAck::DEFAULT_TTL_SECONDS,
                desc: "seconds a /debug-lua reply lives before it self-deletes. 0 leaves it in place."
          field Core::CommandAck::DELETE_COMMAND_FIELD, :boolean,
                default: Core::CommandAck::DELETE_COMMAND_DEFAULT,
                desc: "whether the /debug-lua invocation itself is removed together with its reply"
        end
      end

      # Per field, so one enormous message cannot push the rest off the screen.
      TRACE_LIMIT = 700

      # @param scripts [ControlPlane::Scripts, nil] where the rules live
      # @param pool [Scripting::Pool, nil] where they run
      # @param registry_for [#call, nil] community -> Scripting::Registry, so the
      #   host functions a script gets can be scoped to its own community
      # @param clock [#call] frozen per invocation, injectable for tests
      # @param ephemeral [Core::EphemeralMessage, nil] posts the /debug-lua answer
      # @param cleanup [Core::Scheduler, nil] fires that answer's self-delete on time
      def initialize(scripts: nil, pool: nil, registry_for: nil, logger: nil,
                     removal: nil, poster: nil, room_poster: nil, endpoint_runner: nil,
                     ephemeral: nil, cleanup: nil, clock: -> { Time.now.utc })
        super()
        @scripts = scripts
        @pool = pool
        @registry_for = registry_for
        @logger = logger
        @removal = removal
        @poster = poster
        @room_poster = room_poster
        @endpoint_runner = endpoint_runner
        @ephemeral = ephemeral
        @cleanup = cleanup
        @clock = clock
        @cache = {}
        @tracing = {}
      end

      attr_reader :logger

      # Run one script outside the message pipeline: rubotty.schedule booked it
      # or an async_http answer came back. The payload has no text and no
      # author, so a script written assuming a normal message will break; with
      # no message to reject, only the text a command or processor returned is
      # used.
      def wake(community:, row:, room_key:, kind:, data: nil, response: nil, generation: 0, wake_reason: nil)
        return if @pool.nil? || !@pool.available?

        rule = build_rule(row)
        return if rule.nil?

        payload = wake_payload(kind: kind, room_key: room_key, data: data, response: response,
                               wake_reason: wake_reason)
        # Built here rather than inside the registry, so what the script asked
        # for during the run can be drained afterwards.
        woken = Scripting::WakeContext.new(community: community, room_key: room_key,
                                           generation: generation)
        answer = @pool.run(source: rule.source, arg: payload,
                           registry: wake_registry(woken, row),
                           timeout: Scripting::Child::DEFAULT_TIMEOUT)
        note_wake(row)
        spoken = spoken_text(rule, answer)
        @room_poster&.call(community, room_key, spoken) unless spoken.nil?
        # A woken script may ask for an endpoint call too, and nothing drained
        # that, so a chain stopped dead at its first hop without saying so.
        dispatch_wake_requests(community, room_key, woken)
      rescue Scripting::Error => e
        logger&.warn { "scripts: #{row.name.inspect} failed on a #{kind} wake: #{e.message}" }
        note_wake(row, failed: true)
        @scripts&.record_error(row, e.message)
      rescue StandardError => e
        logger&.warn { "scripts: a #{kind} wake failed: #{e.class}: #{e.message}" }
      end

      private

      # A wake is counted apart from traffic, since the clock waking a rule
      # says nothing about whether anybody is using it.
      def note_wake(row, failed: false)
        @scripts&.record_run(row, source: "wake", failed: failed)
      rescue StandardError => e
        logger&.debug { "scripts: could not count a wake: #{e.message}" }
      end

      def wake_payload(kind:, room_key:, data:, response:, wake_reason: nil)
        context = Scripting::Context.new(room_key: room_key, clock: @clock)
        body = { "invocation_data" => data }
        body["response"] = response unless response.nil?
        body["wake_reason"] = wake_reason unless wake_reason.nil?
        context.decorate(body, kind: kind.to_s)
      end

      def wake_registry(woken, row)
        return nil if @registry_for.nil?

        @registry_for.call(woken, row)
      end

      # A command answers with a string; a processor may carry one in `reply`.
      # Anything else is a script that had nothing to say.
      def spoken_text(rule, answer)
        return presence(answer) if rule.command?
        return nil unless answer.is_a?(Hash)

        presence(answer["reply"])
      end

      def presence(value)
        text = value.to_s
        text.empty? ? nil : text
      end

      public

      def call(context)
        answer = handle_debug_command(context)
        return answer if answer

        return Outcome.continue([]) unless runnable?(context)

        rules = rules_for(context)
        return Outcome.continue([]) if rules.empty?

        decide(context, rules)
      rescue StandardError => e
        # Nothing a script does may derail the pipeline, including a failure in
        # this class's own bookkeeping.
        logger&.warn { "scripts: pipeline step failed: #{e.class}: #{e.message}" }
        Outcome.continue([])
      end

      private

      # /debug-lua on|off, operators only. In memory and expiring rather than a
      # row somebody has to remember to unset, since debug output carries a
      # room's traffic and an operator's source; a restart or an hour both
      # clear it.
      DEBUG_WINDOW = 60 * 60

      def handle_debug_command(context)
        wanted = debug_command_argument(context)
        return nil if wanted.nil?

        unless operator?(context, context.message)
          return say(context, "Only an operator can turn script tracing on.")
        end

        key = [community_key(context.community), room_key(context)]
        on = %w[on true yes 1].include?(wanted)
        @tracing[key] = on ? @clock.call + DEBUG_WINDOW : nil
        say(context, on ? "Script tracing on for an hour. It carries your script's source, so mind who is here." : "Script tracing off.")
      end

      # nil unless this message really is the command, so anything else falls
      # through untouched. Only a fresh message counts: an edit turning old
      # text into "/debug-lua on" should not flip tracing on, since a trace
      # carries the room's traffic and the script's source.
      def debug_command_argument(context)
        return nil unless context.message.kind == :chat

        word, arguments = CommandWord.parse(context)
        return nil unless word == DEBUG_COMMAND

        arguments.first.to_s.downcase
      end

      # The /debug-lua answer is a command acknowledgement like any other: it goes
      # back to whoever typed it rather than to every platform in the room, it
      # self-deletes, and it takes the invocation with it. Never raises.
      def say(context, text)
        acknowledge(context, text)
        Outcome.halt([])
      end

      def acknowledge(context, text)
        return if @ephemeral.nil?

        delay = Core::CommandAck.ttl_seconds(context.config)
        group = @ephemeral.post(
          endpoints: [context.message.origin], body: Core::RichText.plain(text),
          name: NOTICE_NAME, delete_after: delay,
          also_delete: Core::CommandAck.pair_with(context.message, context.config),
          reply_to: Core::CommandAck.reply_to(context.message)
        )
        @cleanup.after(delay) { group.delete_now } if delay.positive? && @cleanup && group.any?
      rescue StandardError => e
        logger&.warn { "scripts: could not answer /#{DEBUG_COMMAND}: #{e.message}" }
      end

      # On when the operator said so in the last hour, or when the dashboard has
      # it set for this scope.
      def tracing?(context)
        until_at = @tracing[[community_key(context.community), room_key(context)]]
        return true if until_at && @clock.call < until_at

        !!(context.config && truthy?(context.config[:debug] || context.config["debug"]))
      rescue StandardError
        false
      end

      def truthy?(value, default: false)
        return default if value.nil?
        return value if value == true || value == false

        %w[true yes on 1].include?(value.to_s.strip.downcase)
      end

      # What Ruby handed Lua, what Lua actually ran, and what came back. One
      # message rather than three, so following an invocation does not mean
      # reading three that arrived out of order, and it stays put: the poster
      # is handed no delay, which is what the ephemeral primitive takes to mean
      # "leave it alone".
      def trace(context, rule, payload, outcome, failed: false)
        return unless @poster

        @poster.call(context, [
          "script trace: #{rule.name}#{failed ? " (failed)" : ""}",
          "payload:",
          clip(payload.inspect),
          "source:",
          clip(rule.source),
          failed ? "raised:" : "returned:",
          clip(failed ? outcome : outcome.inspect)
        ].join("\n"))
      rescue StandardError => e
        logger&.debug { "scripts: could not post a trace: #{e.message}" }
      end

      def clip(text)
        string = text.to_s
        string.length > TRACE_LIMIT ? "#{string[0, TRACE_LIMIT]}..." : string
      end

      # Whether this author is spared what a script DECIDES. exempt_operators
      # only blocks a REJECT or REWRITE on an operator's own message: it still
      # runs, replies, remembers, and answers commands, so an operator can
      # drive their own script without also being exempt from their own rules.
      def spared_verdicts?(context)
        return false unless truthy?(config_value(context, :exempt_operators), default: true)

        operator?(context, context.message)
      end

      def config_value(context, key)
        config = context.config || {}
        config.key?(key) ? config[key] : config[key.to_s]
      end

      def runnable?(context)
        !@scripts.nil? && !@pool.nil? && !context.community.nil? && @pool.available?
      end

      # The rules this room has live, rebuilt when the community's scripts
      # change. Trigger state (the rings a recent_contains rule keeps) lives on
      # these objects, so they have to survive between messages, and they are
      # keyed per room so "the last twenty messages" means the last twenty here.
      def rules_for(context)
        key = [community_key(context.community), room_key(context)]
        rows = active_rows(context.community)
        entry = (@cache[key] ||= { rules: {}, rows: {} })

        # The signature used to cover every active row, so ANY write in the
        # community (even one script's failure, which bumps updated_at) threw
        # away every rule object and the windowed-trigger rings with it: a
        # flood rule counting three in the last ten silently went back to zero.
        live = rows.filter_map do |row|
          stamp = row.updated_at.to_s
          held = entry[:rules][row.id]
          if held.nil? || held[:stamp] != stamp
            rule = build_rule(row)
            next nil if rule.nil?

            held = { stamp: stamp, rule: rule }
            entry[:rules][row.id] = held
          end
          entry[:rows][held[:rule].object_id] = row
          held[:rule]
        end

        # A script that was archived or switched off should stop, and its ring
        # should not sit here forever.
        keep = rows.map(&:id).to_set
        entry[:rules].delete_if { |id, _| !keep.include?(id) }
        # And the row behind it. This half is keyed by the rule's object_id, so
        # every edit added an entry holding a live database row and removed
        # none: one leaked row per edit per room per community, kept for the
        # life of the process.
        alive = entry[:rules].each_value.map { |held| held[:rule].object_id }.to_set
        entry[:rows].delete_if { |object_id, _| !alive.include?(object_id) }
        live
      end

      def active_rows(community)
        @scripts.active(community)
      rescue StandardError => e
        logger&.warn { "scripts: could not load scripts: #{e.class}: #{e.message}" }
        []
      end

      def build_rule(row)
        Scripting::Rule.from_config(
          name: row.name, kind: row.kind, source: row.compiled.to_s,
          trigger_type: row.trigger_type, trigger_config: @scripts.trigger_config(row)
        )
      rescue Scripting::Error => e
        logger&.warn { "scripts: #{row.name.inspect} would not load: #{e.message}" }
        nil
      end

      # Run the matching rules and turn their answers into an Outcome.
      def decide(context, rules)
        event = event_for(context)
        payload_context = Scripting::Context.new(room_key: room_key(context), clock: @clock)
        replies = []
        verdict = Scripting::Verdict.allow
        current = event
        spared = spared_verdicts?(context)

        rules.each do |rule|
          # A callback is only ever woken by schedule or by an async_http
          # answer, so it takes no part in folding a message through.
          next if rule.callback?

          fired = rule.fire(current)
          next if fired.nil?

          trigger, matched = fired
          answer = invoke(context, rule,
                          payload_context.decorate(matched, message: current,
                                                   kind: payload_kind(rule, current),
                                                   trigger: trigger.class.type_name))
          next if answer.nil?

          if rule.command?
            replies << answer.to_s
            next
          end

          decided = spare(rule, Scripting::Verdict.from_script(answer), spared)
          # Posted the same way a command's answer is, whatever the action
          # turned out to be, so the simplest thing anybody wants (say Y when
          # somebody says X) is a one line processor.
          replies << decided.reply if decided.reply?
          if decided.reject?
            outcome = rejected(context, rule, decided, replies)
            dispatch_requests(context)
            return outcome
          end
          next unless decided.rewrite?

          verdict = decided
          current = with_text(current, decided.text)
        end

        outcome = finish(context, verdict, replies)
        dispatch_requests(context)
        outcome
      end

      # What rubotty.kind() answers. An edit is its own kind whatever the rule is, because
      # "this text changed" is the fact a script has to know about; a command
      # script that hears edits reads the command and its arguments exactly as before.
      def payload_kind(rule, event)
        return Scripting::Context::EDIT if event.edited?
        return Scripting::Context::COMMAND if rule.command?

        Scripting::Context::MESSAGE
      end

      # An exempt operator keeps the reply and loses the action, so a rule that
      # removes a message and says why still says why. Written as a verdict
      # rather than a skip, so removal, notice and halt all stay in one place
      # and cannot disagree about whether this message was rejected.
      def spare(rule, decided, spared)
        return decided unless spared && (decided.reject? || decided.rewrite?)

        logger&.debug do
          "scripts: #{rule.name.inspect} wanted to #{decided.action} an operator's own message, " \
            "and exempt_operators is on"
        end
        Scripting::Verdict.new(reply: decided.reply)
      end

      # Fire whatever async_http calls the rules asked for, after the reply is
      # already posted so nothing waits on the network. The callback is woken
      # with the answer whether or not it succeeded, because an endpoint that
      # died silently leaves a script no way to tell the room.
      def dispatch_wake_requests(community, room_key, woken)
        return if @endpoint_runner.nil?

        drained = woken.script_requests.dup
        woken.script_requests.clear
        drained.each { |request| @endpoint_runner.call(community, room_key, request) }
      rescue StandardError => e
        logger&.warn { "scripts: could not run a woken endpoint call: #{e.class}: #{e.message}" }
      end

      def dispatch_requests(context)
        pending = context.respond_to?(:script_requests) ? context.script_requests : []
        return if pending.empty? || @endpoint_runner.nil?

        drained = pending.dup
        pending.clear
        drained.each { |request| @endpoint_runner.call(context.community, room_key(context), request) }
      rescue StandardError => e
        logger&.warn { "scripts: could not dispatch an endpoint call: #{e.class}: #{e.message}" }
      end

      # Remove the message everywhere and stop the chain. Without the removal
      # engine there is nothing honest to do: halting alone would stop the
      # relay while leaving the original sitting on its own platform, so the
      # message is allowed through and the gap is logged loudly.
      def rejected(context, rule, decided, replies = [])
        if @removal.nil?
          logger&.warn { "scripts: #{rule.name.inspect} rejected a message but no removal engine is wired" }
          return Outcome.continue(replies)
        end

        @removal.remove_everywhere(context.message)
        @removal.notice(context: context, action: "delete",
                        reason: decided.reason || "A community rule removed this message.")
        # A reply survives the halt. Rejecting and saying why in one answer is
        # the case notify still exists for, and a script that used the new
        # shape to do it should not lose the words.
        Outcome.halt(replies)
      end

      # Delete then repost, in that order and only in that order. If the delete
      # fails the rewrite is abandoned, because a room showing the original AND
      # the replacement is worse than one showing the original alone.
      def finish(context, verdict, replies)
        return Outcome.continue(replies) unless verdict.rewrite?
        return abandoned(replies, "no removal engine is wired") if @removal.nil? || @poster.nil?

        removed = @removal.remove_everywhere(context.message)
        return abandoned(replies, "the original could not be removed") if Array(removed).compact.empty?

        repost(context, verdict.text)
        Outcome.halt(replies)
      end

      def abandoned(replies, why)
        logger&.warn { "scripts: abandoned a rewrite because #{why}" }
        Outcome.continue(replies)
      end

      # Posted as the bot on the author's behalf, to the whole room including
      # the platform it came from, so every side reads the same text.
      def repost(context, text)
        @poster.call(context, text)
      rescue StandardError => e
        logger&.warn { "scripts: could not post the rewrite: #{e.class}: #{e.message}" }
      end

      # Whatever the script answered, or nil when it failed. A failure is
      # recorded on the row so the editor can show it and the circuit breaker
      # can eventually switch the rule off.
      def invoke(context, rule, payload)
        answer = @pool.run(source: rule.source, arg: payload, registry: registry(context, row_for(context, rule)),
                           timeout: Scripting::Child::DEFAULT_TIMEOUT)
        trace(context, rule, payload, answer) if tracing?(context)
        note_run(context, rule)
        note_success(context, rule)
        answer
      rescue Scripting::Error => e
        # Traced before the failure is recorded, since a rule that breaks is
        # exactly when somebody wants to see what it was handed. The error goes
        # to the room too: reading it in the editor means knowing to look.
        trace(context, rule, payload, "#{e.class}: #{e.message}", failed: true) if tracing?(context)
        note_run(context, rule, failed: true)
        note_failure(context, rule, e)
        nil
      end

      # One run per handoff, whatever the rule decided with it: a message it
      # rejects is a message it was asked about, so it counts like any other.
      # Cheap because the store holds this in memory and writes out on its own
      # thresholds rather than on this message.
      def note_run(context, rule, failed: false)
        row = row_for(context, rule)
        @scripts&.record_run(row, failed: failed) if row
      rescue StandardError => e
        logger&.debug { "scripts: could not count a run: #{e.message}" }
      end

      # The counter only means CONSECUTIVE failures if a clean run clears it,
      # and nothing cleared it: the breaker was counting a rule's failures for
      # its whole life, so one that broke once a month was switched off in
      # month five. Cheap because the store returns early when the count is
      # already zero, which is almost every message.
      def note_success(context, rule)
        row = row_for(context, rule)
        @scripts&.record_success(row) if row
      rescue StandardError => e
        logger&.debug { "scripts: could not clear the failure count: #{e.message}" }
      end

      def note_failure(context, rule, error)
        logger&.warn { "scripts: #{rule.name.inspect} failed: #{error.class}: #{error.message}" }
        row = row_for(context, rule)
        @scripts.record_error(row, error.message) if row
      rescue StandardError => e
        logger&.debug { "scripts: could not record the failure: #{e.message}" }
      end

      # The stored row behind a rule, from THIS community and room's cache entry
      # only. Memory is scoped to the row, so resolving the wrong one is a cross
      # tenant read and write rather than a cosmetic mix up.
      def row_for(context, rule)
        entry = @cache[[community_key(context.community), room_key(context)]]
        entry && entry[:rows][rule.object_id]
      end

      def registry(context, row)
        @registry_for ? @registry_for.call(context, row) : nil
      end

      def event_for(context)
        message = context.message
        Scripting::Triggers::Event.new(
          # Stripped here, once, on the way in: styling from a script is carried by
          # private use characters, and a member pasting one into an echoed message
          # could otherwise forge formatting or a mention. Doing it centrally beats
          # trusting every rule to remember rubotty.escape.
          text: Scripting::Markup.strip(message.body.text),
          author_id: message.author&.native_id.to_s,
          # any_name rather than display_name, which Telegram leaves nil for
          # anybody who has only set a first name or a username, so the author
          # reached every script as "". Stripped for the reason the text above
          # is: a display name is member controlled too.
          author_name: Scripting::Markup.strip(message.author&.any_name.to_s),
          room_key: room_key(context),
          author_is_operator: operator?(context, message),
          origin_platform: message.origin&.adapter_name.to_s,
          edited: message.kind == :edit,
          # All three were already on the message and were being thrown away.
          # Nothing is fetched here: the parser put them there.
          attachments: attachments_of(message),
          reply_to: reply_to_of(message),
          handle: Scripting::Handle.of(message.ref)
        )
      end

      # The url is deliberately not among these: a script holding a fetchable
      # link could post a private upload to the room. `ref` is the platform's
      # own reference, enough to tell two files apart and useless for anything
      # else.
      def attachments_of(message)
        Array(message.attachments).map do |attachment|
          {
            "kind" => attachment.kind.to_s,
            # A filename is chosen by whoever uploaded it, so it is stripped
            # like every other member controlled string on this payload.
            "filename" => Scripting::Markup.strip(attachment.filename.to_s),
            "bytes" => attachment.size.to_i,
            "content_type" => attachment.mime_type.to_s,
            "ref" => attachment.native_ref.to_s
          }
        end
      end

      # The message this one answers, or nil when it answers nothing. The
      # excerpt is the one the adapter captured at parse time
      # (Core::ReplyPreview), so this costs no lookup and works for a parent
      # that predates the bridge.
      def reply_to_of(message)
        return nil if message.reply_to.nil?

        preview = message.reply_preview
        author = preview&.author&.any_name.to_s
        {
          "handle" => Scripting::Handle.of(message.reply_to),
          "author" => Scripting::Markup.strip(author.empty? ? preview&.label.to_s : author),
          "text" => Scripting::Markup.strip(preview&.body&.text.to_s)
        }
      end

      # Fail closed: an author the directory cannot resolve is treated as an
      # ordinary member, so a rule that goes easy on operators does not go easy
      # on everybody when the lookup breaks.
      def operator?(context, message)
        directory = context.operators
        return false if directory.nil? || message.author.nil?

        !directory.resolve(message.origin.adapter_name, message.author.native_id,
                           username: message.author.username).nil?
      rescue StandardError => e
        logger&.warn { "scripts: operator? failed: #{e.class}: #{e.message}" }
        false
      end

      # A rewrite changes the text and nothing else about who said it, what
      # they attached or what they were answering, so everything but the text
      # is carried over. Dropping them here would mean the second rule in a
      # chain saw a message with no attachments purely because the first one
      # rewrote a word.
      def with_text(event, text)
        Scripting::Triggers::Event.new(
          text: text, author_id: event.author_id, author_name: event.author_name,
          room_key: event.room_key, author_is_operator: event.author_is_operator,
          origin_platform: event.origin_platform, edited: event.edited,
          attachments: event.attachments, reply_to: event.reply_to,
          handle: event.handle
        )
      end

      # Nothing in the chain answers to room_key: Snapshot::Channel's own
      # route_key is the platform side key (a Telegram chat_id) and would be
      # wrong here. Shared with the router, so a script's memos scope to the
      # same room on both sides.
      def room_key(context)
        Scripting::RoomKey.for(channel: context.channel, community: context.community)
      end

      def community_key(community)
        community.respond_to?(:slug) ? community.slug.to_s : community.object_id
      end
    end
  end
end
