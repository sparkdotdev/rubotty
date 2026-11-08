# frozen_string_literal: true

require "spec_helper"
require "sequel"

# Two guarantees the ephemeral subsystem adds on top of the primitive: a
# `/delete` on one copy of a grouped bot message removes every copy on every
# platform, and a fresh session sweeps the durable table on boot to remove what a
# crashed or restarted session left stranded. Both go through the real Runtime.
RSpec.describe "ephemeral cross-platform delete and boot sweep" do
  describe "a /delete on one banner copy (issue #43)" do
    let(:tg) { endpoint("tg", account: "a") }
    let(:dc) { endpoint("dc", account: "b") }
    let(:tg_adapter) { Fakes::ReactingAdapter.new }
    let(:dc_adapter) { Fakes::ReactingAdapter.new }
    let(:adapters) { { [:fake, "a"] => tg_adapter, [:fake, "b"] => dc_adapter } }
    let(:topo) { topology(room("r", tg, dc)) }

    # Kept deliberately empty of any banner row: the banner is posted directly,
    # never relayed, so the ephemeral group is the only thing linking its copies.
    let(:storage) { Rubotty::Storage::Memory.new }

    let(:db) do
      database = Sequel.sqlite
      Rubotty::ControlPlane.migrate!(database)
      database
    end
    let(:store) { Rubotty::Core::EphemeralStore::Sequel.new(db: db) }
    let(:ephemeral) do
      Rubotty::Core::EphemeralMessage.new(
        adapters: adapters, session_id: "s", store: store, topology: topo, logger: Rubotty::Log.null
      )
    end

    let(:operator) do
      Rubotty::Core::Moderation::Operator.new(name: "Op", identities: { fake: ["55"] })
    end
    let(:directory) { Rubotty::Core::Moderation::Directory.new([operator]) }
    let(:commands) { Rubotty::Core::Commands.new(actions: [:delete], logger: Rubotty::Log.null) }

    let(:base) { Time.now }
    let(:clock) { -> { @now ||= base } }
    let(:scheduler) { Rubotty::Core::Scheduler.new(logger: Rubotty::Log.null, clock: clock) }
    def advance(seconds) = (@now = (@now || base) + seconds)

    subject(:router) do
      Rubotty::Core::Router.new(
        topology: topo, adapters: adapters, storage: storage,
        loop_guard: Rubotty::Core::LoopGuard.new(storage: storage),
        logger: Rubotty::Log.null, commands: commands, operators: directory,
        cleanup: scheduler, cleanup_after: 15, acknowledge: true, ephemeral: ephemeral
      )
    end

    after { scheduler.stop }

    # Post the banner as one linked group across both platforms, then delete the
    # copy on Telegram with a `/delete`.
    before do
      ephemeral.post(endpoints: [tg, dc], body: "Started rubotty", name: "rubotty", delete_after: 120)
      router.handle(
        message(tg, text: "/delete", native_id: "cmd1",
                    author: author(native_id: "55"), reply_to: ref("tg", "d1"))
      )
      advance(15)
      scheduler.run_due
    end

    it "removes the banner copy on the platform the command was run from" do
      expect(tg_adapter.deleted).to include(%w[tg d1])
    end

    # Before the group link this copy stayed up forever: the message map has no
    # banner row to translate the target across platforms.
    it "removes the banner copy on the OTHER platform too" do
      expect(dc_adapter.deleted).to include(%w[dc d1])
    end

    it "forgets the banner's durable rows, so the boot sweep will not chase it" do
      expect(store.group_id_for(endpoint_id: "tg", native_id: "d1")).to be_nil
      expect(store.group_id_for(endpoint_id: "dc", native_id: "d1")).to be_nil
    end
  end

  describe "the boot sweep of a previous session's banner (issue #41)", :control_plane do
    let(:yaml) do
      <<~YAML
        name: integration bridge
        accounts:
          tg: { adapter: telegram, token_env: TG_TOKEN }
          dc: { adapter: discord, token_env: DC_TOKEN }
        storage:
          driver: memory
        behaviour:
          log_level: fatal
        announce:
          room: lounge
          detail: minimal
          delete_after: 120
        rooms:
          - id: lounge
            endpoints:
              - { id: tg-lounge, adapter: telegram, account: tg, chat_id: "-100111" }
              - { id: dc-lounge, adapter: discord, account: dc, channel_id: "8000000000000000003" }
      YAML
    end

    let(:tg_http) { Fakes::TelegramHttp.new }
    let(:dc_client) { DiscordFakes::Client.new(own_id: "bot-dc") }

    # A Sequel-backed message map activates the control plane and with it the
    # durable ephemeral store; build runs both migration regimes on this connection.
    let(:db) { Sequel.sqlite }
    let(:storage) { Rubotty::Storage::SequelStore.new(db: db).migrate! }

    subject(:runtime) do
      account_env = { "TG_TOKEN" => "123:abc", "DC_TOKEN" => "dc" }
      config = Rubotty::Config::Loader.load_string(yaml, env: account_env)
      # Runtime no longer reads a control-plane deployment's accounts out of
      # the config; seed the table the way a real deployment's one-time seed
      # would, before boot resolves them into adapters. The runtime's env has
      # to carry the same token vars: the table resolves token_env against it.
      Rubotty::ControlPlane.migrate!(db)
      Rubotty::ControlPlane::Accounts.new(models: build_models(db)).seed_from_config(config)
      Rubotty::Core::Runtime.new(
        config: config, storage: storage, logger: Rubotty::Log.null, env: account_env
      ).tap do |rt|
        tg_http.on("sendMessage", { "message_id" => 77 })
        tg_http.default_result([])
        rt.build
        rt.adapters[[:telegram, "tg"]].replace_client(
          Rubotty::Adapters::Telegram::ApiClient.new(token: "123:abc", http: tg_http)
        )
        rt.adapters[[:discord, "dc"]].replace_client(dc_client)
        enable_startup_banner(rt)
      end
    end

    # The banner is off unless a community asks for it; these examples turn it on the way
    # an operator would, since they're about what happens to the copies once it has
    # posted. "all" is the community-wide selector.
    def enable_startup_banner(runtime)
      models = build_models(db)
      controls = Rubotty::ControlPlane::FeatureControls.new(models: models)
      models.community.all.each do |row|
        controls.enable(community: row, selector: "all", feature: "startup_banner")
      end
      runtime.registry.reload
    end

    let(:lounge_channel) { dc_client.channel("8000000000000000003") }

    after { runtime.stop }

    it "records a durable pending-deletion row for each banner copy it posts" do
      runtime.send(:announce_startup)
      expect(db[:ephemeral_messages].count).to eq(2)
    end

    it "deletes both stranded copies on the next boot and clears the table" do
      # This session posts the banner and records its pending deletions, then
      # "crashes" before its in-process timer fires.
      runtime.send(:announce_startup)
      expect(db[:ephemeral_messages].count).to eq(2)

      # A fresh boot: a new session id, so the previous session's rows are now
      # orphaned. The sweep removes their copies on both platforms.
      runtime.instance_variable_set(:@session_id, "a-brand-new-session")
      runtime.send(:sweep_ephemeral)

      expect(tg_http.last("deleteMessage").params["message_id"]).to eq(77)
      expect(lounge_channel.load_message("sent-1").deleted).to be(true)
      expect(db[:ephemeral_messages].count).to eq(0)
    end

    it "leaves this session's own still-pending rows alone" do
      runtime.send(:announce_startup)
      # Same session id: the boot sweep must not reap its own live banner.
      runtime.send(:sweep_ephemeral)

      expect(tg_http.called?("deleteMessage")).to be(false)
      expect(db[:ephemeral_messages].count).to eq(2)
    end

    # A redeploy cycle can restart faster than delete_after elapses, so the
    # previous banner's own timer never fires and the boot sweep may not even
    # be reached before the next restart. deliver_banner is called directly,
    # bypassing the suppressor, the way a genuinely new build always would.
    it "deletes the previous restart's banner immediately when a fresh one posts before its own delay elapses" do
      room = runtime.send(:routing_topology).rooms.find { |candidate| candidate.id == "lounge" }

      runtime.send(:deliver_banner, room, scope: nil)
      expect(db[:ephemeral_messages].count).to eq(2)

      # The fake's queued sendMessage response is one-shot, so the second
      # restart's own post needs its own queued reply.
      tg_http.on("sendMessage", { "message_id" => 78 })

      # The second banner posts before the first's delay has elapsed and
      # before any sweep has run.
      runtime.send(:deliver_banner, room, scope: nil)

      expect(tg_http.last("deleteMessage").params["message_id"]).to eq(77)
      expect(lounge_channel.load_message("sent-1").deleted).to be(true)
      expect(db[:ephemeral_messages].count).to eq(2)
    end
  end
end
