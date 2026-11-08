# frozen_string_literal: true

require "spec_helper"
require "stringio"

# Publishing the bot's commands so typing "/" suggests them, built from the same
# neutral Core::CommandRegistry the Discord side registers from.
RSpec.describe Rubotty::Adapters::Telegram::Commands do
  let(:http) { Fakes::TelegramHttp.new }
  let(:client) { Rubotty::Adapters::Telegram::ApiClient.new(token: "123:abc", http: http) }
  # A real logger over a string, so the "logged, never fatal" claims below can be
  # checked against what actually gets written.
  let(:logs) { StringIO.new }
  let(:logger) { Rubotty::Log.build(level: "debug", io: logs) }

  subject(:commands) { described_class.new(client: client, logger: logger) }

  # Stands in for Core::CommandRegistry so a limit can be provoked. Anonymous
  # because a constant declared in an example group lands on Object and collides
  # with the next spec file that picks the same name.
  def fake_registry(specs)
    Class.new do
      define_method(:all) { specs }
      define_method(:for_audience) do |moderator:, surface: nil|
        chosen = moderator ? specs : specs.select(&:everyone?)
        surface.nil? ? chosen : chosen.select { |spec| spec.surface == surface }
      end
    end.new
  end

  def definitions_from(specs)
    described_class.new(client: client, registry: fake_registry(specs), logger: logger)
                   .definitions(moderator: false)
  end

  def payload(index) = http.calls("setMyCommands")[index].params

  def names_for(index) = payload(index)["commands"].map { |command| command["command"] }

  describe "what it publishes" do
    it "sends one setMyCommands per scope" do
      commands.register
      expect(http.calls("setMyCommands").size).to eq(3)
      expect(http.calls("setMyCommands").map { |call| call.params.dig("scope", "type") })
        .to eq(%w[default all_private_chats all_chat_administrators])
    end

    it "gives the default scope only the everyone-commands, so a member is not shown a verb they cannot use" do
      commands.register
      expect(names_for(0)).to include("help", "find", "platforms")
      expect(names_for(0)).not_to include("ban", "delete", "kick", "redirect")
    end

    # Telegram command scopes do not merge: the most specific scope with commands
    # set supplies the whole list, so the administrator scope has to carry the
    # everyone-commands too.
    it "gives the administrator scope the full set, because a more specific scope replaces rather than extends" do
      commands.register
      expect(names_for(2)).to include("ban", "delete", "kick", "redirect")
      expect(names_for(2)).to include("help", "find", "platforms")
      expect(names_for(2)).to include(*names_for(0))
    end

    it "keeps the registry's order, so the moderation verbs lead the administrator menu" do
      commands.register
      expect(names_for(2).first(7)).to eq(%w[delete ban kick mute unmute pin unpin])
    end

    # The bug this scope exists for: all_chat_administrators never covers a
    # private chat, so a moderator verb published only there is invisible in
    # the DM where the console answers it. An operator finds vindicate by
    # typing a slash, or does not find it at all.
    it "offers the console's own verbs in a private chat, where the console lives" do
      commands.register
      expect(names_for(1)).to include("vindicate", "innocent")
    end

    it "keeps the everyone-commands there too, since scopes replace rather than extend" do
      commands.register
      expect(names_for(1)).to include("help", "find", "platforms")
    end

    # A private chat is not where a room verb is typed, and listing every
    # moderation verb to anybody who DMs the bot reads as an invitation.
    it "leaves the room verbs out of a private chat" do
      commands.register
      expect(names_for(1)).not_to include("ban", "kick", "redirect")
    end

    it "never lists a command twice, even where the two sets overlap" do
      commands.register
      expect(names_for(1)).to eq(names_for(1).uniq)
    end

    it "publishes every command the registry declares for that audience" do
      commands.register
      expected = Rubotty::Core::CommandRegistry.all.map { |spec| spec.name.tr("-", "_") }
      expect(names_for(2)).to eq(expected)
    end
  end

  # Telegram rejects the entire setMyCommands call over one malformed entry, so
  # a name or description it will not take must never reach the wire.
  describe "conforming to Telegram's own limits" do
    it "publishes only names Telegram accepts: lowercase, digits and underscores, at most 32" do
      commands.register
      names_for(2).each do |name|
        expect(name).to match(/\A[a-z0-9_]{1,32}\z/), "#{name.inspect} is not a legal Telegram command name"
      end
    end

    it "publishes a hyphenated command underscored, since a Telegram name may not hold a hyphen" do
      commands.register
      expect(names_for(0)).to include("identify_topic")
      expect(names_for(0)).not_to include("identify-topic")
    end

    it "keeps every description inside Telegram's 256 characters" do
      commands.register
      payload(1)["commands"].each do |command|
        expect(command["description"].length).to be_between(1, 256)
      end
    end

    it "truncates a description that would otherwise be rejected, rather than costing every command its place" do
      published = definitions_from([
                                     Rubotty::Core::CommandRegistry::Spec.new(
                                       name: "verbose", description: "x" * 400, audience: :everyone
                                     )
                                   ])
      expect(published.first.description.length).to eq(256)
      expect(published.first.description).to end_with("…")
    end

    it "drops a command whose name cannot be expressed at all, and says so, rather than failing the whole call" do
      published = definitions_from([
                                     Rubotty::Core::CommandRegistry::Spec.new(
                                       name: "sürprise!", description: "Not expressible on Telegram.",
                                       audience: :everyone
                                     )
                                   ])
      expect(published).to be_empty
      expect(logs.string).to match(/cannot be published to telegram/)
    end

    it "drops a name longer than the 32 characters Telegram allows" do
      published = definitions_from([
                                     Rubotty::Core::CommandRegistry::Spec.new(
                                       name: "a" * 33, description: "Too long a name.", audience: :everyone
                                     )
                                   ])
      expect(published).to be_empty
    end

    it "never sends more than the 100 commands Telegram allows, and logs what it left out" do
      specs = Array.new(120) do |index|
        Rubotty::Core::CommandRegistry::Spec.new(
          name: "cmd#{index}", description: "Command #{index}.", audience: :everyone
        )
      end
      published = definitions_from(specs)
      expect(published.size).to eq(100)
      expect(logs.string).to match(/20 were not published/)
    end
  end

  # Telegram gives a command no argument UI at all, so the shape of the
  # invocation has to be visible in the description.
  describe "the usage hint" do
    def description_for(name)
      commands.definitions(moderator: true).find { |d| d.name == name }.description
    end

    it "names a required argument in angle brackets and an optional one in square brackets" do
      expect(description_for("find")).to start_with("<query> - ")
      expect(description_for("mute")).to include("[minutes]")
    end

    it "says to reply, for a command whose target is a message" do
      expect(description_for("pin")).to start_with("reply to a message - ")
    end

    it "says to reply to the person, for a command whose target is a member" do
      expect(description_for("ban")).to start_with("reply to that person - ")
    end

    it "puts the target before the arguments, in the order they are typed" do
      expect(description_for("redirect")).to start_with("reply to a message <channel> - ")
      expect(description_for("delete")).to start_with("reply to a message [when] - ")
    end

    it "leaves a command that takes nothing as its plain description" do
      expect(description_for("help")).to eq("List the commands you can use here.")
    end

    it "carries the registry's own wording rather than a second copy of it" do
      expect(description_for("platforms")).to eq(Rubotty::Core::CommandRegistry.find("platforms").description)
    end
  end

  describe "when Telegram will not take the list" do
    it "logs a rejection and carries on, because a cosmetic menu is not worth failing a boot over" do
      http.error_on("setMyCommands", code: 400, description: "Bad Request: BOT_COMMAND_INVALID")
      expect { commands.register }.not_to raise_error
      expect(logs.string).to match(/could not publish the telegram command list \(default\)/)
    end

    it "still publishes the later scopes after the first is refused" do
      http.error_on("setMyCommands", code: 400, description: "Bad Request: BOT_COMMAND_INVALID")
      commands.register
      expect(http.calls("setMyCommands").size).to eq(3)
      expect(names_for(1)).to include("vindicate")
      expect(names_for(2)).to include("ban")
    end

    it "survives a rate limit, which is retryable but not this call's problem to retry" do
      http.error_on("setMyCommands", code: 429, description: "Too Many Requests",
                                     parameters: { "retry_after" => 5 })
      expect { commands.register }.not_to raise_error
    end
  end
end
