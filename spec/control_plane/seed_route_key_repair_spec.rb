# frozen_string_literal: true

require "spec_helper"

# A prior release's Seed#route_key_for fell back to the YAML endpoint id
# for five adapters; route_key now uses the platform's own address. A
# database seeded under the old shape still has route_key == endpoint_key,
# so a plain reseed collides with itself on the endpoint_key unique index.
RSpec.describe "reseeding a database seeded under an earlier route_key shape", :control_plane do
  let(:env) do
    { "TG_TOKEN" => "tg-token", "MX_TOKEN" => "mx-token", "XM_PASSWORD" => "xm-pass",
      "ST_TOKEN" => "st-token", "FX_TOKEN" => "fx-token" }
  end

  let(:yaml) do
    <<~YAML
      name: five adapter repair test
      accounts:
        tg:
          adapter: telegram
          token_env: TG_TOKEN
        mx:
          adapter: matrix
          homeserver: "https://matrix.example.org"
          token_env: MX_TOKEN
        xm:
          adapter: xmpp
          jid: "bot@example.org"
          password_env: XM_PASSWORD
        st:
          adapter: stoat
          token_env: ST_TOKEN
        fx:
          adapter: fluxer
          token_env: FX_TOKEN
        irc1:
          adapter: irc
          server: irc.example.org
          nick: bridgebot
      rooms:
        - id: general
          label: General
          endpoints:
            - id: tg-general
              adapter: telegram
              account: tg
              chat_id: "-1008000000001"
            - id: mx-general
              adapter: matrix
              account: mx
              room_id: "!abc:example.org"
            - id: xm-general
              adapter: xmpp
              account: xm
              room_jid: "general@conference.example.org"
            - id: st-general
              adapter: stoat
              account: st
              channel_id: "CHAN1"
            - id: fx-general
              adapter: fluxer
              account: fx
              channel_id: "1234567890"
            - id: irc-general
              adapter: irc
              account: irc1
              channel: "#general"
    YAML
  end

  let(:model) { Rubotty::Config::Loader.load_string(yaml, env: env) }
  let(:db) { migrated_db }
  let(:models) { build_models(db) }

  before { Rubotty::ControlPlane::Seed.from_model(model, models: models, slug: "repair-test") }

  # Simulate a database seeded under the earlier shape: rewrite every affected
  # channel's route_key back to the endpoint_key it fell back to at the time.
  def downgrade_to_earlier_route_key_shape
    %w[matrix xmpp stoat fluxer irc].each do |adapter|
      models.channel.where(adapter: adapter).each { |channel| channel.update(route_key: channel.endpoint_key) }
    end
  end

  it "does not raise a Sequel::UniqueConstraintViolation on reseed" do
    downgrade_to_earlier_route_key_shape

    expect do
      Rubotty::ControlPlane::Seed.from_model(model, models: models, slug: "repair-test")
    end.not_to raise_error
  end

  it "creates no duplicate rows: still exactly one channel per endpoint" do
    downgrade_to_earlier_route_key_shape
    Rubotty::ControlPlane::Seed.from_model(model, models: models, slug: "repair-test")

    expect(models.channel.count).to eq(6)
  end

  it "rewrites route_key back to the current shape for every affected adapter" do
    downgrade_to_earlier_route_key_shape
    Rubotty::ControlPlane::Seed.from_model(model, models: models, slug: "repair-test")

    expect(models.channel.where(endpoint_key: "mx-general").first.route_key).to eq("!abc:example.org")
    expect(models.channel.where(endpoint_key: "xm-general").first.route_key).to eq("general@conference.example.org")
    expect(models.channel.where(endpoint_key: "st-general").first.route_key).to eq("CHAN1")
    expect(models.channel.where(endpoint_key: "fx-general").first.route_key).to eq("1234567890")
    expect(models.channel.where(endpoint_key: "irc-general").first.route_key).to eq("#general")
  end

  it "keeps the same row identity across the repair rather than replacing it" do
    downgrade_to_earlier_route_key_shape
    id_before = models.channel.where(endpoint_key: "mx-general").first.id

    Rubotty::ControlPlane::Seed.from_model(model, models: models, slug: "repair-test")

    expect(models.channel.where(endpoint_key: "mx-general").first.id).to eq(id_before)
  end
end
