# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::ControlPlane::Seed, :control_plane do
  let(:model) { sample_model }
  let(:db) { migrated_db }
  let(:models) { build_models(db) }

  before { described_class.from_model(model, models: models, slug: "sample") }

  let(:snapshot) do
    Rubotty::ControlPlane::Registry.build(models: models, accounts: model.accounts).current
  end
  let(:community) { snapshot.community("sample") }

  # Compared on everything that makes an endpoint that place, so any field drifting
  # across the YAML -> DB -> Snapshot round trip fails the test.
  def endpoint_tuple(endpoint)
    [endpoint.id, endpoint.adapter_name, endpoint.account, endpoint.settings,
     endpoint.receives?, endpoint.sends?, endpoint.relay,
     endpoint.display_name_template, endpoint.display_name_fallback, endpoint.label]
  end

  # The control plane synthesises the guest and API endpoints, which a YAML model has
  # no way to describe and which the seed never produces. Both carry
  # channel_endpoint_key, so dropping that marker leaves only the seed's own output.
  def room_tuple(room)
    seeded = room.endpoints.reject { |e| e.settings.key?(:channel_endpoint_key) }
    [room.id, room.label, seeded.map { |e| endpoint_tuple(e) }]
  end

  it "creates the expected control-plane rows from the SAMPLE config" do
    expect(models.community.count).to eq(1)
    expect(models.platform_connection.count).to eq(2)   # one telegram supergroup, one discord guild
    expect(models.channel.count).to eq(16)              # 8 rooms * 2 endpoints
    expect(models.room.count).to eq(8)
    expect(models.room_channel.count).to eq(16)
    expect(models.person.count).to eq(1)                # sample_owner, deduplicated
    expect(models.person_identity.count).to eq(2)       # telegram (+handle) and discord
    expect(models.operator.count).to eq(1)
  end

  describe "the Snapshot it produces is equivalent to the one built from YAML" do
    it "reproduces the topology exactly, room by room and endpoint by endpoint" do
      yaml_rooms = model.topology.rooms.map { |r| room_tuple(r) }.sort_by(&:first)
      db_rooms = community.topology.rooms.map { |r| room_tuple(r) }.sort_by(&:first)
      expect(db_rooms).to eq(yaml_rooms)
    end

    it "reproduces every endpoint's adapter settings, including symbol-typed keys" do
      dc = community.topology.endpoint("dc-general")
      yaml_dc = model.topology.endpoint("dc-general")
      # webhook and use_embeds are :symbol fields a naive JSON round trip would flatten.
      expect(dc.settings).to eq(yaml_dc.settings)
      expect(dc.settings[:webhook]).to eq(:auto)
    end

    it "keeps the Telegram General endpoint free of a thread_id" do
      general = community.topology.endpoint("tg-general")
      expect(general.settings).not_to have_key(:thread_id)
      expect(general.settings[:chat_id]).to eq("-1008000000001")
    end

    it "resolves the operator identically on both platforms" do
      %i[telegram discord].each do |adapter|
        id = adapter == :telegram ? "80000012" : "80000000000000013"
        yaml_op = model.operators.resolve(adapter, id)
        db_op = community.operators.resolve(adapter, id)
        expect(db_op&.name).to eq(yaml_op&.name)
        expect(db_op&.identities).to eq(yaml_op&.identities)
        scope = { community_id: community.id }
        expect(db_op&.may?(:delete, "general", **scope)).to eq(yaml_op&.may?(:delete, "general", **scope))
      end
    end

    it "resolves a mentionable person by id and by handle identically" do
      expect(community.people.by_identity(:discord, "80000000000000013")&.name)
        .to eq(model.people.by_identity(:discord, "80000000000000013")&.name)
      expect(community.people.by_handle(:telegram, "sample_owner")&.name)
        .to eq(model.people.by_handle(:telegram, "sample_owner")&.name)
    end
  end

  describe "route derivation" do
    it "keys a Telegram forum topic as chat_id/thread_id" do
      channel = models.channel.where(endpoint_key: "tg-gaming").first
      expect(channel.route_key).to eq("-1008000000001/142483")
    end

    it "keys the General topic as the bare chat_id" do
      channel = models.channel.where(endpoint_key: "tg-general").first
      expect(channel.route_key).to eq("-1008000000001")
    end

    it "keys a Discord channel as its channel_id" do
      channel = models.channel.where(endpoint_key: "dc-general").first
      expect(channel.route_key).to eq("800000000000000011")
    end
  end

  describe "platform connections" do
    it "groups all Telegram topics under one supergroup connection keyed on chat_id" do
      telegram = models.platform_connection.where(adapter: "telegram").first
      expect(telegram.external_id).to eq("-1008000000001")
    end

    it "creates one Discord connection with a sentinel guild id, resolved later" do
      discord = models.platform_connection.where(adapter: "discord").first
      expect(discord.external_id).to eq("unresolved:sample")
    end
  end

  describe "feature settings seeded from the config" do
    it "turns the bridge on as the community default" do
      expect(community.feature_enabled?("tg-general", "bridge")).to be(true)
    end

    it "enables moderation and carries its command config" do
      expect(community.feature_enabled?("tg-general", "moderation")).to be(true)
      expect(community.feature_config("tg-general", "moderation"))
        .to include(ack_ttl_seconds: 15)
    end

    it "leaves an unconfigured feature off by code default" do
      expect(community.feature_enabled?("tg-general", "word_filter")).to be(false)
    end

    # A generic version of the regression above: every feature seed_features
    # touches, not just moderation, so a future key mismatch fails here first
    # instead of only ever being silently inert.
    it "only ever seeds config keys each feature's own config_schema declares" do
      seeded = models.feature_setting.where(community_id: community.id, room_id: nil).all
      expect(seeded).not_to be_empty

      seeded.each do |row|
        schema = Rubotty::Features::Catalog.class_for(row.feature)&.config_schema
        next if schema.nil?

        declared = schema.fields.keys.map(&:to_s)
        unknown = row.json_value(:config).keys - declared
        expect(unknown).to eq([]), "#{row.feature} seeded keys not in its config_schema: #{unknown}"
      end
    end
  end

  # Regression for the seed silently wiping a real dashboard edit: a
  # full-replace write used to drop whatever an operator had set for a key
  # seed_features itself never touches, on every reseed.
  describe "re-seeding after a dashboard edit to a key the seed itself never sets" do
    it "keeps delete_command_message instead of reverting it to unset" do
      controls = Rubotty::ControlPlane::FeatureControls.new(models: models)
      controls.set(community: community, selector: "all", feature: "moderation",
                    key: "delete_command_message", value: false)

      described_class.from_model(model, models: models, slug: "sample")

      fresh = Rubotty::ControlPlane::Registry.build(models: models, accounts: model.accounts).current
      config = fresh.community("sample").feature_config("tg-general", "moderation")
      expect(config[:delete_command_message]).to eq(false)
      expect(config).to include(ack_ttl_seconds: 15)
    end
  end

  # granted_at is the only timestamp column on operators, and ChangeDetector
  # polls it to decide whether a running process's Snapshot needs a reload.
  # A reseed that touched actions/scope in place without bumping it left a
  # running process enforcing the operator's old permissions indefinitely.
  describe "re-seeding an existing operator" do
    it "bumps granted_at even when only actions and scope changed in place" do
      operator = models.operator.where(community_id: community.id).first
      old_granted_at = Time.parse("2020-01-01 00:00:00 UTC")
      operator.update(granted_at: old_granted_at)

      described_class.from_model(model, models: models, slug: "sample")

      reloaded = models.operator.where(id: operator.id).first
      expect(reloaded.granted_at).to be > old_granted_at
    end
  end

  # The community's name is reconciled from config on every boot, and nothing else is.
  describe ".reconcile_identity" do
    def build_renamed_sample(new_name)
      yaml = File.read(ControlPlaneHelpers::CONFIG_PATH).sub(/^name: .*$/, "name: #{new_name}")
      Rubotty::Config::Loader.load_string(yaml, env: ControlPlaneHelpers::CONFIG_ENV)
    end

    it "updates the row's name when the config's has changed" do
      renamed = build_renamed_sample("SAMPLE Renamed")

      row = described_class.reconcile_identity(renamed, models: models, slug: "sample")

      expect(row).not_to be_nil
      expect(row.name).to eq("SAMPLE Renamed")
      expect(models.community.where(slug: "sample").first.name).to eq("SAMPLE Renamed")
    end

    it "returns nil and touches nothing when the name already matches" do
      before_updated_at = models.community.where(slug: "sample").first.updated_at

      row = described_class.reconcile_identity(model, models: models, slug: "sample")

      expect(row).to be_nil
      expect(models.community.where(slug: "sample").first.updated_at).to eq(before_updated_at)
    end

    it "returns nil for a slug with no existing row, rather than creating one" do
      row = described_class.reconcile_identity(model, models: models, slug: "no-such-slug")

      expect(row).to be_nil
      expect(models.community.where(slug: "no-such-slug").first).to be_nil
    end

    it "never touches topology, people or features, only the name" do
      renamed = build_renamed_sample("SAMPLE Renamed")
      before_counts = %i[room channel person operator feature_setting].to_h { |m| [m, models.public_send(m).count] }

      described_class.reconcile_identity(renamed, models: models, slug: "sample")

      after_counts = %i[room channel person operator feature_setting].to_h { |m| [m, models.public_send(m).count] }
      expect(after_counts).to eq(before_counts)
    end
  end

  describe "idempotency" do
    def counts
      %i[community platform_connection channel room room_channel person person_identity
         operator feature_setting].to_h { |m| [m, models.public_send(m).count] }
    end

    it "reconciles rather than duplicating when re-run" do
      before_counts = counts
      described_class.from_model(model, models: models, slug: "sample")
      expect(counts).to eq(before_counts)
    end

    it "still produces an equivalent topology after a re-seed" do
      described_class.from_model(model, models: models, slug: "sample")
      fresh = Rubotty::ControlPlane::Registry.build(models: models, accounts: model.accounts).current
      db_rooms = fresh.community("sample").topology.rooms.map { |r| room_tuple(r) }.sort_by(&:first)
      yaml_rooms = model.topology.rooms.map { |r| room_tuple(r) }.sort_by(&:first)
      expect(db_rooms).to eq(yaml_rooms)
    end
  end
end
