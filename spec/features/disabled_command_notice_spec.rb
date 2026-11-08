# frozen_string_literal: true

require "spec_helper"

# A recognised command word that no other step in the chain served gets an
# actionable reply instead of dead silence, and never carries on to the bridge.
RSpec.describe Rubotty::Features::DisabledCommandNotice do
  let(:tg) { endpoint("tg") }
  let(:adapter) { Fakes::ReactingAdapter.new }
  let(:adapters) { Hash.new(adapter) }
  let(:scheduler) { Rubotty::Core::Scheduler.new(logger: Rubotty::Log.null) }
  let(:ephemeral) do
    Rubotty::Core::EphemeralMessage.new(
      adapters: adapters, session_id: "s", topology: topology(room("r", tg)), logger: Rubotty::Log.null
    )
  end

  def feature
    described_class.new(
      topology: topology(room("r", tg)), adapters: adapters, logger: Rubotty::Log.null,
      ephemeral: ephemeral, cleanup: scheduler
    )
  end

  # A minimal stand-in for Snapshot::Community: only #feature_enabled? and
  # #feature_config (for the shared command marker) are ever read.
  def fake_community(enabled: {}, prefixes: nil)
    Class.new do
      define_method(:initialize) { |flags, prefixes| @flags = flags; @prefixes = prefixes }
      define_method(:feature_enabled?) { |_channel, feature| @flags.fetch(feature, false) }
      define_method(:feature_config) do |_channel, feature|
        feature == Rubotty::Core::CommandPrefix::CONFIG_FEATURE ? (@prefixes || {}) : {}
      end
    end.new(enabled, prefixes)
  end

  def context(text, community: nil)
    Rubotty::Features::Context.new(
      message: message(tg, text: text, author: author(native_id: "u1")),
      config: {}, community: community, channel: nil
    )
  end

  def last_reply = adapter.delivered_to("tg").last&.body&.text

  after { scheduler.stop }

  it "declares itself always_enabled, like IdentifyTopic, unlike every other command feature" do
    expect(described_class.always_enabled?).to be(true)
    expect(described_class.feature_name).to eq("disabled_command_notice")
    expect(described_class.observes).to eq([:chat])
  end

  it "is catalogued for lookup, but not independently toggleable" do
    expect(Rubotty::Features::Catalog.classes).to include(described_class)
    expect(Rubotty::Features::Catalog.class_for("disabled_command_notice").always_enabled?).to be(true)
  end

  # A recognised command is consumed wherever it is recognised, so a disabled feature's verb
  # is answered here and never reaches the bridge.
  it "halts on a command it answers for, keeping the text off the other platforms" do
    community = fake_community(enabled: { "keyword_watch" => false })
    outcome = feature.call(context("/watch aoe3", community: community))
    expect(outcome.halt?).to be(true)
  end

  it "does nothing for ordinary chat text that matches no command word at all" do
    community = fake_community(enabled: {})
    outcome = feature.call(context("just chatting", community: community))
    expect(outcome.halt?).to be(false)
    expect(last_reply).to be_nil
  end

  it "does nothing for a word CommandRegistry does not know (a typo, not a real command)" do
    community = fake_community(enabled: {})
    feature.call(context("/nosuchcommand", community: community))
    expect(last_reply).to be_nil
  end

  # No control plane means no switch to read and no dashboard to send anybody
  # to, but the command still has to be answered rather than relayed.
  it "answers without a resolved community, without blaming a setting" do
    feature.call(context("/watch aoe3", community: nil))
    expect(last_reply).to include("/watch")
    expect(last_reply).not_to include("isn't turned on")
  end

  # Reaching this step at all means the feature that owns the word did not
  # serve it, so the deployment is missing the service behind it.
  it "answers even when the backing feature is enabled here, since nothing above served the word" do
    community = fake_community(enabled: { "keyword_watch" => true })
    feature.call(context("/watch aoe3", community: community))
    expect(last_reply).to include("/watch")
    expect(last_reply).not_to include("isn't turned on")
  end

  it "answers for /identify-topic, which can never be off, without claiming it is" do
    community = fake_community(enabled: {})
    feature.call(context("/identify-topic Lisbon Meetup", community: community))
    expect(last_reply).to include("/identify-topic")
    expect(last_reply).not_to include("isn't turned on")
  end

  # Moderation's verbs were held back on the grounds that answering told a
  # non-operator which verbs exist. The clients publish that list in their own
  # command menu, so the silence protected nothing and only looked like a
  # broken bot.
  it "names moderation for a verb typed where moderation is switched off" do
    community = fake_community(enabled: { "moderation" => false })
    feature.call(context("/delete", community: community))
    expect(last_reply).to include("/delete")
    expect(last_reply).to include(Rubotty::Features::Moderation.description)
  end

  it "answers the Telegram menu spelling of a moderation verb too" do
    community = fake_community(enabled: { "moderation" => false })
    feature.call(context("/delete@rubotty_telegram_bot", community: community))
    expect(last_reply).to include("/delete")
  end

  # The word this parses has to agree with whatever marker the disabled feature
  # itself would have recognised, or the notice fires on the wrong text (or not
  # at all) once a community moves off the hardcoded default.
  describe "reading the same shared marker as the feature it is describing" do
    it "recognises the community's own configured marker, not just the hardcoded default" do
      community = fake_community(enabled: { "keyword_watch" => false }, prefixes: { "prefixes" => ["#"] })
      feature.call(context("#watch aoe3", community: community))
      expect(last_reply).to include("/watch")
    end

    it "no longer answers on the hardcoded default once the community moves off it" do
      community = fake_community(enabled: { "keyword_watch" => false }, prefixes: { "prefixes" => ["#"] })
      feature.call(context("/watch aoe3", community: community))
      expect(last_reply).to be_nil
    end
  end

  describe "the command-word to feature_name mapping, when the backing feature is disabled" do
    it "names keyword_watch for /watch" do
      community = fake_community(enabled: { "keyword_watch" => false })
      feature.call(context("/watch aoe3 4h", community: community))
      expect(last_reply).to include("/watch")
      expect(last_reply).to include(Rubotty::Features::KeywordWatch.description)
      expect(last_reply).to include("dashboard's Features page")
    end

    it "recognises the alternate ! prefix too" do
      community = fake_community(enabled: { "keyword_watch" => false })
      feature.call(context("!watch aoe3 4h", community: community))
      expect(last_reply).to include("/watch")
    end

    it "names events for /event" do
      community = fake_community(enabled: { "events" => false })
      feature.call(context('/event title="Raid" start="2026-08-01 20:00" tz=Europe/Lisbon kind=gaming',
                            community: community))
      expect(last_reply).to include("/event")
      expect(last_reply).to include(Rubotty::Features::Events.description)
    end

    it "names events for /rsvp too, sharing Events' own feature_name" do
      community = fake_community(enabled: { "events" => false })
      feature.call(context("/rsvp 5 yes", community: community))
      expect(last_reply).to include("/rsvp")
      expect(last_reply).to include(Rubotty::Features::Events.description)
    end

    it "names utility_commands for /find" do
      community = fake_community(enabled: { "utility_commands" => false })
      feature.call(context("/find ada", community: community))
      expect(last_reply).to include("/find")
      expect(last_reply).to include(Rubotty::Features::UtilityCommands.description)
    end

    it "names utility_commands for /help" do
      community = fake_community(enabled: { "utility_commands" => false })
      feature.call(context("/help", community: community))
      expect(last_reply).to include("/help")
      expect(last_reply).to include(Rubotty::Features::UtilityCommands.description)
    end

    it "names utility_commands for /platforms" do
      community = fake_community(enabled: { "utility_commands" => false })
      feature.call(context("/platforms", community: community))
      expect(last_reply).to include("/platforms")
      expect(last_reply).to include(Rubotty::Features::UtilityCommands.description)
    end

    # Previously nickname and operator had no Spec at all, so CommandRegistry.known?
    # was false for both and this feature never fired: the raw command text fell
    # straight through to Bridge and got relayed as plain chat instead.
    it "names nickname for /nickname" do
      community = fake_community(enabled: { "nickname" => false })
      feature.call(context("/nickname Sam", community: community))
      expect(last_reply).to include("/nickname")
      expect(last_reply).to include(Rubotty::Features::Nickname.description)
    end

    it "names operator_requests for /operator" do
      community = fake_community(enabled: { "operator_requests" => false })
      feature.call(context("/operator request", community: community))
      expect(last_reply).to include("/operator")
      expect(last_reply).to include(Rubotty::Features::OperatorRequests.description)
    end
  end
