# frozen_string_literal: true

require "spec_helper"

# Message actions act on the replied message and user actions on its author,
# which is why both are issued as replies.
RSpec.describe "moderation verbs" do
  let(:http) { Fakes::TelegramHttp.new }
  let(:place) do
    endpoint("tg", adapter: :telegram, settings: { chat_id: "-1008000000001" })
  end
  let(:adapter) do
    Rubotty::Adapters::Telegram::Adapter.new(
      account: "tg", settings: { token: "t", token_env: "TG" },
      dispatcher: Fakes::RecordingDispatcher.new, logger: Rubotty::Log.null,
      endpoints: [place]
    ).replace_client(Rubotty::Adapters::Telegram::ApiClient.new(token: "t", http: http))
  end
  let(:operator) { Rubotty::Core::Moderation::Operator.new(name: "Alex") }

  def command(action, target_user_id: "55", arguments: [])
    Rubotty::Core::Moderation::Command.new(
      action: action, issuer: operator, origin: place,
      target_user_id: target_user_id, arguments: arguments
    )
  end

  describe "Telegram" do
    it "declares every verb it implements" do
      %i[delete ban unban kick mute unmute pin unpin unpinall].each do |action|
        expect(adapter.capabilities.moderates?(action)).to be(true)
      end
    end

    it "bans a member" do
      expect(adapter.moderate(command(:ban), place, nil).status).to eq(:done)
      expect(http.last("banChatMember").params["user_id"]).to eq(55)
    end

    # Telegram has no kick: it is a ban immediately followed by an unban, which
    # removes the member while leaving them able to rejoin.
    it "kicks by banning and immediately unbanning" do
      expect(adapter.moderate(command(:kick), place, nil).status).to eq(:done)
      expect(http.called?("banChatMember")).to be(true)
      expect(http.last("unbanChatMember").params["only_if_banned"]).to be(true)
    end

    it "mutes by removing every send permission" do
      adapter.moderate(command(:mute), place, nil)
      permissions = http.last("restrictChatMember").params["permissions"]
      expect(permissions.values.uniq).to eq([false])
    end

    # restrictChatMember replaces the whole permission set, so unmuting has to
    # hand every permission back rather than clearing one flag.
    it "unmutes by restoring every permission" do
      adapter.moderate(command(:unmute), place, nil)
      permissions = http.last("restrictChatMember").params["permissions"]
      expect(permissions.values.uniq).to eq([true])
    end

    # only_if_banned makes lifting an already-gone ban a no-op, which is how a
    # temp-ban reverses itself when its sanction expires.
    it "unbans a member" do
      expect(adapter.moderate(command(:unban), place, nil).status).to eq(:done)
      expect(http.last("unbanChatMember").params["user_id"]).to eq(55)
      expect(http.last("unbanChatMember").params["only_if_banned"]).to be(true)
    end

    it "pins and unpins a message" do
      adapter.moderate(command(:pin), place, "900")
      expect(http.last("pinChatMessage").params["message_id"]).to eq(900)
      adapter.moderate(command(:unpin), place, "900")
      expect(http.last("unpinChatMessage").params["message_id"]).to eq(900)
    end

    # One call takes the whole chat's pins, this bot's and everyone else's,
    # and Telegram offers nothing to read them back with first.
    it "clears every pin in the chat without naming a message" do
      expect(adapter.moderate(command(:unpinall), place, nil).status).to eq(:done)
      expect(http.last("unpinAllChatMessages").params["chat_id"]).to eq("-1008000000001")
    end

    it "reports a permission failure as forbidden rather than as an error" do
      http.error_on("banChatMember", code: 403, description: "Forbidden: not enough rights")
      expect(adapter.moderate(command(:ban), place, nil).status).to eq(:forbidden)
    end

    it "reports an unknown action as unsupported" do
      expect(adapter.moderate(command(:obliterate), place, nil).status).to eq(:unsupported)
    end
  end

  describe "resolving the target person across platforms" do
    let(:tg) { endpoint("tg", adapter: :telegram) }
    let(:dc) { endpoint("dc", adapter: :discord) }
    let(:storage) { Rubotty::Storage::Memory.new }
    let(:recorder) { Fakes::ReactingAdapter.new }
    let(:alex) do
      Rubotty::Core::Moderation::Operator.new(name: "Alex", identities: { telegram: ["1"] })
    end
    let(:troll) do
      Rubotty::Core::Person.new(name: "Troll", identities: { telegram: ["99"], discord: ["777"] })
    end

    def route(people:)
      commands = Rubotty::Core::Commands.new(actions: %i[delete ban], logger: Rubotty::Log.null)
      router = Rubotty::Core::Router.new(
        topology: topology(room("r", tg, dc)), adapters: Hash.new(recorder), storage: storage,
        loop_guard: Rubotty::Core::LoopGuard.new(storage: storage),
        logger: Rubotty::Log.null, commands: commands,
        operators: Rubotty::Core::Moderation::Directory.new([alex]),
        people: Rubotty::Core::Directory.new(people)
      )
      preview = Rubotty::Core::ReplyPreview.new(
        author: author(native_id: "99", username: "troll"),
        body: Rubotty::Core::RichText.plain("something rude")
      )
      router.handle(
        message(tg, text: "/ban", native_id: "1000", author: author(native_id: "1"),
                    reply_to: ref("tg", "900"), reply_preview: preview)
      )
    end

    it "uses the identity map to find the same person on the other platform" do
      route(people: [troll])
      expect(recorder.moderations.map { |m| m[:endpoint_id] }).to include("dc")
    end

    # Guessing here would risk banning an unrelated account that happens to
    # share a numeric id.
    it "refuses to act on a platform where the person is unknown" do
      results = route(people: [])
      remote = results.find { |r| r.endpoint_id == "dc" }
      expect(remote.status).to eq(:not_found)
      expect(remote.detail).to include("no known account")
    end

    it "still acts on the platform the command came from" do
      route(people: [])
      expect(recorder.moderations.map { |m| m[:endpoint_id] }).to eq(["tg"])
    end
  end

  describe "issuing them" do
    let(:tg) { endpoint("tg") }
    let(:alex) do
      Rubotty::Core::Moderation::Operator.new(name: "Alex", identities: { fake: ["55"] })
    end
    let(:commands) do
      Rubotty::Core::Commands.new(actions: Rubotty::Core::Moderation::ACTIONS, logger: Rubotty::Log.null)
    end

    let(:directory) { Rubotty::Core::Moderation::Directory.new([alex]) }

    def parse(text, reply_to: ref("tg", "900"), preview: nil)
      commands.parse(
        message(tg, text: text, author: author(native_id: "55"),
                    reply_to: reply_to, reply_preview: preview),
        directory: directory
      )
    end

    it "captures the replied author as the target of a user action" do
      preview = Rubotty::Core::ReplyPreview.new(author: author(native_id: "99", username: "troll"))
      expect(parse("/ban", preview: preview).target_user.native_id).to eq("99")
    end

    it "refuses a user action issued without replying to anybody" do
      expect(parse("/ban", reply_to: nil)).to be_a(Rubotty::Core::Commands::Refusal)
    end

    it "passes arguments through, so a mute can carry a duration" do
      expect(parse("/mute 30").arguments).to eq(["30"])
    end

    it "knows which actions need a message and which need a person" do
      expect(parse("/pin").needs_target_message?).to be(true)
      expect(parse("/ban").needs_target_user?).to be(true)
    end

    it "recognises a command under the alternate ! prefix as well as /" do
      preview = Rubotty::Core::ReplyPreview.new(author: author(native_id: "99", username: "troll"))
      expect(parse("!ban", preview: preview).action).to eq(:ban)
      expect(parse("!ban", preview: preview).target_user.native_id).to eq("99")
      expect(parse("/ban", preview: preview).action).to eq(:ban)
    end

    it "leaves an unknown prefixed token alone under every marker, so it relays normally" do
      expect(parse("!notacommand")).to be_nil
      expect(parse("/notacommand")).to be_nil
    end

    it "honours a restricted prefix set: with only /, ! is not a command" do
      slash_only = Rubotty::Core::Commands.new(
        prefixes: ["/"], actions: Rubotty::Core::Moderation::ACTIONS, logger: Rubotty::Log.null
      )
      reply = ref("tg", "900")
      slash_msg = message(tg, text: "!delete", author: author(native_id: "55"), reply_to: reply)
      expect(slash_only.parse(slash_msg, directory: directory)).to be_nil
      slash_ok = message(tg, text: "/delete", author: author(native_id: "55"), reply_to: reply)
      expect(slash_only.parse(slash_ok, directory: directory)).to be_a(Rubotty::Core::Moderation::Command)
    end
  end
end
