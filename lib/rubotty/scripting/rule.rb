# frozen_string_literal: true

module Rubotty
  module Scripting
    # One operator authored script plus the rule that wakes it. A rule is a
    # command or a processor, and the difference is what its answer means
    # rather than how it runs: a command's answer is a reply to post, a
    # processor's decides what happens to the message (pass it through,
    # rewrite it, or reject it).
    class Rule
      # Kept in step with ControlPlane::Scripts::KINDS by the spec, since these
      # are two lists that have to name the same things: a kind the store will
      # save and this refuses cannot be built, so the script silently never
      # runs. That is exactly what happened when callback was added.
      KINDS = %i[command processor callback].freeze

      attr_reader :name, :kind, :source, :triggers

      # +trigger+ takes one trigger or several. Several are tried in the order
      # declared and the first that matches wins, so a script runs once per
      # message however many conditions it carries, rather than once per
      # matching condition with invocations that cannot share memos.
      def initialize(name:, kind:, source:, trigger:)
        raise Failed, "#{kind.inspect} is not a kind of rule" unless KINDS.include?(kind.to_sym)

        @name = name.to_s
        @kind = kind.to_sym
        @source = source.to_s
        @triggers = Array(trigger)
      end

      # Build from the shape the dashboard stores: a type name, its config, and
      # the script body.
      def self.from_config(name:, kind:, source:, trigger_type:, trigger_config: {})
        new(name: name, kind: kind, source: source,
            trigger: Triggers.build_all(trigger_type, trigger_config))
      end

      # The first one, which is the whole story for a script carrying one.
      def trigger = @triggers.first

      def command? = @kind == :command

      # A callback never runs on traffic. It is only ever woken by schedule or
      # by an async_http answer, so the rule set skips it when folding a
      # message through.
      def callback? = @kind == :callback

      def processor? = @kind == :processor

      # Which trigger woke this rule, and what the script gets as its argument.
      #
      # @return [Array(Triggers::Base, Hash), nil] the trigger and its payload,
      #   or nil when nothing matched
      def fire(event)
        @triggers.each do |trigger|
          # An edit only reaches a trigger that asked for it; skipping BEFORE
          # observe keeps a windowed condition's ring from counting an edit
          # as another message. Checked on the event rather than assumed, so
          # a caller with its own event shape avoids a NoMethodError.
          next if edit?(event) && !trigger.hears_edits?

          payload = trigger.observe(event)
          return [trigger, payload] unless payload.nil?
        end
        nil
      end

      # What the script gets as its argument when this rule fires, for a caller
      # that does not care which condition did it.
      def observe(event) = fire(event)&.last

      private

      def edit?(event) = event.respond_to?(:edited?) && event.edited?
    end

    # What a processor decided. A script returns a plain table and this is
    # what reading it means, in one place, so a malformed or missing answer is
    # interpreted the same way everywhere. The default is deliberately
    # "allow": a broken rule degrades to doing nothing rather than silently
    # swallowing a room's traffic.
    class Verdict
      ALLOW = :allow
      REJECT = :reject
      REWRITE = :rewrite

      attr_reader :action, :text, :reason, :reply

      def initialize(action: ALLOW, text: nil, reason: nil, reply: nil)
        @action = action
        @text = text
        @reason = reason
        @reply = reply
      end

      def self.allow = new

      # @param value [Object] whatever the script returned
      def self.from_script(value)
        return allow unless value.is_a?(Hash)

        # reply rides along with whatever the action is, so "say Y when
        # somebody says X" is a one line processor instead of calling notify
        # as a side effect and returning a verdict separately.
        reply = presence(value["reply"])

        case value["action"].to_s
        when "reject" then new(action: REJECT, reason: presence(value["reason"]), reply: reply)
        when "rewrite" then rewrite_from(value, reply)
        else new(reply: reply)
        end
      end

      def self.rewrite_from(value, reply = nil)
        text = presence(value["text"])
        # A rewrite with nothing to rewrite to is a script bug, and dropping the
        # message would be the worst reading of it. The reply is still honoured:
        # it is the half the script got right.
        return new(reply: reply) if text.nil?

        new(action: REWRITE, text: text, reply: reply)
      end

      def self.presence(value)
        string = value.to_s
        string.empty? ? nil : string
      end
      private_class_method :presence

      def allow? = @action == ALLOW

      def reject? = @action == REJECT

      def rewrite? = @action == REWRITE

      def reply? = !@reply.nil?
    end

    # The rules in force for one scope, and the fold of a message through
    # them. Trigger state lives in the rule objects, so a RuleSet is per room:
    # two rooms never share a ring, which is what keeps "the last twenty
    # messages" meaning the last twenty in THIS room.
    class RuleSet
      def initialize(rules: [], pool: nil, registry: nil, logger: nil, timeout: Child::DEFAULT_TIMEOUT,
                     context: nil)
        @rules = rules
        @pool = pool
        @registry = registry
        @logger = logger
        @timeout = timeout
        # The ambient half of the payload (rubotty.now(), rubotty.room_key()
        # and the rest). Without it a script reading any of them sees nil
        # here while working in production, the one place a rule could pass a
        # test and still be broken.
        @context = context || Context.new
      end

      attr_reader :rules

      # Which rules this message wakes, with the payload each one matched on and
      # the trigger that did it. Pure: no script runs here, which is what makes
      # the matching testable on its own and what a dashboard dry run would call.
      def matches(event)
        @rules.filter_map do |rule|
          fired = rule.fire(event)
          fired.nil? ? nil : [rule, fired.last, fired.first]
        end
      end

      # Run every processor whose rule matched, in order, and return the first
      # decision that is not "allow": stops at the first reject, since once a
      # message is going, later rules have nothing to say about it. A rewrite
      # feeds the next rule the rewritten text, and a reply is carried through
      # regardless of the final action, matching the live pipeline exactly
      # since shipped examples are validated through here.
      def screen(event)
        verdict = Verdict.allow
        reply = nil
        current = event
        @rules.each do |rule|
          next unless rule.processor?

          fired = rule.fire(current)
          next if fired.nil?

          trigger, payload = fired
          decided = Verdict.from_script(invoke(rule, payload, trigger))
          reply = decided.reply if decided.reply?
          return with_reply(decided, reply) if decided.reject?

          next unless decided.rewrite?

          verdict = decided
          current = event_with(current, decided.text)
        end
        with_reply(verdict, reply)
      end

      def with_reply(verdict, reply)
        return verdict if reply.nil? || verdict.reply?

        Verdict.new(action: verdict.action, text: verdict.text,
                    reason: verdict.reason, reply: reply)
      end

      # Every command reply this message produced.
      def replies(event)
        matches(event).filter_map do |rule, payload, trigger|
          next unless rule.command?

          answer = invoke(rule, payload, trigger)
          answer.nil? ? nil : answer.to_s
        end
      end

      private

      def event_with(event, text)
        Triggers::Event.new(text: text, author_id: event.author_id,
                            author_name: event.author_name, room_key: event.room_key,
                            author_is_operator: event.author_is_operator,
                            origin_platform: event.origin_platform, edited: event.edited)
      end

      # A script that fails is logged and treated as having said nothing, so a
      # broken rule degrades to inaction. Failing closed here would mean an
      # operator's typo could stop a room relaying, which is a far worse outcome
      # than the rule not running.
      def invoke(rule, payload, trigger = nil)
        return nil if @pool.nil?

        @pool.run(source: rule.source,
                  arg: @context.decorate(payload, trigger: trigger&.class&.type_name),
                  registry: @registry, timeout: @timeout)
      rescue Scripting::Error => e
        @logger&.warn { "scripting: rule #{rule.name.inspect} failed: #{e.class}: #{e.message}" }
        nil
      end
    end
  end
end
