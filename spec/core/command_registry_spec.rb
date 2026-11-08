# frozen_string_literal: true

require "spec_helper"

# The one neutral description of the bot's command surface: the Discord adapter
# turns each Spec into a native slash command, but nothing here is Discord-shaped.
RSpec.describe Rubotty::Core::CommandRegistry do
  describe ".all" do
    it "lists the moderation verbs a person actually issues, in order, first" do
      expect(described_class.moderation_specs.map(&:name)).to eq(
        %w[delete ban kick mute unmute pin unpin clean lock unlock]
      )
      expect(described_class.all.first(10).map(&:name)).to eq(
        %w[delete ban kick mute unmute pin unpin clean lock unlock]
      )
    end

    it "then lists the public utility commands" do
      expect(described_class.all.map(&:name)).to include("find", "platforms", "event", "guest")
    end

    it "gives /event one typed, keyed argument per field, native to Discord's own picker" do
      event = described_class.find("event")
      expect(event.everyone?).to be(true)
      expect(event.targets_message?).to be(false)
      expect(event.targets_user?).to be(false)
      expect(event.arguments.map(&:name)).to eq(%w[title start kind tz game server url rsvp repeat reminders])
      expect(event.arguments).to all(be_keyed)
    end

    it "keeps /event's required arguments ahead of its optional ones, which Discord's own registration demands" do
      required, optional = described_class.find("event").arguments.partition(&:required?)
      expect(required.map(&:name)).to eq(%w[title start kind])
      expect(optional.map(&:name)).to eq(%w[tz game server url rsvp repeat reminders])
    end

    it "leaves /rsvp's two arguments unkeyed (positional): neither is ever blank, so a plain space-join round-trips them" do
      rsvp = described_class.find("rsvp")
      expect(rsvp.arguments.map(&:name)).to eq(%w[id response])
      expect(rsvp.arguments).to all(satisfy { |argument| !argument.keyed? })
      expect(rsvp.arguments.map(&:required?)).to eq([true, true])
    end

    it "gives /events one optional, unkeyed id, and lets anyone run it" do
      events = described_class.find("events")
      expect(events.everyone?).to be(true)
      expect(events.arguments.map(&:name)).to eq(%w[id])
      expect(events.arguments.first.required?).to be(false)
    end

    it "gates /remind to moderators, with a required event id" do
      remind = described_class.find("remind")
      expect(remind.moderator?).to be(true)
      expect(remind.arguments.map(&:name)).to eq(%w[id])
      expect(remind.arguments.first.required?).to be(true)
    end

    it "gives /reschedule a required, unkeyed id like /rsvp, then every other field keyed and optional" do
      reschedule = described_class.find("reschedule")
      expect(reschedule.everyone?).to be(true)
      expect(reschedule.arguments.map(&:name)).to eq(
        %w[id title start tz end description url repeat reminders]
      )
      id, *fields = reschedule.arguments
      expect(id.required?).to be(true)
      expect(id.keyed?).to be(false)
      expect(fields).to all(be_keyed)
      expect(fields.map(&:required?)).to all(be(false))
    end

    it "gives /poll a free-text question and keyed, optional reply_options, duration and multi_select overrides" do
      poll = described_class.find("poll")
      expect(poll.arguments.map(&:name)).to eq(%w[question reply_options duration multi_select])
      expect(poll.arguments.first).not_to be_keyed
      expect(poll.arguments[1..]).to all(be_keyed)
      expect(poll.arguments[1..]).to all(satisfy { |argument| !argument.required? })
      expect(poll.arguments[1].type).to eq(:boolean)
      expect(poll.arguments[2].type).to eq(:string)
      expect(poll.arguments[3].type).to eq(:boolean)
    end

    it "gives /schedule a labelled box per field, all keyed like /event" do
      schedule = described_class.find("schedule")
      expect(schedule.arguments.map(&:name)).to eq(%w[name game times duration tz])
      expect(schedule.arguments).to all(be_keyed)
      required, optional = schedule.arguments.partition(&:required?)
      expect(required.map(&:name)).to eq(%w[name game times])
      expect(optional.map(&:name)).to eq(%w[duration tz])
      expect(schedule.arguments.find { |a| a.name == "times" }.description).to include("|")
    end

    # A registry Spec is free to name any argument it likes, independent of
    # what the feature's own parser actually reads off a keyed word. This ties
    # the two together so a keyed argument with nothing on the parser side to
    # receive it fails loudly instead of drifting apart unnoticed.
    it "keeps /poll's keyed arguments in lockstep with what its parser's ALLOWED_DIRECTIVES accepts" do
      poll = described_class.find("poll")
      expect(poll.arguments.select(&:keyed?).map(&:name)).to match_array(
        Rubotty::Features::PollCommand::ALLOWED_DIRECTIVES.map(&:to_s)
      )
    end

    it "keeps /schedule's keyed arguments in lockstep with what its parser's ALLOWED_FIELDS accepts" do
      schedule = described_class.find("schedule")
      expect(schedule.arguments.select(&:keyed?).map(&:name)).to match_array(
        Rubotty::Features::ScheduleCommand::ALLOWED_FIELDS
      )
    end

    it "keeps /event's keyed arguments in lockstep with what its parser's ALLOWED_FIELDS accepts" do
      event = described_class.find("event")
      expect(event.arguments.select(&:keyed?).map(&:name)).to match_array(
        Rubotty::Features::EventCommand::ALLOWED_FIELDS
      )
    end

    it "keeps /reschedule's keyed arguments in lockstep with what its parser's ALLOWED_FIELDS accepts" do
      reschedule = described_class.find("reschedule")
      expect(reschedule.arguments.select(&:keyed?).map(&:name)).to match_array(
        Rubotty::Features::RescheduleCommand::ALLOWED_FIELDS
      )
    end

    it "gives /guest one free-text argument, for the same Discord round-trip reason as /event" do
      guest = described_class.find("guest")
      expect(guest.everyone?).to be(true)
      expect(guest.targets_message?).to be(false)
      expect(guest.targets_user?).to be(false)
      expect(guest.arguments.map(&:name)).to eq(["invite"])
      expect(guest.arguments.first.required?).to be(true)
    end

    it "gives /nickname a free-text, optional instruction, so a bare invocation still shows yours" do
      nickname = described_class.find("nickname")
      expect(nickname.feature).to eq("nickname")
      expect(nickname.everyone?).to be(true)
      expect(nickname.arguments.map(&:name)).to eq(["instruction"])
      expect(nickname.arguments.first.required?).to be(false)
    end

    it "gives /operator a free-text, optional action, so a bare invocation still defaults to request" do
      operator = described_class.find("operator")
      expect(operator.feature).to eq("operator_requests")
      expect(operator.everyone?).to be(true)
      expect(operator.arguments.map(&:name)).to eq(["action"])
      expect(operator.arguments.first.required?).to be(false)
    end

    it "leaves out unban, which has no reply to target and is issued programmatically" do
      expect(described_class.all.map(&:name)).not_to include("unban")
    end

    it "describes every command for a person, not a log" do
      described_class.all.each do |spec|
        expect(spec.description).not_to be_empty
        expect(spec.description).to match(/\A[A-Z]/)
      end
    end
  end

  describe "targets" do
    it "marks message verbs as acting on a message" do
      %w[delete pin unpin].each do |name|
        expect(described_class.find(name).targets_message?).to be(true)
      end
    end

    it "marks user verbs as acting on a person" do
      %w[ban kick mute unmute].each do |name|
        expect(described_class.find(name).targets_user?).to be(true)
      end
    end

    # lock, unlock and clean name no reply; the room comes from context.channel
    # or the argument, the same way /schedule and /event resolve theirs.
    it "targets neither a message nor a user for the room-scoped verbs" do
      %w[lock unlock clean].each do |name|
        spec = described_class.find(name)
        expect(spec.targets_message?).to be(false)
        expect(spec.targets_user?).to be(false)
      end
    end
  end

  # Every other targeted verb is reachable only by naming its target. /unpin
  # also answers a room, so a client that made its picker mandatory would hide
  # that form completely.
  it "requires the target of every targeted verb but unpin" do
    targeted = described_class.all.select { |spec| spec.targets_message? || spec.targets_user? }

    expect(targeted.reject(&:target_required?).map(&:name)).to eq(["unpin"])
  end

  describe "arguments" do
    it "gives mute an optional minutes argument and the others none" do
      mute = described_class.find("mute")
      expect(mute.arguments.map(&:name)).to eq(["minutes"])
      expect(mute.arguments.first.type).to eq(:integer)
      expect(mute.arguments.first.required?).to be(false)

      expect(described_class.find("ban").arguments).to be_empty
    end

    # Both sweeping verbs take a room rather than acting on one message: one an
    # operator names, or every room in the community.
    it "gives each sweeping verb an optional room argument" do
      %w[unpin clean].each do |name|
        room = described_class.find(name).arguments
        expect(room.map(&:name)).to eq(["room"]), "#{name} takes #{room.map(&:name).inspect}"
        expect(room.first.required?).to be(false)
        expect(room.first).not_to be_keyed
      end
    end
  end

  describe "audiences" do
    it "treats every moderation verb as a moderator command" do
      expect(described_class.moderation_specs).to all(satisfy(&:moderator?))
    end

    it "treats /find as a public command any member may run" do
      expect(described_class.find("find").everyone?).to be(true)
    end

    it "gives a moderator every command and a non-moderator only the everyone ones" do
      expect(described_class.for_audience(moderator: true)).to eq(described_class.all)
      non_mod = described_class.for_audience(moderator: false)
      expect(non_mod).to all(satisfy(&:everyone?))
      expect(non_mod.map(&:name)).to include("find")
    end
  end

  describe ".find" do
    it "resolves a name with or without a leading slash" do
      expect(described_class.find("delete").name).to eq("delete")
      expect(described_class.find("/delete").name).to eq("delete")
    end

    it "is nil for an unknown command" do
      expect(described_class.find("frobnicate")).to be_nil
      expect(described_class.known?("frobnicate")).to be(false)
    end
  end

  # A Telegram BotCommand name admits no hyphen, so "identify-topic" reaches the
  # "/" menu underscored and a member who picks it there types the underscored
  # form. The registry owns the rule so every surface agrees on it.
  describe ".canonical" do
    it "treats an underscore and a hyphen as the same separator" do
      expect(described_class.canonical("identify_topic")).to eq("identify-topic")
      expect(described_class.canonical("identify-topic")).to eq("identify-topic")
    end

    it "strips a prefix marker, a Telegram @botname suffix and the case" do
      expect(described_class.canonical("/Identify_Topic@thebridgebot")).to eq("identify-topic")
      expect(described_class.canonical("!DELETE")).to eq("delete")
    end

    it "hands back an unknown word bare, so a caller can still tell it is not a command" do
      expect(described_class.canonical("frobnicate")).to eq("frobnicate")
      expect(described_class.canonical("not_a_command")).to eq("not_a_command")
    end

    it "leaves a name that is already canonical alone rather than hyphenating it" do
      expect(described_class.canonical("rsvp")).to eq("rsvp")
    end

    it "resolves the underscored spelling through .find, so a menu pick reaches the spec" do
      expect(described_class.find("identify_topic")&.name).to eq("identify-topic")
      expect(described_class.known?("/identify_topic@thebridgebot")).to be(true)
    end
  end

  describe "an acknowledgement phrase" do
    it "carries the verb's gerund so a reply reads 'Acknowledged, deleting this message.'" do
      expect(described_class.find("delete").acknowledgement).to eq("deleting this message")
    end
  end

  # /nickname and /operator parsed their own COMMAND word directly without ever
  # gaining a Spec, so {Features::DisabledCommandNotice} never fired for them
  # and the raw text reached {Bridge} instead. This walks every feature class
  # that owns a COMMAND constant and fails loudly if one is missing an entry.
  describe "every command feature with a COMMAND constant" do
    it "has a matching registry entry" do
      classes = Rubotty::Features.constants.filter_map do |name|
        klass = Rubotty::Features.const_get(name)
        klass if klass.is_a?(Class) && klass.const_defined?(:COMMAND, false)
      end
      expect(classes).not_to be_empty

      unknown = classes.reject { |klass| described_class.known?(klass.const_get(:COMMAND).to_s) }
      expect(unknown).to be_empty, "no registry entry for: #{unknown.map(&:name).join(", ")}"
    end
  end
  # An operator reading an alert on a phone finds the verb by typing a slash,
  # which only happens if the client's menu carries it.
  describe "the console's own verbs" do
    it "registers vindicate and innocent against content policy" do
      %w[vindicate innocent].each do |name|
        spec = described_class.find(name)
        expect(spec).not_to be_nil, "#{name} is not registered"
        expect(spec.feature).to eq("content_policy")
      end
    end

    it "marks them direct, since the console answers them in a DM" do
      expect(described_class.find("vindicate")).to be_direct
      expect(described_class.find("vindicate")).not_to be_room
    end

    # A slash command a client dispatches into a channel would reach nothing,
    # so every in-room surface reads room_commands instead of all.
    it "holds them out of the room surface while keeping them in the menu" do
      expect(described_class.room_commands.map(&:name)).not_to include("vindicate")
      expect(described_class.for_audience(moderator: true).map(&:name)).to include("vindicate")
      expect(described_class.for_audience(moderator: true, surface: :room).map(&:name))
        .not_to include("vindicate")
    end

    it "keeps them off a non-operator's list, since only an operator reverses one" do
      expect(described_class.for_audience(moderator: false).map(&:name)).not_to include("vindicate")
    end

    it "leaves every other command on the room surface" do
      expect(described_class.room_commands.length).to eq(described_class.all.length - 2)
    end
  end

end