end

# The map used to be hand kept and fell three commands behind: /redirect,
# /upload and /guest were all swallowed in silence when their feature was off.
# It is derived from the registry now, so these examples are about the derivation
# staying honest rather than about the list staying long.
RSpec.describe Rubotty::Features::DisabledCommandNotice, "the command to feature map" do
  let(:map) { described_class.command_features }

  it "covers every command whose feature an operator can switch off" do
    togglable = Rubotty::Core::CommandRegistry.room_commands.select do |spec|
      spec.feature && Rubotty::Features::Catalog.names.include?(spec.feature) &&
        !Rubotty::Features::Catalog.class_for(spec.feature)&.always_enabled?
    end

    expect(map.keys).to include(*togglable.map(&:name).map(&:to_s))
  end

  # The moderation verbs, held out of the map until the client command menus
  # made the silence pointless.
  it "covers every moderation verb" do
    verbs = Rubotty::Core::Moderation::TYPED_ACTIONS.map(&:to_s)

    expect(map.values_at(*verbs)).to all(eq("moderation"))
  end

  # Words a feature answers itself without ever gaining a registry Spec, which
  # is the other way one used to reach the bridge as chat.
  it "covers the words a feature declares for itself" do
    expect(map).to include("whitelist" => "moderated_room", "unwhitelist" => "moderated_room",
                           "debug-lua" => "scripts", "end" => "redirection")
  end

  # The three the hand kept list had lost.
  it "covers the commands that were falling through" do
    expect(map).to include("redirect" => "redirection", "upload" => "file_rehosting",
                           "guest" => "guest_portal")
  end

  # #1884: the client owns start and stop in a private chat, and the DM control
  # lanes answer them there. Nothing in the pipeline publishes either word, so
  # this notice never speaks for one and the two cannot both reply.
  it "claims neither of the words the client reserves in a private chat" do
    %w[start stop].each do |word|
      expect(map).not_to have_key(word)
      expect(Rubotty::Core::CommandRegistry.known?(word)).to be(false)
    end
  end

  # Naming a feature nobody can turn off would have the notice say something
  # that is never true.
  it "names only features that exist and can be turned off" do
    map.each_value do |feature|
      expect(Rubotty::Features::Catalog.names).to include(feature)
      expect(Rubotty::Features::Catalog.class_for(feature).always_enabled?).to be(false)
    end
  end

  # Every command declares its owner, so one added without a feature is caught
  # here rather than going quiet in somebody's room a year later.
  it "leaves only the shared closing word without an owning feature" do
    unowned = Rubotty::Core::CommandRegistry.room_commands.reject(&:feature).map(&:name)

    expect(unowned).to eq(["end"])
  end
end
