# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::ControlPlane::Registry, :control_plane do
  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:accounts) { sample_model.accounts }

  subject(:registry) { described_class.build(models: models, accounts: accounts) }

  describe "#current" do
    it "hands out a frozen Snapshot" do
      expect(registry.current).to be_a(Rubotty::ControlPlane::Snapshot)
      expect(registry.current).to be_frozen
    end

    it "returns the same reference on repeated reads until a reload" do
      expect(registry.current).to be(registry.current)
    end

    it "carries the fallback accounts through unchanged when the database has none of its own" do
      expect(registry.current.accounts).to eq(accounts)
    end
  end

  # The database is the live source now, once it holds anything at all: a row
  # is what a dashboard-created or dashboard-edited account actually looks
  # like at runtime, and a name an operator deletes stays gone rather than
  # reappearing out of the fallback hash (config.accounts).
  describe "accounts resolved from the database" do
    let(:env) { ControlPlaneHelpers::CONFIG_ENV }

    it "uses the fallback hash whole while the table has never been seeded" do
      expect(models.account.count).to eq(0)
      built = described_class.build(models: models, accounts: accounts, env: env)
      expect(built.current.accounts).to eq(accounts)
    end

    it "becomes the sole source the moment it holds a row, dropping a fallback name it does not carry" do
      Rubotty::ControlPlane::Accounts.new(models: models).create(
        adapter: "telegram", name: "extra", settings: { "token_env" => "TELEGRAM_BOT_TOKEN" }
      )
      built = described_class.build(models: models, accounts: accounts, env: env)
      expect(built.current.accounts.keys).to eq(["extra"])
      expect(built.current.accounts["extra"].settings[:token]).to eq(env["TELEGRAM_BOT_TOKEN"])
    end

    it "lets a row win over the fallback hash for a name both have" do
      Rubotty::ControlPlane::Accounts.new(models: models).create(
        adapter: "telegram", name: "telegram",
        settings: { "token_env" => "TELEGRAM_BOT_TOKEN", "poll_timeout" => 99 }
      )
      built = described_class.build(models: models, accounts: accounts, env: env)
      expect(built.current.accounts["telegram"].settings[:poll_timeout]).to eq(99)
    end

    it "drops a row that fails to resolve rather than reaching back into the fallback hash" do
      Rubotty::ControlPlane::Accounts.new(models: models).create(
        adapter: "discord", name: "discord", settings: { "token_env" => "DISCORD_BOT_TOKEN" }
      )
      models.account.create(
        adapter: "telegram", name: "telegram", settings: "{}", source: "dashboard",
        created_at: Time.now, updated_at: Time.now
      )
      built = described_class.build(models: models, accounts: accounts, env: env)
      expect(built.current.accounts).not_to have_key("telegram")
      expect(built.current.accounts["discord"]).to be_a(Rubotty::Config::Account)
    end
  end

  describe "the frozen value guarantees the router relies on" do
    it "freezes the projected community, its endpoints and rooms" do
      community = registry.current.community("sample")
      expect(community).to be_frozen
      expect(community.topology).to be_frozen
      expect(community.channels.first.endpoint).to be_frozen
    end
  end

  describe "#reload atomic swap semantics" do
    it "publishes a build before releasing the lock to a newer reload" do
      generation = 0
      builder = Object.new
      builder.define_singleton_method(:build) { |*_args, **_kwargs| generation += 1 }
      built = described_class.new(models: nil, builder: builder)
      mutex = Mutex.new
      paused, resume, start = Queue.new, Queue.new, Queue.new
      first = nil
      lock = Object.new
      lock.define_singleton_method(:synchronize) do |&block|
        value = mutex.synchronize(&block)
        if Thread.current == first
          paused << true
          resume.pop
        end
        value
      end
      built.instance_variable_set(:@reload_lock, lock)
      first = Thread.new { start.pop; built.reload }
      start << true
      expect(paused.pop(timeout: 5)).to be(true)
      expect(built.reload).to eq(3)
      resume << true
      first.value
      expect(built.current).to eq(3)
    ensure
      resume << true if resume
      first&.join(1)
      first&.kill&.join
    end

    it "retains the current snapshot when a rebuild fails" do
      current = registry.current
      allow(Rubotty::ControlPlane::SnapshotBuilder).to receive(:build).and_raise("unavailable")
      expect { registry.reload }.to raise_error("unavailable")
      expect(registry.current).to be(current)
    end

    it "builds a brand new Snapshot object" do
      before = registry.current
      after = registry.reload
      expect(after).not_to be(before)
      expect(registry.current).to be(after)
    end

    it "leaves an in-flight reader's Snapshot untouched when config changes" do
      in_flight = registry.current
      expect(in_flight.community("sample").name).to eq("SAMPLE")

      models.community.where(slug: "sample").update(name: "SAMPLE Renamed", updated_at: Time.now)
      registry.reload

      expect(in_flight.community("sample").name).to eq("SAMPLE")
      expect(in_flight).to be_frozen
      expect(registry.current.community("sample").name).to eq("SAMPLE Renamed")
    end

    it "reflects a newly added channel only after the reload that projects it" do
      before = registry.current
      expect(before.channel_by_endpoint_key("tg-extra")).to be_nil

      conn = models.platform_connection.where(adapter: "telegram").first
      community = models.community.where(slug: "sample").first
      now = Time.now
      models.channel.create(
        community_id: community.id, platform_connection_id: conn.id,
        adapter: "telegram", account: "telegram", route_key: "-1008000000001/777",
        endpoint_key: "tg-extra", label: "extra", receives: true, sends: true,
        relay: "{}", display_name: "{}", settings: '{"chat_id":"-1008000000001","thread_id":777}',
        created_at: now, updated_at: now
      )

      expect(before.channel_by_endpoint_key("tg-extra")).to be_nil
      registry.reload
      expect(registry.current.channel_by_endpoint_key("tg-extra")).not_to be_nil
      expect(registry.current.resolve(:telegram, "telegram", "-1008000000001/777").endpoint_key)
        .to eq("tg-extra")
    end
  end

  describe "inbound resolution on the Snapshot" do
    subject(:snapshot) { registry.current }

    it "resolves an exact Telegram forum topic" do
      expect(snapshot.resolve(:telegram, "telegram", "-1008000000001/142483").endpoint_key)
        .to eq("tg-gaming")
    end

    it "misses, rather than falling back to the General topic, for an unknown thread in a known chat" do
      # Substituting General's channel here broke echo-exclusion for a topic that
      # shares a room with General.
      expect(snapshot.resolve(:telegram, "telegram", "-1008000000001/000000")).to be_nil
    end

    it "resolves a Discord channel by its snowflake" do
      expect(snapshot.resolve(:discord, "discord", "800000000000000011").endpoint_key)
        .to eq("dc-general")
    end

    it "misses on a space the bot does not serve" do
      expect(snapshot.resolve(:telegram, "telegram", "-999")).to be_nil
    end
  end
end
