# frozen_string_literal: true

require "spec_helper"

# The pending-space flow reaches an adapter through Adapters::Base's declared
# seams, so a platform that can leave and can post a notice has to say so or
# ControlPlane::PendingSpaces silently degrades it to inert.
RSpec.describe "Discord pending-space handling" do
  let(:client) { DiscordFakes::Client.new }

  let(:adapter) do
    Rubotty::Adapters::Discord::Adapter.new(
      account: "main",
      settings: { token: "t" },
      dispatcher: ->(_message) {},
      logger: Rubotty::Log.null,
      endpoints: []
    ).replace_client(client)
  end

  describe "the leave and notice seams" do
    it "declares that it can leave a guild" do
      expect(adapter.supports_leave?).to be(true)
    end

    it "declares that it can post a notice into a guild" do
      expect(adapter.supports_space_notice?).to be(true)
    end

    it "posts the notice and then leaves" do
      expect(adapter.leave_space("9001", notice: "going")).to be(true)

      expect(client.guild_notices).to include(hash_including(guild_id: "9001", text: "going"))
      expect(client.left_servers).to include("9001")
    end

    it "still reports a confirmed leave when the notice could not be posted" do
      allow(client).to receive(:post_guild_notice).and_raise(StandardError, "no channel")

      expect(adapter.leave_space("9001", notice: "going")).to be(true)
      expect(client.left_servers).to include("9001")
    end

    it "reports false when the leave itself failed" do
      client.fail_next_leave(StandardError.new("missing permission"))

      expect(adapter.leave_space("9001")).to be(false)
    end

    it "posts a notice with no accompanying leave" do
      expect(adapter.post_space_notice("9001", "under review")).to be(true)

      expect(client.guild_notices).to include(hash_including(guild_id: "9001", text: "under review"))
      expect(client.left_servers).to be_empty
    end

    it "refuses an empty notice" do
      expect(adapter.post_space_notice("9001", "  ")).to be(false)
      expect(client.guild_notices).to be_empty
    end
  end

  # Core::Runtime hands every adapter that declares the keyword the shared
  # PendingSpaces service, so a platform that does not declare it is quietly
  # left out of the review window.
  describe "the pending-spaces seam", :control_plane do
    let(:seeded) { seeded_sample }
    let(:models) { seeded[1] }
    let(:db) { seeded[0] }

    let(:join_guard) do
      Rubotty::ControlPlane::JoinGuard.new(
        authorization: Rubotty::ControlPlane::AuthorizationDirectory.new(models: models)
      )
    end

    let(:scheduler) do
      Rubotty::Core::DurableScheduler.new(
        store: Rubotty::Core::DurableSchedulerStore::Sequel.new(db: db), session_id: "s1",
        logger: Rubotty::Log.null
      )
    end

    let(:pending_spaces) do
      Rubotty::ControlPlane::PendingSpaces.new(
        models: models, authorization: Rubotty::ControlPlane::AuthorizationDirectory.new(models: models),
        scheduler: scheduler, adapters: {}, ttl: 1800, logger: Rubotty::Log.null
      )
    end

    subject(:guild_adapter) do
      Rubotty::Adapters::Discord::Adapter.new(
        account: "discord", settings: { token: "t" },
        dispatcher: ->(_message) {}, logger: Rubotty::Log.null, endpoints: [],
        join_guard: join_guard, pending_spaces: pending_spaces
      ).replace_client(client)
    end

    def add_unauthorized_guild
      client.set_guild_channels("999", [{ id: "123001", name: "general" }])
      guild_adapter.handle_guild_added(
        DiscordFakes::ServerCreateEvent.new(server: DiscordFakes::Server.new(id: "999", name: "Rando Server"))
      )
    end

    it "accepts the keyword the runtime wires uniformly" do
      expect(Rubotty::Adapters::Discord::Adapter.instance_method(:initialize).parameters)
        .to include([:key, :pending_spaces])
    end

    it "holds the service the way Adapters::Base declares" do
      expect(guild_adapter.pending_spaces).to be(pending_spaces)
    end

    it "pends an unauthorized guild rather than leaving it at once" do
      add_unauthorized_guild

      row = models.pending_space.where(adapter: "discord", external_id: "999").first
      expect(row).not_to be_nil
      expect(row.state).to eq(Rubotty::ControlPlane::PendingSpaces::PENDING)
      expect(client.left_servers).to be_empty
    end

    it "posts the pending notice once" do
      add_unauthorized_guild
      add_unauthorized_guild

      texts = client.guild_notices.map { |notice| notice[:text] }
      expect(texts.count(Rubotty::ControlPlane::PendingSpaces::PENDING_NOTICE)).to eq(1)
    end

    # The guild is kept because of its title and owned by nobody, so the board is
    # the only place it can show up at all.
    it "pends a guild whose title is on the protected whitelist, and stays in it" do
      client.set_guild_channels("997", [{ id: "123003", name: "general" }])
      guild_adapter.handle_guild_added(
        DiscordFakes::ServerCreateEvent.new(server: DiscordFakes::Server.new(id: "997", name: "SECOND Lisbon"))
      )

      row = models.pending_space.where(adapter: "discord", external_id: "997").first
      expect(row).not_to be_nil
      expect(row.state).to eq(Rubotty::ControlPlane::PendingSpaces::PENDING)
      expect(row.job_id).to be_nil
      expect(client.left_servers).to be_empty
      expect(client.guild_notices).to be_empty
    end

    it "still leaves at once when no pending-spaces service is wired" do
      bare = Rubotty::Adapters::Discord::Adapter.new(
        account: "discord", settings: { token: "t" },
        dispatcher: ->(_message) {}, logger: Rubotty::Log.null, endpoints: [],
        join_guard: join_guard
      ).replace_client(client)
      client.set_guild_channels("998", [{ id: "123002", name: "general" }])

      bare.handle_guild_added(
        DiscordFakes::ServerCreateEvent.new(server: DiscordFakes::Server.new(id: "998", name: "Rando Server"))
      )

      expect(client.left_servers).to eq(["998"])
    end
  end
end
