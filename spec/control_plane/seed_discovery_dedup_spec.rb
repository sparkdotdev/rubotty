# frozen_string_literal: true

require "spec_helper"

# A channel seeded from YAML and the same channel found later by a live
# discovery sweep must resolve to the SAME row. Seed#route_key_for used to
# fall back to the YAML endpoint id while ChannelDiscovery#inventory always
# writes the platform's own channel id, so the two never collided.
RSpec.describe "a seeded channel and a discovered channel resolve to one row", :control_plane do
  let(:env) { { "STOAT_TOKEN" => "s-token", "TELEGRAM_BOT_TOKEN" => "tg-token" } }

  # A two-endpoint room, Stoat bridged to Telegram, is the shape this
  # proves. server_id is filled in so the seeded platform_connection's
  # external_id already matches what a live sweep would report; the
  # unfilled guild/server id gap is a separate, pre-existing concern.
  let(:yaml) do
    <<~YAML
      name: stoat dedup test
      accounts:
        stoat:
          adapter: stoat
          token_env: STOAT_TOKEN
        telegram:
          adapter: telegram
          token_env: TELEGRAM_BOT_TOKEN
      rooms:
        - id: general
          label: General
          endpoints:
            - id: st-general
              adapter: stoat
              account: stoat
              channel_id: "CHAN-GENERAL"
              server_id: "SRV1"
            - id: tg-general
              adapter: telegram
              account: telegram
              chat_id: "-1008000000001"
    YAML
  end

  let(:model) { Rubotty::Config::Loader.load_string(yaml, env: env) }
  let(:db) { migrated_db }
  let(:models) { build_models(db) }
  let(:community) { models.community.first }
  let(:stoat_connection) { models.platform_connection.where(adapter: "stoat").first }

  subject(:discovery) { Rubotty::ControlPlane::ChannelDiscovery.new(models: models, logger: Rubotty::Log.null) }

  before { Rubotty::ControlPlane::Seed.from_model(model, models: models, slug: "stoat-dedup") }

  it "keys the seeded Stoat channel by its platform channel_id, not the YAML endpoint id" do
    channel = models.channel.where(adapter: "stoat").first
    expect(channel.route_key).to eq("CHAN-GENERAL")
  end

  it "records nothing new when a discovery sweep finds the SAME Stoat channel" do
    expect(models.channel.count).to eq(2)

    recorded = discovery.inventory(
      adapter: :stoat, account: "stoat", external_id: stoat_connection.external_id,
      channels: [{ id: "CHAN-GENERAL", name: "General" }]
    )

    expect(recorded).to eq(0)
    expect(models.channel.count).to eq(2)
  end

  it "leaves nothing on the Discovered/unmapped page for the same channel" do
    discovery.inventory(
      adapter: :stoat, account: "stoat", external_id: stoat_connection.external_id,
      channels: [{ id: "CHAN-GENERAL", name: "General" }]
    )

    expect(discovery.unmapped(community)).to be_empty
  end
end
