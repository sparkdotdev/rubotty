# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Core::Moderation do
  describe Rubotty::Core::Moderation::Operator do
    # Identity is per platform, so modelling the person with identities hanging
    # off them makes revoking access one deletion.
    subject(:operator) do
      described_class.new(
        name: "Alex",
        identities: { telegram: ["55"], discord: %w[900 901] }
      )
    end

    it "recognises a person by their identity on either platform" do
      expect(operator.identity?(:telegram, "55")).to be(true)
      expect(operator.identity?(:discord, "901")).to be(true)
    end

    it "does not recognise an id belonging to a different platform" do
      expect(operator.identity?(:discord, "55")).to be(false)
    end

    it "does not recognise an unknown id" do
      expect(operator.identity?(:telegram, "999")).to be(false)
      expect(operator.identity?(:telegram, nil)).to be(false)
    end

    it "permits every action in every room by default" do
      expect(operator.may?(:delete, "any-room", community_id: 1)).to be(true)
    end

    it "honours a restricted action list" do
      limited = described_class.new(name: "M", identities: { telegram: ["1"] }, actions: [:delete])
      expect(limited.may?(:delete, "r", community_id: 1)).to be(true)
      expect(limited.may?(:ban, "r", community_id: 1)).to be(false)
    end

    it "honours a restricted room list" do
      scoped = described_class.new(name: "M", identities: { telegram: ["1"] }, rooms: ["gaming"])
      expect(scoped.may?(:delete, "gaming", community_id: 1)).to be(true)
      expect(scoped.may?(:delete, "news", community_id: 1)).to be(false)
    end

    # A room key is unique only within one community, so the same key in
    # another one is somebody else's room.
    it "refuses the same room key in another community, and where none is named" do
      scoped = described_class.new(
        name: "M", identities: { telegram: ["1"] }, rooms: ["gaming"], community_id: 1
      )
      expect(scoped.may?(:delete, "gaming", community_id: 1)).to be(true)
      expect(scoped.may?(:delete, "gaming", community_id: 2)).to be(false)
      expect(scoped.may?(:delete, "gaming", community_id: nil)).to be(false)
    end
  end

  describe Rubotty::Core::Moderation::Directory do
    subject(:directory) do
      described_class.new([
                            Rubotty::Core::Moderation::Operator.new(
                              name: "Alex", identities: { telegram: ["55"], discord: ["900"] }
                            )
                          ])
    end

    it "resolves an identity to the person" do
      expect(directory.resolve(:telegram, "55").name).to eq("Alex")
    end

    # Fails closed: no configuration produces a default allow.
    it "returns nobody for an unknown user" do
      expect(directory.resolve(:telegram, "999")).to be_nil
    end

    it "does not authorise temporary IRC or XMPP room nicknames" do
      operator = Rubotty::Core::Moderation::Operator.new(
        name: "Privileged", identities: { irc: ["ada"], xmpp: ["jid:ada@example.org", "ada@example.org"] }
      )
      session_directory = described_class.new([operator], protected_operators: nil)

      expect(session_directory.resolve(:irc, "ada")).to be_nil
      expect(session_directory.resolve(:xmpp, "ada@example.org")).to be_nil
      expect(session_directory.resolve(:xmpp, "jid:ada@example.org")).to be_nil
    end

    it "is empty when nobody is configured, which is what the operator exemptions read" do
      expect(described_class.new.empty?).to be(true)
    end
  end
end

