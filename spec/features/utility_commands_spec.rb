# frozen_string_literal: true

require "spec_helper"

# The public command surface: a recognised command posts one self-deleting reply and swallows
# the invocation, and anything else falls through so the bridge relays it.
module UtilityCommandsSupport
end

RSpec.describe Rubotty::Features::UtilityCommands do
  let(:tg) { endpoint("tg") }
  let(:adapter) { Fakes::ReactingAdapter.new }
  let(:adapters) { Hash.new(adapter) }
  let(:scheduler) { Rubotty::Core::Scheduler.new(logger: Rubotty::Log.null) }
  let(:ephemeral) do
    Rubotty::Core::EphemeralMessage.new(
      adapters: adapters, session_id: "s", topology: topology(room("r", tg)), logger: Rubotty::Log.null
    )
  end

  # A stand-in for ControlPlane::IdentityDirectory: it records the search it was asked
  # to run and returns whatever rows the test configured.
  UtilityCommandsSupport::Row = Struct.new(:adapter, :native_id, :username, :display_name, keyword_init: true)

  # Fluxer's shape: no API to publish a command list into, and a client that
  # takes "/" for its own fixed menu before the bot ever sees it.
  class MenulessAdapter < Fakes::ReactingAdapter
    CAPABILITIES = Rubotty::Adapters::Capabilities.new(
      edits: true, deletes: true, replies: true,
      command_list: false, reserved_command_prefixes: ["/"]
    ).freeze

    def capabilities = CAPABILITIES
  end

  # Telegram and Discord's shape: the commands are already in a native picker.
  class PickerAdapter < Fakes::ReactingAdapter
    CAPABILITIES = Rubotty::Adapters::Capabilities.new(
      edits: true, deletes: true, replies: true, command_list: true
    ).freeze

    def capabilities = CAPABILITIES
  end

  let(:directory_rows) { [] }
  let(:directory) do
    rows = directory_rows
    calls = search_calls
    Class.new do
      define_method(:search) do |community_id:, query:, limit: nil|
        calls << { community_id: community_id, query: query, limit: limit }
        rows
      end
    end.new
  end
  let(:search_calls) { [] }

  # A real Snapshot::Community rather than a bare id stand-in, so
  # #command_prefixes (feature_config off the shared "commands" scope) has
  # something real to resolve against. +prefixes+ configures that shared
  # marker the same way an operator would through the dashboard.
  def community_with(prefixes: nil, operators: Rubotty::Core::Moderation::Directory.new)
    settings = prefixes.nil? ? [] : [
      Rubotty::ControlPlane::Snapshot::FeatureSetting.new(
        feature: Rubotty::Core::CommandPrefix::CONFIG_FEATURE, enabled: true, config: { "prefixes" => prefixes }
      )
    ]
    Rubotty::ControlPlane::Snapshot::Community.new(
      id: "c1", slug: "c1", name: "c1", status: "active", settings: {},
      topology: Rubotty::Core::Topology.new([]), channels: [],
      operators: operators, people: Rubotty::Core::Directory.new,
      feature_settings: settings
    )
  end

  let(:community) { community_with }

  def feature(identity_directory: directory)
    described_class.new(
      topology: topology(room("r", tg)), adapters: adapters, logger: Rubotty::Log.null,
      ephemeral: ephemeral, cleanup: scheduler, identity_directory: identity_directory
    )
  end

  def context(text, config: {}, community: self.community)
    Rubotty::Features::Context.new(
      message: message(tg, text: text, author: author(native_id: "u1")),
      config: config, community: community
    )
  end

  def last_reply = adapter.delivered_to("tg").last&.body&.text

  after { scheduler.stop }

  describe "the contract" do
    it "names itself, is off by default, observes only chat, and publishes a schema" do
      expect(described_class.feature_name).to eq("utility_commands")
      expect(described_class.default_enabled?).to be(false)
      expect(described_class.observes).to eq(%i[chat])
      expect(described_class.config_schema).to be_a(Rubotty::Config::Schema)
    end

    it "leaves an ordinary message alone so the bridge relays it" do
      outcome = feature.call(context("just chatting"))
      expect(outcome.halt?).to be(false)
    end

    it "leaves an unknown command alone" do
      outcome = feature.call(context("/wat"))
      expect(outcome.halt?).to be(false)
    end
  end

  describe "/find" do
    let(:directory_rows) do
      [
        UtilityCommandsSupport::Row.new(adapter: "discord", native_id: "9", username: "owner_handle", display_name: "Bob"),
        UtilityCommandsSupport::Row.new(adapter: "telegram", native_id: "7", username: "sparky123", display_name: "Alice")
      ]
    end

    it "lists the matches as handle@platform [Display], and swallows the command" do
      outcome = feature.call(context("/find owner"))

      expect(outcome.halt?).to be(true)
      expect(last_reply).to eq(
        "Matches for \"owner\":\nowner_handle@discord [Bob]\nsparky123@telegram [Alice]"
      )
    end

    it "searches only this community, passing the community id and limit through" do
      feature.call(context("/find owner", config: { find_limit: 5 }))
      expect(search_calls).to eq([{ community_id: "c1", query: "owner", limit: 5 }])
    end

    it "honours an alternate prefix, so !find works where / is reserved" do
      feature.call(context("!find owner"))
      expect(search_calls.first[:query]).to eq("owner")
    end

    it "says so when nobody matches" do
      feature(identity_directory: empty_directory).call(context("/find ghost"))
      expect(last_reply).to eq("No one matching \"ghost\" has been seen in this community.")
    end

    it "shows usage when no query is given" do
      feature.call(context("/find"))
      expect(last_reply).to eq("Usage: /find <name or handle>")
    end

    it "falls back to the native id when a handle was never observed" do
      feature(identity_directory: one_row(UtilityCommandsSupport::Row.new(adapter: "irc", native_id: "nick!host", username: nil,
                                                   display_name: nil))).call(context("/find nick"))
      expect(last_reply).to eq("Matches for \"nick\":\nnick!host@irc")
    end

    it "does not claim the command when /find is disabled for the community" do
      outcome = feature.call(context("/find owner", config: { find_enabled: false }))
      expect(outcome.halt?).to be(false)
      expect(adapter.delivered).to be_empty
    end

    it "reports nothing to search without a control-plane directory" do
      feature(identity_directory: nil).call(context("/find owner", community: nil))
      expect(last_reply).to eq("No one matching \"owner\" has been seen in this community.")
    end
  end

  describe "/platforms" do
    let(:links) do
      [
        { platform: "discord", label: "Our Discord", url: "https://discord.gg/abc" },
        { platform: "telegram", label: "Telegram group", url: "https://t.me/xyz" }
      ]
    end

    it "lists the OTHER platforms' join links and swallows the command" do
      # The message arrives on :fake, so both configured platforms are other ends and appear.
      outcome = feature.call(context("/platforms", config: { platforms: links }))

      expect(outcome.halt?).to be(true)
      expect(last_reply).to eq(
        "Join this community on:\n- Our Discord: https://discord.gg/abc\n- Telegram group: https://t.me/xyz"
      )
    end

    it "excludes the platform the command was issued on" do
      tg_origin = endpoint("tg", adapter: :discord)
      ctx = Rubotty::Features::Context.new(
        message: message(tg_origin, text: "/platforms", author: author(native_id: "u1")),
        config: { platforms: links }, community: community
      )
      feature.call(ctx)
      expect(last_reply).to eq("Join this community on:\n- Telegram group: https://t.me/xyz")
    end

    it "defaults a missing label to the platform name and drops an entry with no url" do
      config = { platforms: [{ platform: "matrix", url: "https://matrix.to/#/room" }, { platform: "irc" }] }
      feature.call(context("/platforms", config: config))
      expect(last_reply).to eq("Join this community on:\n- Matrix: https://matrix.to/#/room")
    end

    it "says nothing is linked yet rather than staying quiet when no links are configured" do
      outcome = feature.call(context("/platforms"))
      expect(outcome.halt?).to be(true)
      expect(last_reply).to eq("Nothing is linked here yet.")
    end
  end

  describe "/help" do
    let(:operator) { Rubotty::Core::Moderation::Operator.new(name: "Op", identities: { fake: ["u1"] }) }
    let(:directory) { Rubotty::Core::Moderation::Directory.new([operator]) }

    # The scope carries the directory: a permission check reads the community's
    # own and nothing beside it.
    def context_with(text, operators:)
      Rubotty::Features::Context.new(
        message: message(tg, text: text, author: author(native_id: "u1")),
        config: {}, community: community_with(operators: operators || Rubotty::Core::Moderation::Directory.new)
      )
    end

    it "responds to everyone and swallows the command" do
      outcome = feature.call(context_with("/help", operators: nil))
      expect(outcome.halt?).to be(true)
      expect(last_reply).to start_with("Commands you can use:")
    end

    it "gives an operator the full list, moderation verbs and public commands" do
      feature.call(context_with("/help", operators: directory))

      expect(last_reply).to include("/delete [when] - Delete the target message")
      expect(last_reply).to include("/ban - Ban a member")
      expect(last_reply).to include("/find <query> - Find who to @mention")
      expect(last_reply).to include("/platforms - Show this community's other platforms")
      expect(last_reply).to include("/help - List the commands you can use here.")
    end

    it "gives a regular member the public commands plus their own self-delete" do
      feature.call(context_with("/help", operators: directory_without_u1))

      expect(last_reply).to include("/find <query> - Find who to @mention")
      expect(last_reply).to include("/platforms - Show this community's other platforms")
      expect(last_reply).to include("/delete - reply to your own message to delete it everywhere.")
      expect(last_reply).not_to include("Ban a member")
    end

    it "self-deletes on the standard TTL like the other replies" do
      feature.call(context_with("/help", operators: nil))
      expect(scheduler.pending).to eq(1)
    end

    it "keeps printing \"/\" on a platform that reserves no marker" do
      feature.call(context_with("/help", operators: nil))

      expect(last_reply).to include("/help - List the commands you can use here.")
      expect(last_reply).not_to include("!help -")
    end

    it "honours the community's own shared command marker" do
      feature.call(
        Rubotty::Features::Context.new(
          message: message(tg, text: "?help", author: author(native_id: "u1")),
          config: {}, community: community_with(prefixes: ["?"]), operators: nil
        )
      )

      expect(last_reply).to include("?help - List the commands you can use here.")
    end
  end

  # Fluxer has no application-command API and its own client eats "/", so the only way a
  # member finds the commands is the listing and the pointer, both of which have to print
  # the marker that actually arrives.
  describe "a platform whose client eats \"/\"" do
    let(:fx) { endpoint("fx", adapter: :fluxer, settings: { channel_id: "111111111" }) }
    let(:adapter) { MenulessAdapter.new }

    def fluxer_feature
      described_class.new(
        topology: topology(room("r", fx)), adapters: adapters, logger: Rubotty::Log.null,
        ephemeral: ephemeral, cleanup: scheduler, identity_directory: directory
      )
    end

    def fluxer_context(text)
      Rubotty::Features::Context.new(
        message: message(fx, text: text, author: author(native_id: "u1")),
        config: {}, community: community, operators: nil
      )
    end

    def fluxer_reply = adapter.delivered_to("fx").last&.body&.text

    it "answers a Fluxer-origin /help, since the text path reaches it like any other" do
      outcome = fluxer_feature.call(fluxer_context("/help"))

      expect(outcome.halt?).to be(true)
      expect(fluxer_reply).to start_with("Commands you can use:")
    end

    it "answers a Fluxer-origin !help the same way" do
      outcome = fluxer_feature.call(fluxer_context("!help"))

      expect(outcome.halt?).to be(true)
      expect(fluxer_reply).to start_with("Commands you can use:")
    end

    it "prints the marker that arrives rather than the one the client swallows" do
      fluxer_feature.call(fluxer_context("!help"))

      expect(fluxer_reply).to include("!help - List the commands you can use here.")
      expect(fluxer_reply).to include("!find <query> - Find who to @mention")
      expect(fluxer_reply).to include("!delete - reply to your own message to delete it everywhere.")
      expect(fluxer_reply).not_to include("/help -")
    end

    it "prints it in the /find usage line too" do
      fluxer_feature.call(fluxer_context("!find"))

      expect(fluxer_reply).to eq("Usage: !find <name or handle>")
    end
  end

  # There is no menu to publish into on a platform like Fluxer, so the channel is told once
  # where the commands are.
  describe "the help pointer" do
    let(:fx) { endpoint("fx", adapter: :fluxer, settings: { channel_id: "111111111" }) }
    let(:adapter) { MenulessAdapter.new }

    def fluxer_feature(help_pointer: nil)
      described_class.new(
        topology: topology(room("r", fx)), adapters: adapters, logger: Rubotty::Log.null,
        ephemeral: ephemeral, cleanup: scheduler, identity_directory: directory,
        help_pointer: help_pointer
      )
    end

    def chat(text, config: {})
      Rubotty::Features::Context.new(
        message: message(fx, text: text, author: author(native_id: "u1")),
        config: config, community: community, operators: nil
      )
    end

    def posted = adapter.delivered_to("fx").map { |sent| sent.body.text }

    it "names the help command with the marker that works there" do
      outcome = fluxer_feature.call(chat("morning all"))

      expect(outcome.halt?).to be(false)
      expect(posted.last).to eq(
        "This channel is bridged by rubotty. Type !help to see what you can ask it to do."
      )
    end

    it "says it once, however much the channel talks" do
      pointer = Rubotty::Core::HelpPointer.new
      feature = fluxer_feature(help_pointer: pointer)
      3.times { |i| feature.call(chat("message #{i}")) }

      expect(posted.size).to eq(1)
    end

    it "leaves it in place rather than self-deleting, so it can be found later" do
      fluxer_feature.call(chat("morning all"))

      expect(scheduler.pending).to eq(0)
    end

    it "stays quiet where the platform publishes its own command list" do
      picker = PickerAdapter.new
      feature = described_class.new(
        topology: topology(room("r", fx)), adapters: Hash.new(picker), logger: Rubotty::Log.null,
        ephemeral: Rubotty::Core::EphemeralMessage.new(
          adapters: Hash.new(picker), session_id: "s", topology: topology(room("r", fx)),
          logger: Rubotty::Log.null
        ),
        cleanup: scheduler, identity_directory: directory
      )
      feature.call(chat("morning all"))

      expect(picker.delivered).to be_empty
    end

    it "stays quiet when the community turns it off" do
      fluxer_feature.call(chat("morning all", config: { help_pointer: false }))

      expect(posted).to be_empty
    end

    it "does not lecture somebody who already typed a command" do
      fluxer_feature.call(chat("!wat"))

      expect(posted).to be_empty
    end
  end

  # The startup banner is off unless a community turns it on, so this is the only way left
  # to ask a running bot what it is.
  describe "/version" do
    let(:operator) { Rubotty::Core::Moderation::Operator.new(name: "Op", identities: { fake: ["u1"] }) }
    let(:directory) { Rubotty::Core::Moderation::Directory.new([operator]) }

    def version_context(operators:)
      Rubotty::Features::Context.new(
        message: message(tg, text: "/version", author: author(native_id: "u1")),
        config: {}, community: community_with(operators: operators || Rubotty::Core::Moderation::Directory.new)
      )
    end

    it "answers anyone with the service, its version and the build" do
      outcome = feature.call(version_context(operators: nil))

      expect(outcome.halt?).to be(true)
      expect(last_reply).to include("rubotty version: #{Rubotty::VERSION}")
    end

    # The point of the tiering: the full banner names the machine, and a member
    # asking what version is running has not asked about the host.
    it "does not describe the machine to a regular member" do
      feature.call(version_context(operators: directory_without_u1))

      expect(last_reply).not_to include("host:")
      expect(last_reply).not_to include("ruby runtime:")
    end

    it "gives an operator the runtime and host lines they need to debug a deploy" do
      feature.call(version_context(operators: directory))

      expect(last_reply).to include("ruby runtime:")
      expect(last_reply).to include("host:")
    end

    # It reports on the process answering, so it must not consult the per
    # community switch that governs the unprompted boot banner.
    it "works whether or not the community turned the startup banner on" do
      feature.call(version_context(operators: nil))

      expect(last_reply).to include("rubotty version:")
    end

    it "self-deletes on the standard TTL like the other replies" do
      feature.call(version_context(operators: nil))

      expect(scheduler.pending).to eq(1)
    end

    it "is listed in /help so somebody can discover it" do
      feature.call(version_context(operators: nil))
      feature.call(
        Rubotty::Features::Context.new(
          message: message(tg, text: "/help", author: author(native_id: "u1")),
          config: {}, community: community, operators: nil
        )
      )

      expect(last_reply).to include("/version - Show what version of rubotty is running here.")
    end
  end

  describe "the reply TTL" do
    let(:directory_rows) { [UtilityCommandsSupport::Row.new(adapter: "discord", native_id: "9", username: "owner", display_name: nil)] }

    it "schedules the reply's self-delete after the configured ack_ttl_seconds" do
      feature.call(context("/find owner", config: { ack_ttl_seconds: 45 }))
      expect(scheduler.pending).to eq(1)
    end

    it "defaults to the standard 30s when the scope sets nothing" do
      feature.call(context("/find owner"))
      expect(scheduler.pending).to eq(1)
    end

    it "leaves the reply in place when the scope sets 0" do
      feature.call(context("/find owner", config: { ack_ttl_seconds: 0 }))
      expect(scheduler.pending).to eq(0)
      expect(last_reply).to include("owner@discord")
    end
  end

  # An operator directory without u1, so the asker resolves to a regular member.
  def directory_without_u1
    other = Rubotty::Core::Moderation::Operator.new(name: "Someone", identities: { fake: ["999"] })
    Rubotty::Core::Moderation::Directory.new([other])
  end

  def empty_directory
    Class.new { def search(**) = [] }.new
  end

  def one_row(row)
    Class.new { define_method(:search) { |**| [row] } }.new
  end
end
