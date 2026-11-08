# frozen_string_literal: true

require "spec_helper"

# On Discord a space is a guild holding many channels, so one pending row
# covers all of them. On Telegram every chat is its own space, so the pending
# row's external id IS the chat id, and approval lets channel discovery
# attribute that same chat. Exercised end to end since the handoff is a string equality.
RSpec.describe "Telegram pending-space handling", :control_plane do
  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }

  let(:http) { Fakes::TelegramHttp.new }
  let(:dispatcher) { Fakes::RecordingDispatcher.new }
  let(:authorization) { Rubotty::ControlPlane::AuthorizationDirectory.new(models: models) }
  let(:join_guard) { Rubotty::ControlPlane::JoinGuard.new(authorization: authorization) }

  let(:store) do
    Class.new do
      def initialize = @h = {}

      def get_state(key) = @h[key]

      def put_state(key, value, expires_at: nil) = @h[key] = value
    end.new
  end

  let(:scheduler) do
    Rubotty::Core::DurableScheduler.new(
      store: Rubotty::Core::DurableSchedulerStore::Sequel.new(db: db), session_id: "s1",
      logger: Rubotty::Log.null
    )
  end

  # Populated in the before block below, the same by-reference trick Core::Runtime
  # uses: the service and the adapter each need the other.
  let(:adapters) { {} }

  let(:pending_spaces) do
    Rubotty::ControlPlane::PendingSpaces.new(
      models: models, authorization: authorization, scheduler: scheduler,
      adapters: adapters, logger: Rubotty::Log.null
    )
  end

  let(:discovery) do
    Rubotty::ControlPlane::ChannelDiscovery.new(
      models: models,
      watch: Rubotty::ControlPlane::NewChannelWatch.new(models: models, store: store),
      pending_spaces: pending_spaces, logger: Rubotty::Log.null
    )
  end

  subject(:adapter) do
    Rubotty::Adapters::Telegram::Adapter.new(
      account: "telegram", settings: { token: "123:abc", transport: :long_polling, token_env: "TG_TOKEN" },
      dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [],
      join_guard: join_guard, pending_spaces: pending_spaces, discovery: discovery
    ).replace_client(Rubotty::Adapters::Telegram::ApiClient.new(token: "123:abc", http: http))
  end

  # The seeded account name, so a chat the control plane already maps really does
  # look mapped to this adapter: the lookup keys on (adapter, account, chat).
  before { adapters[[:telegram, "telegram"]] = adapter }

  let(:chat_id) { -1_009_999 }

  def bot_added(title: "Rando Group")
    {
      "update_id" => 9,
      "my_chat_member" => {
        "chat" => { "id" => chat_id, "type" => "supergroup", "title" => title },
        "from" => { "id" => 77, "username" => "inviter", "first_name" => "Ivy" },
        "date" => 1_700_000_000,
        "old_chat_member" => { "user" => { "id" => 999, "is_bot" => true }, "status" => "left" },
        "new_chat_member" => { "user" => { "id" => 999, "is_bot" => true }, "status" => "member" }
      }
    }
  end

  def message_in(id: chat_id, title: "Rando Group", text: "hello")
    {
      "update_id" => 10,
      "message" => {
        "message_id" => 100, "date" => 1_700_000_000,
        "chat" => { "id" => id, "type" => "supergroup", "title" => title },
        "from" => { "id" => 55, "first_name" => "Ada", "username" => "ada", "is_bot" => false },
        "text" => text
      }
    }
  end

  def pending_row = models.pending_space.where(adapter: "telegram", external_id: chat_id.to_s).first

  describe "being added to a group" do
    it "pends the chat under its own id, and posts the notice once" do
      adapter.handle_update(bot_added)

      row = pending_row
      expect(row).not_to be_nil
      expect(row.state).to eq(Rubotty::ControlPlane::PendingSpaces::PENDING)
      expect(row.name).to eq("Rando Group")
      expect(row.inviter_native_id).to eq("77")

      notices = http.requests.select { |request| request.method_name == "sendMessage" }
      expect(notices.map { |request| request.params["text"] })
        .to eq([Rubotty::ControlPlane::PendingSpaces::PENDING_NOTICE])
    end

    it "books the auto-leave timer for a chat no whitelist protects" do
      adapter.handle_update(bot_added)

      expect(pending_row.job_id).not_to be_nil
      expect(scheduler.pending(kind: Rubotty::ControlPlane::PendingSpaces::EXPIRE_KIND)).to eq(1)
    end

    it "leaves with leaveChat when the review window expires with no decision" do
      adapter.handle_update(bot_added)
      row = pending_row

      pending_spaces.expire(Struct.new(:payload).new({ "pending_space_id" => row.id }))

      expect(http.requests.map(&:method_name)).to include("leaveChat")
      expect(models.pending_space[row.id].state).to eq(Rubotty::ControlPlane::PendingSpaces::DENIED)
    end

    it "leaves with leaveChat on a deny" do
      adapter.handle_update(bot_added)

      pending_spaces.deny(id: pending_row.id, admin: "test")

      leave = http.requests.find { |request| request.method_name == "leaveChat" }
      expect(leave).not_to be_nil
      expect(leave.params["chat_id"].to_s).to eq(chat_id.to_s)
    end

    it "falls back to the inert notice when the leave itself fails" do
      adapter.handle_update(bot_added)
      http.error_on("sendMessage", code: 400, description: "no")
      http.error_on("leaveChat", code: 400, description: "not enough rights")

      pending_spaces.deny(id: pending_row.id, admin: "test")

      texts = http.requests.select { |request| request.method_name == "sendMessage" }
                  .map { |request| request.params["text"] }
      expect(texts).to include(Rubotty::ControlPlane::PendingSpaces::INERT_NOTICE)
      expect(models.pending_space[pending_row.id].inert_notice_posted_at).not_to be_nil
    end
  end

  # The whole reason a Telegram space is worth approving.
  describe "approving a pended chat, then seeing it discovered" do
    it "makes the chat appear as a discovered channel of the approved community" do
      adapter.handle_update(bot_added)
      result = pending_spaces.approve(
        id: pending_row.id, admin: "test", new_community_name: "Rando Community"
      )
      expect(result.approved?).to be(true)

      community = result.community
      expect(models.channel.where(community_id: community.id).count).to eq(0)

      adapter.handle_update(message_in)

      channel = models.channel.where(adapter: "telegram", route_key: chat_id.to_s).first
      expect(channel).not_to be_nil
      expect(channel.community_id).to eq(community.id)
      expect(channel.label).to eq("Rando Group")
      expect(channel.json_value(:settings)["chat_id"]).to eq(chat_id.to_s)
      expect(discovery.unmapped(community).map(&:id)).to include(channel.id)
    end

    it "attributes the chat to the community the approval attached it to, not a new one" do
      adapter.handle_update(bot_added)
      existing = models.community.first
      pending_spaces.approve(id: pending_row.id, admin: "test", community_id: existing.id)

      adapter.handle_update(message_in)

      channel = models.channel.where(adapter: "telegram", route_key: chat_id.to_s).first
      expect(channel.community_id).to eq(existing.id)
    end
  end

  # A bot that was down when it was added never sees my_chat_member, so without
  # this the chat stays invisible for good.
  describe "traffic from a chat that saw no join event" do
    it "pends the chat anyway, from a plain message" do
      adapter.handle_update(message_in)

      row = pending_row
      expect(row).not_to be_nil
      expect(row.state).to eq(Rubotty::ControlPlane::PendingSpaces::PENDING)
      expect(row.name).to eq("Rando Group")
    end

    it "says nothing in the chat, since nothing just happened there" do
      adapter.handle_update(message_in)

      expect(http.requests.map(&:method_name)).not_to include("leaveChat")
      texts = http.requests.select { |request| request.method_name == "sendMessage" }
                  .map { |request| request.params["text"] }
      expect(texts).not_to include(Rubotty::ControlPlane::PendingSpaces::PENDING_NOTICE)
    end

    it "still posts the notice once if a real join arrives for the same chat later" do
      adapter.handle_update(message_in)
      adapter.handle_update(bot_added)

      texts = http.requests.select { |request| request.method_name == "sendMessage" }
                  .map { |request| request.params["text"] }
      expect(texts.count(Rubotty::ControlPlane::PendingSpaces::PENDING_NOTICE)).to eq(1)
    end

    it "writes one row however chatty the group is, and never restarts the clock" do
      adapter.handle_update(message_in)
      expires_at = pending_row.expires_at
      5.times { adapter.handle_update(message_in(text: "again")) }

      expect(models.pending_space.where(external_id: chat_id.to_s).count).to eq(1)
      expect(pending_row.expires_at).to eq(expires_at)
    end

    it "never pends a chat that already belongs to a community" do
      known = models.platform_connection.where(adapter: "telegram").first

      adapter.handle_update(message_in(id: known.external_id, title: "SAMPLE"))

      expect(models.pending_space.where(external_id: known.external_id).count).to eq(0)
    end

    it "approving a traffic-pended chat discovers it just the same" do
      adapter.handle_update(message_in)
      result = pending_spaces.approve(
        id: pending_row.id, admin: "test", new_community_name: "Recovered Community"
      )

      adapter.handle_update(message_in(text: "hello again"))

      channel = models.channel.where(adapter: "telegram", route_key: chat_id.to_s).first
      expect(channel).not_to be_nil
      expect(channel.community_id).to eq(result.community.id)
    end
  end

  # A brand new group named after a core community is the case the two halves of
  # "authorized" disagreed on: the title whitelist called it authorized, so it was
  # never pended, while the discovery watch called it unauthorized, so no channel
  # row was written either, and the chat existed nowhere.
  describe "a chat whose title matches the protected whitelist" do
    def protected_message(text: "hello") = message_in(title: "SECOND Lisbon", text: text)

    def protected_join = bot_added(title: "SECOND Lisbon")

    # Being added is itself the thing worth reviewing, and a room nobody speaks
    # in is the one that would otherwise go unnoticed.
    it "reaches the board on the join event, before anybody has said a word in it" do
      adapter.handle_update(protected_join)

      row = pending_row
      expect(row).not_to be_nil
      expect(row.state).to eq(Rubotty::ControlPlane::PendingSpaces::PENDING)
      expect(row.name).to eq("SECOND Lisbon")
      expect(row.inviter_native_id).to eq("77")
    end

    it "stays in the chat on that join, and says nothing there" do
      adapter.handle_update(protected_join)

      expect(http.requests.map(&:method_name)).not_to include("leaveChat")
      texts = http.requests.select { |request| request.method_name == "sendMessage" }
                  .map { |request| request.params["text"] }
      expect(texts).to be_empty
    end

    it "books no auto-leave timer for the row that join created" do
      adapter.handle_update(protected_join)

      expect(pending_row.job_id).to be_nil
      expect(scheduler.pending(kind: Rubotty::ControlPlane::PendingSpaces::EXPIRE_KIND)).to eq(0)
    end

    it "is never left by the review timer when the join pended it either" do
      adapter.handle_update(protected_join)

      pending_spaces.expire(Struct.new(:payload).new({ "pending_space_id" => pending_row.id }))

      expect(http.requests.map(&:method_name)).not_to include("leaveChat")
      expect(pending_row.state).to eq(Rubotty::ControlPlane::PendingSpaces::PENDING)
    end

    it "writes one row when the join and the first message both arrive" do
      adapter.handle_update(protected_join)
      adapter.handle_update(protected_message)

      expect(models.pending_space.where(external_id: chat_id.to_s).count).to eq(1)
    end

    it "still reaches the board, since a title says nothing about who owns the chat" do
      adapter.handle_update(protected_message)

      row = pending_row
      expect(row).not_to be_nil
      expect(row.state).to eq(Rubotty::ControlPlane::PendingSpaces::PENDING)
      expect(row.name).to eq("SECOND Lisbon")
    end

    it "is never left by the review timer, which is what the whitelist is for" do
      adapter.handle_update(protected_message)

      pending_spaces.expire(Struct.new(:payload).new({ "pending_space_id" => pending_row.id }))

      expect(http.requests.map(&:method_name)).not_to include("leaveChat")
      expect(pending_row.state).to eq(Rubotty::ControlPlane::PendingSpaces::PENDING)
    end
  end

  # Nothing else about a message in an unmapped chat survives: it resolves to no
  # channel, so it never becomes a Core::Message and no pipeline feature runs. A
  # bot that answers nothing at all there is indistinguishable from one that is
  # down, which is the whole reason /version exists.
  describe "/version in a chat no community owns" do
    def replies
      http.requests.select { |request| request.method_name == "sendMessage" }
          .map { |request| request.params["text"] }
    end

    it "answers a bare /version" do
      adapter.handle_update(message_in(text: "/version"))

      expect(replies.last).to include(Rubotty::VERSION)
    end

    it "answers the @botname form Telegram fills in from the command menu" do
      adapter.handle_update(message_in(text: "/version@rubotty_telegram_bot"))

      expect(replies.last).to include(Rubotty::VERSION)
    end

    it "discloses only the service and its version to someone who operates nothing" do
      adapter.handle_update(message_in(text: "/version"))

      expect(replies.last).not_to include("ruby runtime:")
    end

    it "pends the chat as well, so the answer and the card arrive together" do
      adapter.handle_update(message_in(text: "/version"))

      expect(pending_row).not_to be_nil
    end

    it "stays silent in a chat that was reviewed and denied" do
      adapter.handle_update(message_in)
      pending_spaces.deny(id: pending_row.id, admin: "test")
      before = replies.length

      adapter.handle_update(message_in(text: "/version"))

      expect(replies.length).to eq(before)
    end

    it "answers nothing to an ordinary message, so this is a command surface only" do
      adapter.handle_update(message_in(text: "hello"))

      expect(replies).to be_empty
    end
  end
end
