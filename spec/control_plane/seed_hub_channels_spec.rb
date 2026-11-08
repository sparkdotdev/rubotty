# frozen_string_literal: true

require "spec_helper"

# An IRC hub-mode account mirrors several rooms into one physical channel,
# so their channel rows legitimately share (adapter, account, route_key).
# #upsert_channel's own lookup used to collide the second room's write
# with the first's, which the database's plain unique index would also reject.
RSpec.describe "seeding an IRC hub group", :control_plane do
  let(:env) { { "TG_TOKEN" => "tg-token" } }

  # A room needs at least two endpoints (Loader#build_rooms), so each hub
  # room is bridged with a Telegram side too, exactly how hub mode is used
  # for real: the IRC side of several distinct cross-platform rooms all
  # mirror into the SAME physical IRC channel, and it is only that IRC side
  # that shares a route_key.
  def hub_yaml(gaming_receives: false, travel_receives: true)
    <<~YAML
      name: hub group seed test
      accounts:
        tg:
          adapter: telegram
          token_env: TG_TOKEN
        irc-hub:
          adapter: irc
          server: irc.example.org
          nick: rubotty
          mode: hub
          hub_channel: "#sample"
      rooms:
        - id: gaming
          label: Gaming
          endpoints:
            - id: tg-gaming
              adapter: telegram
              account: tg
              chat_id: "-1001"
            - id: irc-hub-gaming
              adapter: irc
              account: irc-hub
              channel: "#sample"
              room_label: gaming
              receive: #{gaming_receives}
        - id: travel
          label: Travel
          endpoints:
            - id: tg-travel
              adapter: telegram
              account: tg
              chat_id: "-1002"
            - id: irc-hub-travel
              adapter: irc
              account: irc-hub
              channel: "#sample"
              room_label: travel
              receive: #{travel_receives}
    YAML
  end

  let(:model) { Rubotty::Config::Loader.load_string(hub_yaml, env: env) }
  let(:db) { migrated_db }
  let(:models) { build_models(db) }

  it "seeds both rooms' channel rows without a uniqueness collision" do
    expect do
      Rubotty::ControlPlane::Seed.from_model(model, models: models, slug: "hub-test")
    end.not_to raise_error

    expect(models.channel.where(adapter: "irc", account: "irc-hub", route_key: "#sample").count).to eq(2)
  end

  it "keeps each room's own endpoint_key, receives and label on its own row" do
    Rubotty::ControlPlane::Seed.from_model(model, models: models, slug: "hub-test")

    gaming = models.channel.where(endpoint_key: "irc-hub-gaming").first
    travel = models.channel.where(endpoint_key: "irc-hub-travel").first

    expect(gaming.route_key).to eq("#sample")
    expect(travel.route_key).to eq("#sample")
    expect(gaming.receives).to be(false)
    expect(travel.receives).to be(true)
    expect(gaming.id).not_to eq(travel.id)
  end

  it "reseeding is idempotent: no duplicate rows, same identity" do
    Rubotty::ControlPlane::Seed.from_model(model, models: models, slug: "hub-test")
    gaming_id = models.channel.where(endpoint_key: "irc-hub-gaming").first.id
    travel_id = models.channel.where(endpoint_key: "irc-hub-travel").first.id

    Rubotty::ControlPlane::Seed.from_model(model, models: models, slug: "hub-test")

    expect(models.channel.where(adapter: "irc", account: "irc-hub", route_key: "#sample").count).to eq(2)
    expect(models.channel.where(endpoint_key: "irc-hub-gaming").first.id).to eq(gaming_id)
    expect(models.channel.where(endpoint_key: "irc-hub-travel").first.id).to eq(travel_id)
  end

  # The config-authoring mistake #receiving_endpoint already tolerates at
  # boot (logs an error, answers inbound with the first claimant): both hub
  # endpoints declare receives: true. Seed has to resolve this the SAME way,
  # not let the second write crash the whole seed transaction.
  describe "misconfigured with two receives: true claimants on one channel" do
    let(:model) { Rubotty::Config::Loader.load_string(hub_yaml(gaming_receives: true, travel_receives: true), env: env) }

    it "does not raise, and writes only the first claimant (config order) as receives: true" do
      expect do
        Rubotty::ControlPlane::Seed.from_model(model, models: models, slug: "hub-test")
      end.not_to raise_error

      gaming = models.channel.where(endpoint_key: "irc-hub-gaming").first
      travel = models.channel.where(endpoint_key: "irc-hub-travel").first
      expect([gaming.receives, travel.receives]).to eq([true, false])
    end
  end

  describe "a read-only hub with no receiving endpoint at all" do
    let(:model) { Rubotty::Config::Loader.load_string(hub_yaml(gaming_receives: false, travel_receives: false), env: env) }

    it "seeds both rows as receives: false, unchanged from the YAML" do
      Rubotty::ControlPlane::Seed.from_model(model, models: models, slug: "hub-test")

      gaming = models.channel.where(endpoint_key: "irc-hub-gaming").first
      travel = models.channel.where(endpoint_key: "irc-hub-travel").first
      expect([gaming.receives, travel.receives]).to eq([false, false])
    end
  end

  # ChannelResolver (backed by a Snapshot built from these seeded rows) is
  # what the IRC adapter's live inbound path reads through once a control
  # plane is active. Snapshot#build_route_index used to pick whichever of
  # the two rows happened to sort last, with no regard to receives at all.
  describe "the resulting Snapshot resolves inbound to the receiving room" do
    it "picks the receives: true endpoint through ChannelResolver, live" do
      Rubotty::ControlPlane::Seed.from_model(model, models: models, slug: "hub-test")
      registry = Rubotty::ControlPlane::Registry.build(models: models, accounts: model.accounts)
      resolver = Rubotty::ControlPlane::ChannelResolver.new(registry)

      endpoint = resolver.endpoint_for(:irc, "irc-hub", "#sample")

      expect(endpoint.id).to eq("irc-hub-travel")
    end
  end
end
