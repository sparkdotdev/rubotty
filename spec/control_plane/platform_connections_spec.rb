# frozen_string_literal: true

require "spec_helper"

# The operations core the dashboard's Platforms page drives to add, edit and remove a
# community's platform connections and to persist their per-account behaviour settings.
RSpec.describe Rubotty::ControlPlane::PlatformConnections, :control_plane do
  let(:db) { migrated_db }
  let(:models) { build_models(db) }
  let(:now) { Time.now }
  let(:config) { sample_model }

  let(:community) do
    models.community.create(slug: "editable-co", name: "Editable Co", status: "active", settings: "{}",
                            created_at: now, updated_at: now)
  end

  # The suite's explicit deployment fixture protects the sample community.
  let(:protected_community) do
    models.community.create(slug: "sample", name: "SAMPLE", status: "active", settings: "{}",
                            created_at: now, updated_at: now)
  end

  let(:telegram_account) { config.accounts["telegram"] }
  let(:discord_account) { config.accounts["discord"] }

  subject(:connections) { described_class.new(models: models, clock: -> { now }) }

  describe "#create" do
    it "creates a connection with the given identity and label" do
      row = connections.create(community: community, adapter: "discord", account: "discord",
                               external_id: "123", label: "Main server")
      expect(row.community_id).to eq(community.id)
      expect(row.adapter).to eq("discord")
      expect(row.account).to eq("discord")
      expect(row.external_id).to eq("123")
      expect(row.label).to eq("Main server")
    end

    it "rejects an adapter outside the known set, creating nothing" do
      expect do
        connections.create(community: community, adapter: "not-a-real-adapter", account: "x", external_id: "y")
      end.to raise_error(described_class::Invalid, /Unknown adapter "not-a-real-adapter"/)
      expect(models.platform_connection.where(community_id: community.id).count).to eq(0)
    end

    it "rejects a blank account, creating nothing" do
      expect do
        connections.create(community: community, adapter: "discord", account: "", external_id: "123")
      end.to raise_error(described_class::Invalid, "Account and external id are both required.")
      expect(models.platform_connection.where(community_id: community.id).count).to eq(0)
    end

    it "rejects a blank external id, creating nothing" do
      expect do
        connections.create(community: community, adapter: "discord", account: "discord", external_id: "")
      end.to raise_error(described_class::Invalid, "Account and external id are both required.")
      expect(models.platform_connection.where(community_id: community.id).count).to eq(0)
    end

    it "rejects a duplicate (adapter, account, external_id), leaving the existing row alone" do
      connections.create(community: community, adapter: "discord", account: "discord", external_id: "123")
      expect do
        connections.create(community: community, adapter: "discord", account: "discord", external_id: "123")
      end.to raise_error(described_class::Invalid, "A connection for discord/discord/123 already exists.")
      expect(models.platform_connection.where(community_id: community.id).count).to eq(1)
    end
  end

  it "guards configured community identity without requiring a title pattern" do
    policy = Rubotty::ControlPlane::ProtectedCommunities.new(community_slugs: [community.slug])
    allow(Rubotty::ControlPlane::ProtectedCommunities).to receive(:default).and_return(policy)
    row = connections.create(community: community, adapter: "discord", account: "discord", external_id: "original")
    community.update(name: "Renamed")

    expect do
      connections.update_identity(connection: row, adapter: "discord", account: "discord", external_id: "changed")
    end.to raise_error(described_class::Invalid, /protected community/)
    expect { connections.remove(connection: row) }.to raise_error(described_class::Invalid, /protected community/)
    expect(row.refresh.external_id).to eq("original")
  end

  describe "#update_identity" do
    let!(:connection) do
      connections.create(community: community, adapter: "discord", account: "discord",
                         external_id: "123", label: "Old label")
    end

    it "updates the adapter, account, external id and label" do
      updated = connections.update_identity(connection: connection, adapter: "discord", account: "discord",
                                            external_id: "456", label: "New label")
      expect(updated.external_id).to eq("456")
      expect(updated.label).to eq("New label")
    end

    it "rejects an adapter outside the known set, changing nothing" do
      expect do
        connections.update_identity(connection: connection, adapter: "not-a-real-adapter",
                                    account: "discord", external_id: "123")
      end.to raise_error(described_class::Invalid, /Unknown adapter/)
      expect(connection.refresh.adapter).to eq("discord")
    end

    it "refuses to edit a protected community's connection identity, touching nothing" do
      protected_connection = connections.create(community: protected_community, adapter: "discord",
                                                 account: "discord", external_id: "999")
      expect do
        connections.update_identity(connection: protected_connection, adapter: "discord",
                                    account: "discord", external_id: "changed", label: "Renamed")
      end.to raise_error(described_class::Invalid, /protected community/)
      expect(protected_connection.refresh.external_id).to eq("999")
      expect(protected_connection.refresh.label).to be_nil
    end

    it "does not re-validate a protected connection's request before refusing it" do
      protected_connection = connections.create(community: protected_community, adapter: "discord",
                                                 account: "discord", external_id: "999")
      # Both faults apply, and the protected-community refusal fires first.
      expect do
        connections.update_identity(connection: protected_connection, adapter: "not-a-real-adapter",
                                    account: "discord", external_id: "999")
      end.to raise_error(described_class::Invalid, /protected community/)
    end
  end

  describe "#save_behavior_settings" do
    let!(:telegram_connection) do
      connections.create(community: community, adapter: "telegram", account: "telegram", external_id: "1")
    end
    let!(:discord_connection) do
      connections.create(community: community, adapter: "discord", account: "discord", external_id: "2")
    end
    let!(:fieldless_connection) do
      connections.create(community: community, adapter: "stoat", account: "stoat", external_id: "3")
    end

    it "coerces and stores a boolean and a float field alongside a symbol field" do
      connection = connections.save_behavior_settings(
        connection: telegram_connection, account: telegram_account,
        raw_settings: { "reaction_policy" => "drop", "cross_delete_on_discord" => "false", "album_window" => "3" }
      )
      stored = connection.json_value(:settings)
      expect(stored).to eq("reaction_policy" => "drop", "cross_delete_on_discord" => false, "album_window" => 3.0)
    end

    it "validates a different adapter's fields independently" do
      connection = connections.save_behavior_settings(connection: discord_connection, account: discord_account,
                                                       raw_settings: { "max_upload_bytes" => "1000000" })
      expect(connection.json_value(:settings)).to eq("max_upload_bytes" => 1_000_000)
    end

    it "rejects a value outside a one_of field's allowed set, writing nothing" do
      expect do
        connections.save_behavior_settings(connection: telegram_connection, account: telegram_account,
                                           raw_settings: { "reaction_policy" => "not-a-policy" })
      end.to raise_error(described_class::Invalid, /must be one of/)
      expect(telegram_connection.refresh.json_value(:settings)).to eq({})
    end

    it "rejects a nil account, naming the connection's own account and adapter" do
      expect do
        connections.save_behavior_settings(connection: telegram_connection, account: nil, raw_settings: {})
      end.to raise_error(described_class::Invalid,
                         'No account named "telegram" is configured for telegram; add it on the ' \
                         "Accounts page before setting its behaviour.")
    end

    it "rejects an adapter with no editable behaviour fields" do
      expect do
        connections.save_behavior_settings(connection: fieldless_connection, account: telegram_account,
                                           raw_settings: {})
      end.to raise_error(described_class::Invalid, "stoat has no editable behaviour settings yet.")
    end

    it "raises Invalid, not KeyError, when BEHAVIOR_FIELDS names a field account_schema no longer declares" do
      stub_const("#{described_class}::BEHAVIOR_FIELDS",
                described_class::BEHAVIOR_FIELDS.merge(telegram: %i[reaction_policy no_longer_a_field]))
      expect do
        connections.save_behavior_settings(connection: telegram_connection, account: telegram_account,
                                           raw_settings: { "reaction_policy" => "drop" })
      end.to raise_error(described_class::Invalid, /no_longer_a_field/)
    end
  end

  describe "#list" do
    it "lists only the calling community's connections, adapter then account" do
      connections.create(community: community, adapter: "discord", account: "discord", external_id: "1")
      connections.create(community: community, adapter: "discord", account: "another", external_id: "2")
      connections.create(community: community, adapter: "telegram", account: "telegram", external_id: "3")
      connections.create(community: protected_community, adapter: "discord", account: "discord",
                         external_id: "999")

      rows = connections.list(community: community)
      expect(rows.map { |row| [row.adapter, row.account] }).to eq(
        [%w[discord another], %w[discord discord], %w[telegram telegram]]
      )
    end
  end

  describe "#remove" do
    it "removes a connection and returns true" do
      row = connections.create(community: community, adapter: "discord", account: "discord", external_id: "1")
      expect(connections.remove(connection: row)).to be(true)
      expect(models.platform_connection[row.id]).to be_nil
    end

    # migration 001 declares channels.platform_connection_id on_delete: :cascade, but
    # SQLite does not enforce a foreign key by default, so check the real backend.
    it "removes the connection's own channels too, whichever backend runs this" do
      row = connections.create(community: community, adapter: "discord", account: "discord", external_id: "1")
      channel = models.channel.create(
        community_id: community.id, platform_connection_id: row.id, adapter: "discord", account: "discord",
        route_key: "1", endpoint_key: "ek-remove-spec", created_at: now, updated_at: now
      )

      connections.remove(connection: row)

      expect(models.channel[channel.id]).to be_nil
    end

    # The whitelist's whole point is that the three most important communities
    # cannot be fat-fingered into a broken state from the panel, and dropping a
    # connection unroutes one just as thoroughly as repointing it does.
    it "refuses to remove a protected community's connection" do
      row = connections.create(community: protected_community, adapter: "discord", account: "discord",
                                external_id: "1")

      expect { connections.remove(connection: row) }
        .to raise_error(described_class::Invalid, /protected community/)
      expect(models.platform_connection[row.id]).not_to be_nil
    end
  end
end