RSpec.describe Rubotty::Core::Commands do
  let(:tg) { endpoint("tg") }
  let(:alex) do
    Rubotty::Core::Moderation::Operator.new(name: "Alex", identities: { fake: ["55"] })
  end
  let(:directory) { Rubotty::Core::Moderation::Directory.new([alex]) }

  subject(:commands) { described_class.new(logger: Rubotty::Log.null) }

  # The directory is handed in per message, since it is the message's own
  # community's; the parser holds none of its own.
  def issue(text, author_id: "55", reply_to: ref("tg", "900"), directory: self.directory)
    commands.parse(
      message(tg, text: text, author: author(native_id: author_id), reply_to: reply_to),
      directory: directory
    )
  end

  it "parses a delete issued by an authorised operator in reply to a message" do
    command = issue("/delete")
    expect(command).to be_a(Rubotty::Core::Moderation::Command)
    expect(command.action).to eq(:delete)
    expect(command.target_ref).to eq(ref("tg", "900"))
    expect(command.issuer).to eq(alex)
  end

  # Telegram appends the bot's username in groups, and its command menu inserts
  # that form, so both spellings have to work.
  it "accepts the form Telegram produces with the bot username attached" do
    expect(issue("/delete@mybridgebot")).to be_a(Rubotty::Core::Moderation::Command)
  end

  it "ignores an ordinary message" do
    expect(issue("just talking")).to be_nil
  end

  it "ignores a word that only looks like a command" do
    expect(issue("/notacommand")).to be_nil
  end

  # A refusal is a value the caller consumes and answers, so the verb never
  # carries on to the bridge as ordinary chat.
  it "refuses an unauthorised sender" do
    refusal = issue("/delete", author_id: "999")
    expect(refusal).to be_a(Rubotty::Core::Commands::Refusal)
    expect(refusal.reason).to eq(:not_permitted)
    expect(refusal.message).to include("You need to be an operator")
  end

  def reply_from(id)
    Rubotty::Core::ReplyPreview.new(author: author(native_id: id))
  end

  def parse_delete(author_id:, target_id:, action: "/delete")
    commands.parse(
      message(tg, text: action, author: author(native_id: author_id),
                  reply_to: ref("tg", "900"), reply_preview: reply_from(target_id)),
      directory: directory
    )
  end

  # A self delete has no operator issuer, which is what tells the router it is
  # authorised for every reachable room.
  it "lets a non operator delete a message they wrote themselves" do
    command = parse_delete(author_id: "999", target_id: "999")
    expect(command).to be_a(Rubotty::Core::Moderation::Command)
    expect(command.issuer).to be_nil
  end

  it "refuses a non operator deleting a message they did not write" do
    expect(parse_delete(author_id: "999", target_id: "777")).to be_a(Rubotty::Core::Commands::Refusal)
  end

  # There is no coherent self ban, so the self authorisation is delete only.
  it "keeps non delete verbs operator only, even for the author" do
    expect(parse_delete(author_id: "999", target_id: "999", action: "/pin")).to be_a(Rubotty::Core::Commands::Refusal)
  end

  # A bare /delete with no reply falls into the issuer's own-last-message mode;
  # every OTHER message action still needs a reply.
  it "refuses a non-delete message action issued without replying to anything" do
    expect(issue("/pin", reply_to: nil)).to be_a(Rubotty::Core::Commands::Refusal)
    expect(issue("/unpin", reply_to: nil)).to be_a(Rubotty::Core::Commands::Refusal)
  end

  it "reads a reply-less /delete as the own-last-message mode rather than refusing it" do
    command = issue("/delete", reply_to: nil)
    expect(command).to be_a(Rubotty::Core::Moderation::Command)
    expect(command.targeting).to eq(:own_last)
    expect(command.target_ref).to be_nil
  end

  # An empty directory used to switch the parser off wholesale, which is how a
  # community onboarded through the dashboard ended up relaying its own commands.
  it "still recognises a verb when no operators are configured" do
    empty = Rubotty::Core::Moderation::Directory.new
    expect(commands.enabled?).to be(true)
    expect(commands.parse(message(tg, text: "/delete"), directory: empty))
      .to be_a(Rubotty::Core::Moderation::Command)
    expect(commands.parse(message(tg, text: "/pin", reply_to: ref("tg", "900")), directory: empty))
      .to be_a(Rubotty::Core::Commands::Refusal)
  end

  # A message whose community did not resolve carries no directory, so the
  # issuer resolves to nobody and every verb but a self delete is refused.
  it "refuses an operator when no directory names their community" do
    refusal = issue("/delete", directory: nil)
    expect(refusal).to be_a(Rubotty::Core::Commands::Refusal)
    expect(refusal.reason).to eq(:not_permitted)
  end

  it "summarises what happened for the issuer" do
    command = issue("/delete")
    results = [
      Rubotty::Core::Moderation::Result.new(endpoint_id: "tg", status: :done),
      Rubotty::Core::Moderation::Result.new(endpoint_id: "dc", status: :unsupported)
    ]
    expect(commands.summarise(command, results)).to eq("delete: 1/2 endpoints (dc: unsupported)")
  end
end

