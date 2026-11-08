# frozen_string_literal: true

require "spec_helper"

# A slash command always gets an ephemeral answer, even when the answer is only
# a refusal, and the invocation is taken away with it. Core::CommandAck owns that
# contract, and four features answered a command word without it, leaving the
# invocation in the room until somebody noticed in a live community.

# The set checked here is derived from the code rather than listed, so the next
# feature to answer a word is caught here instead of in a room.
RSpec.describe "the shared command acknowledgement contract" do
  # The one feature that answers a room word and deliberately posts nothing
  # where it was typed. Reporting has to leave no trace, because the trace is
  # the reprisal: an ephemeral answer still shows the room who reported for as
  # long as it lives, however short its window is set. The invocation is still
  # taken away, by a plain delete, and the answer goes to the reporter by DM.
  ANSWERS_ELSEWHERE = { "Rubotty::Features::Reports" => "answers by DM and never in the room" }.freeze

  # Every word a feature answers in chat: what it declares for itself, what
  # Core::CommandRegistry registers against its feature_name, and the COMMAND or
  # COMMANDS constant a feature parses off the front of a message directly.
  def command_words(klass, registered)
    words = Array(klass.command_words).map(&:to_s) + Array(registered[klass.feature_name]).map(&:name)
    %i[COMMAND COMMANDS].each do |const|
      words += Array(klass.const_get(const)).map(&:to_s) if klass.const_defined?(const, false)
    end
    words.uniq.sort
  end

  # Every Features::Base subclass that really answers one: it reads chat, it owns
  # at least one word, and it has a #call of its own. A carrier class holding only
  # a feature flag and its config (Events, Poll, GuestPortal, FileRehosting) takes
  # Base#call, answers nothing, and is left out; the *Command class that serves
  # its words is picked up in its place.
  def answering_features
    # Room surface only: the contract is about a word answered where people
    # talk, and the console's DM verbs are answered in a DM instead.
    registered = Rubotty::Core::CommandRegistry.room_commands.group_by(&:feature)
    Rubotty::Features.constants.filter_map do |const|
      klass = Rubotty::Features.const_get(const)
      next unless klass.is_a?(Class) && klass < Rubotty::Features::Base
      next if klass.instance_method(:call).owner == Rubotty::Features::Base
      next unless klass.observes.include?(:chat) && command_words(klass, registered).any?
      next if ANSWERS_ELSEWHERE.key?(klass.name)

      klass
    end.uniq
  end

  # The exception list is held to features that exist and really do answer a
  # room word, so a stale entry cannot quietly excuse a feature from the rule.
  it "keeps the recorded exceptions to features that answer a room word" do
    ANSWERS_ELSEWHERE.each_key do |name|
      klass = Object.const_get(name)
      registered = Rubotty::Core::CommandRegistry.room_commands.group_by(&:feature)
      expect(command_words(klass, registered)).not_to be_empty, "#{name} answers no room word any more"
    end
  end

  # The reason is what makes an exception a decision rather than an oversight.
  it "says why each exception answers somewhere else" do
    expect(ANSWERS_ELSEWHERE.values.reject { |why| why.is_a?(String) && !why.strip.empty? }).to be_empty
  end

  # Where a feature's own answer could be written: the file defining its #call,
  # plus every file defining a method of its own, since PollCommand and
  # ScheduleCommand both take #call from a surface module they share.
  def sources(klass)
    own = klass.instance_methods(false) + klass.private_instance_methods(false)
    ([klass.instance_method(:call)] + own.map { |name| klass.instance_method(name) })
      .filter_map { |method| method.source_location&.first }.uniq
  end

  def source_text(klass) = sources(klass).map { |path| File.read(path, encoding: "UTF-8") }.join("\n")

  # The schema the dashboard renders for this feature, which is the carrier's
  # rather than the command class's wherever one feature spans several classes.
  def schema_for(klass)
    Rubotty::Features::Catalog.class_for(klass.feature_name)&.config_schema || klass.config_schema
  end

  def guidance(offenders)
    <<~MESSAGE
      These features answer a command word without going through the shared
      acknowledgement path:

      #{offenders.join("\n")}

      A slash command always gets an ephemeral answer, even when the answer is
      only a refusal, and the command message goes with it. Post the answer
      through Core::EphemeralMessage the way Features::UtilityCommands#acknowledge
      does:

        delay = Core::CommandAck.ttl_seconds(context.config)
        group = @ephemeral.post(
          endpoints: [context.message.origin], body: Core::RichText.plain(text),
          name: NOTICE_NAME, delete_after: delay,
          also_delete: Core::CommandAck.pair_with(context.message, context.config),
          reply_to: Core::CommandAck.reply_to(context.message)
        )
        @cleanup.after(delay) { group.delete_now } if delay.positive? && @cleanup && group.any?

      Leaving it out means the invocation stays in the room forever. A feature
      whose invocation must not stand at all, because it names an operator
      acting against a member, removes it outright in a remove_command instead.
    MESSAGE
  end

  it "finds the command features in the code rather than trusting a list" do
    names = answering_features.map(&:feature_name)

    expect(answering_features.length).to be > 15
    expect(names).to include("operator_requests", "identity_history", "warnings", "scripts",
                             "moderation", "utility_commands")
  end

  # The heart of it. Moderation pairs through delete_command? and not pair_with,
  # holding a parsed command rather than the raw message, and Warnings removes
  # the invocation outright because thirty seconds of it standing there names
  # the operator to the member they just warned; all three spellings count.
  it "takes the invocation away with the answer, everywhere a command is answered" do
    offenders = answering_features.reject do |klass|
      text = source_text(klass)
      text.include?("CommandAck.pair_with") || text.include?("CommandAck.delete_command?") ||
        text.include?("remove_command")
    end

    expect(offenders).to be_empty, guidance(offenders.map { |klass| "  #{klass.name}" })
  end

  it "gives every answer a horizon rather than leaving it in the room" do
    offenders = answering_features.reject { |klass| source_text(klass).include?("delete_after:") }

    expect(offenders.map(&:name)).to be_empty
  end

  # /operator read its window from a bespoke ack_delete_after of its own, so the
  # dashboard could not edit it under the key every other feature uses. One key
  # or none: a feature is free to borrow another timer, and free to declare the
  # shared one, but not to invent a second spelling of it.
  it "keeps the acknowledgement window under the one shared key" do
    bespoke = answering_features.filter_map do |klass|
      schema = schema_for(klass)
      next if schema.nil?

      stray = schema.fields.keys.grep(/\Aack_/) - [Rubotty::Core::CommandAck::TTL_FIELD]
      "#{klass.feature_name}: #{stray.join(", ")}" if stray.any?
    end

    expect(bespoke).to be_empty
  end
end