RSpec.describe "moderation routing" do
  let(:tg) { endpoint("tg") }
  let(:dc) { endpoint("dc") }
  let(:storage) { Rubotty::Storage::Memory.new }
  let(:adapter) { Fakes::ReactingAdapter.new }
  let(:alex) do
    Rubotty::Core::Moderation::Operator.new(name: "Alex", identities: { fake: ["55"] })
  end
  let(:directory) { Rubotty::Core::Moderation::Directory.new([alex]) }
  let(:commands) { Rubotty::Core::Commands.new(logger: Rubotty::Log.null) }

  subject(:router) do
    Rubotty::Core::Router.new(
      topology: topology(room("r", tg, dc)),
      adapters: Hash.new(adapter),
      storage: storage,
      loop_guard: Rubotty::Core::LoopGuard.new(storage: storage),
      logger: Rubotty::Log.null,
      commands: commands,
      operators: directory
    )
  end

  before { storage.record(source: ref("tg", "900"), destination: ref("dc", "d9"), room_id: "r") }

  def issue(text, author_id: "55")
    router.handle(
      message(tg, text: text, native_id: "1000",
                  author: author(native_id: author_id), reply_to: ref("tg", "900"))
    )
  end

  it "executes the action on every endpoint in the room" do
    issue("/delete")
    expect(adapter.moderations.map { |m| m[:endpoint_id] }).to contain_exactly("tg", "dc")
  end

  # Discord reserves a leading "/" for its native slash-command UI, so the same
  # command must also fire under the alternate "!" marker.
  it "executes the action issued under the alternate ! prefix too" do
    issue("!delete")
    expect(adapter.moderations.map { |m| m[:endpoint_id] }).to contain_exactly("tg", "dc")
  end

  it "relays an unknown prefixed token normally rather than swallowing it" do
    router.handle(message(tg, text: "!notacommand", native_id: "1002"))
    expect(adapter.moderations).to be_empty
    expect(adapter.delivered.size).to eq(1)
  end

  it "translates the target into each endpoint's own id space" do
    issue("/delete")
    dc_call = adapter.moderations.find { |m| m[:endpoint_id] == "dc" }
    expect(dc_call[:native_id]).to eq("d9")
  end

  it "uses the origin's own id on the origin endpoint" do
    issue("/delete")
    tg_call = adapter.moderations.find { |m| m[:endpoint_id] == "tg" }
    expect(tg_call[:native_id]).to eq("900")
  end

  it "does not relay the command message itself" do
    issue("/delete")
    expect(adapter.delivered).to be_empty
  end

  it "relays an ordinary message normally" do
    router.handle(message(tg, text: "hello", native_id: "1001"))
    expect(adapter.delivered.size).to eq(1)
  end

  it "does not act, but relays the text normally rather than swallowing it, for an unauthorised sender" do
    issue("/delete", author_id: "999")
    expect(adapter.moderations).to be_empty
    expect(adapter.delivered.size).to eq(1)
  end

  it "reports unsupported for an adapter that cannot perform the action" do
    plain = Fakes::RecordingAdapter.new
    plain_router = Rubotty::Core::Router.new(
      topology: topology(room("r", tg, dc)), adapters: Hash.new(plain), storage: storage,
      loop_guard: Rubotty::Core::LoopGuard.new(storage: storage),
      logger: Rubotty::Log.null, commands: commands, operators: directory
    )
    results = plain_router.handle(
      message(tg, text: "/delete", native_id: "1000",
                  author: author(native_id: "55"), reply_to: ref("tg", "900"))
    )
    expect(results.map(&:status).uniq).to eq([:unsupported])
  end

  it "refuses an operator who is not permitted in this room" do
    scoped = Rubotty::Core::Moderation::Operator.new(
      name: "Alex", identities: { fake: ["55"] }, rooms: ["other-room"]
    )
    scoped_router = Rubotty::Core::Router.new(
      topology: topology(room("r", tg, dc)), adapters: Hash.new(adapter), storage: storage,
      loop_guard: Rubotty::Core::LoopGuard.new(storage: storage), logger: Rubotty::Log.null,
      commands: Rubotty::Core::Commands.new(logger: Rubotty::Log.null),
      operators: Rubotty::Core::Moderation::Directory.new([scoped])
    )
    scoped_router.handle(
      message(tg, text: "/delete", native_id: "1000",
                  author: author(native_id: "55"), reply_to: ref("tg", "900"))
    )
    expect(adapter.moderations).to be_empty
  end
end
