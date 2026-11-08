# frozen_string_literal: true

require "spec_helper"
require "sequel"

RSpec.describe Rubotty::ControlPlane::Migrator, :control_plane do
  let(:db) { Sequel.sqlite }

  let(:control_tables) do
    %i[communities platform_connections channels rooms room_channels
       people person_identities operators operator_requests feature_settings
       observed_identities irc_networks fluxer_instances events event_rsvps]
  end

  it "creates every control-plane table on a fresh sqlite database" do
    described_class.run(db)
    control_tables.each do |table|
      expect(db.table_exists?(table)).to be(true), "expected #{table} to exist"
    end
  end

  it "records progress in schema_info and reports as current once applied" do
    described_class.run(db)
    expect(db.table_exists?(:schema_info)).to be(true)
    expect(described_class.current?(db)).to be(true)
  end

  it "is idempotent: re-running when up to date is a no-op" do
    described_class.run(db)
    expect { described_class.run(db) }.not_to raise_error
    control_tables.each { |table| expect(db.table_exists?(table)).to be(true) }
  end

  it "rolls fully back down, dropping every control-plane table" do
    described_class.run(db)
    described_class.rollback(db, target: 0)
    control_tables.each do |table|
      expect(db.table_exists?(table)).to be(false), "expected #{table} to be dropped"
    end
  end

  it "migrates cleanly again after a full rollback" do
    described_class.run(db)
    described_class.rollback(db, target: 0)
    described_class.run(db)
    control_tables.each { |table| expect(db.table_exists?(table)).to be(true) }
  end

  it "does not touch the message-map tables, which keep their own regime" do
    described_class.run(db)
    # The message map is applied separately and is FK-free derived state.
    expect(db.table_exists?(:message_map)).to be(false)
    Rubotty::Storage::Schema.apply(db)
    expect(db.table_exists?(:message_map)).to be(true)
    expect(db.table_exists?(:communities)).to be(true)
  end

  describe "JSON columns are portable TEXT, not a Postgres-only type" do
    before { described_class.run(db) }

    it "stores channel blobs as text so the schema is identical on sqlite and pg" do
      types = db.schema(:channels).to_h
      %i[settings relay display_name].each do |column|
        db_type = types[column][:db_type].to_s.downcase
        expect(db_type).to include("text"), "#{column} should be TEXT, got #{db_type.inspect}"
      end
    end
  end

  describe "the partial unique index on open operator requests" do
    before do
      described_class.run(db)
      now = Time.now
      db[:communities].insert(slug: "c", name: "C", status: "active", settings: "{}",
                              created_at: now, updated_at: now)
    end

    let(:community_id) { db[:communities].first[:id] }

    def request(state)
      db[:operator_requests].insert(
        community_id: community_id, adapter: "telegram", requester_native_id: "42",
        state: state, requested_at: Time.now
      )
    end

    it "permits at most one pending request per person per community" do
      request("pending")
      expect { request("pending") }.to raise_error(Sequel::UniqueConstraintViolation)
    end

    it "still allows a resolved request alongside a fresh pending one" do
      request("denied")
      expect { request("pending") }.not_to raise_error
    end
  end

  describe "the deterministic routing uniqueness" do
    before do
      described_class.run(db)
      now = Time.now
      @community_id = db[:communities].insert(slug: "c", name: "C", status: "active",
                                              settings: "{}", created_at: now, updated_at: now)
      @conn_id = db[:platform_connections].insert(
        community_id: @community_id, adapter: "telegram", account: "telegram",
        external_id: "-100", created_at: now, updated_at: now
      )
    end

    def channel(route_key:, endpoint_key:)
      db[:channels].insert(
        community_id: @community_id, platform_connection_id: @conn_id,
        adapter: "telegram", account: "telegram", route_key: route_key,
        endpoint_key: endpoint_key, receives: true, sends: true,
        relay: "{}", display_name: "{}", settings: "{}",
        created_at: Time.now, updated_at: Time.now
      )
    end

    it "rejects two channels for the same (adapter, account, route_key)" do
      channel(route_key: "-100/1", endpoint_key: "a")
      expect { channel(route_key: "-100/1", endpoint_key: "b") }
        .to raise_error(Sequel::UniqueConstraintViolation)
    end

    it "rejects a reused endpoint_key" do
      channel(route_key: "-100/1", endpoint_key: "a")
      expect { channel(route_key: "-100/2", endpoint_key: "a") }
        .to raise_error(Sequel::UniqueConstraintViolation)
    end
  end

  describe "migration 012: feature_settings moves from per-channel to per-room scope" do
    it "leaves the schema room-scoped: a room_id column, no channel_id, a room-scoped unique index" do
      described_class.run(db)
      columns = db.schema(:feature_settings).map(&:first)
      expect(columns).to include(:room_id)
      expect(columns).not_to include(:channel_id)
      expect(db.indexes(:feature_settings)).to include(
        feature_settings_room_idx: hash_including(unique: true, columns: %i[community_id room_id feature])
      )
    end

    # Migrate to 11, write rows in the old channel-scoped shape, then run forward and
    # inspect what 012 did to the data rather than only to the schema.
    describe "the data migration and collapse" do
      let(:now) { Time.now }

      before do
        Sequel.extension :migration
        Sequel::Migrator.run(db, described_class::MIGRATIONS_DIR, target: 11)

        @community_id = db[:communities].insert(slug: "c", name: "C", status: "active",
                                                 settings: "{}", created_at: now, updated_at: now)
        connection_id = db[:platform_connections].insert(
          community_id: @community_id, adapter: "telegram", account: "telegram",
          external_id: "-100", created_at: now, updated_at: now
        )
        @room_id = db[:rooms].insert(community_id: @community_id, room_key: "general", label: "GENERAL",
                                     display_name: "{}", created_at: now, updated_at: now)
        @tg_channel_id = db[:channels].insert(
          community_id: @community_id, platform_connection_id: connection_id,
          adapter: "telegram", account: "telegram", route_key: "-100", endpoint_key: "tg-general",
          relay: "{}", display_name: "{}", settings: "{}", created_at: now, updated_at: now
        )
        @dc_channel_id = db[:channels].insert(
          community_id: @community_id, platform_connection_id: connection_id,
          adapter: "discord", account: "discord", route_key: "200", endpoint_key: "dc-general",
          relay: "{}", display_name: "{}", settings: "{}", created_at: now, updated_at: now
        )
        db[:room_channels].insert(room_id: @room_id, channel_id: @tg_channel_id, created_at: now)
        db[:room_channels].insert(room_id: @room_id, channel_id: @dc_channel_id, created_at: now)
      end

      it "repoints a per-channel row at its channel's room" do
        db[:feature_settings].insert(community_id: @community_id, channel_id: @tg_channel_id,
                                     feature: "faq", enabled: true, config: "{}",
                                     created_at: now, updated_at: now)

        described_class.run(db)

        row = db[:feature_settings].where(feature: "faq").first
        expect(row[:room_id]).to eq(@room_id)
      end

      it "leaves a community-default row (NULL scope) alone" do
        db[:feature_settings].insert(community_id: @community_id, channel_id: nil,
                                     feature: "bridge", enabled: true, config: "{}",
                                     created_at: now, updated_at: now)

        described_class.run(db)

        row = db[:feature_settings].where(feature: "bridge").first
        expect(row[:room_id]).to be_nil
        expect([true, 1]).to include(row[:enabled])
      end

      it "collapses two rows that land on the same (community, room, feature), keeping the newest" do
        db[:feature_settings].insert(community_id: @community_id, channel_id: @tg_channel_id,
                                     feature: "word_filter", enabled: true, config: '{"from":"tg"}',
                                     created_at: now, updated_at: now)
        db[:feature_settings].insert(community_id: @community_id, channel_id: @dc_channel_id,
                                     feature: "word_filter", enabled: false, config: '{"from":"dc"}',
                                     created_at: now, updated_at: now + 10)

        described_class.run(db)

        rows = db[:feature_settings].where(feature: "word_filter").all
        expect(rows.size).to eq(1)
        expect(rows.first[:room_id]).to eq(@room_id)
        # The newer (dc) row won the collapse.
        expect(JSON.parse(rows.first[:config])).to eq("from" => "dc")
        expect([false, 0]).to include(rows.first[:enabled])
      end

      it "leaves a channel with no room_channels row at the community-default scope rather than raising" do
        orphan_channel_id = db[:channels].insert(
          community_id: @community_id, platform_connection_id: db[:platform_connections].first[:id],
          adapter: "telegram", account: "telegram", route_key: "-999", endpoint_key: "tg-orphan",
          relay: "{}", display_name: "{}", settings: "{}", created_at: now, updated_at: now
        )
        db[:feature_settings].insert(community_id: @community_id, channel_id: orphan_channel_id,
                                     feature: "faq", enabled: true, config: "{}",
                                     created_at: now, updated_at: now)

        expect { described_class.run(db) }.not_to raise_error

        row = db[:feature_settings].where(feature: "faq").first
        expect(row[:room_id]).to be_nil
      end

      it "rolls back to a channel-scoped row (best effort) and forward again cleanly" do
        db[:feature_settings].insert(community_id: @community_id, channel_id: @tg_channel_id,
                                     feature: "faq", enabled: true, config: "{}",
                                     created_at: now, updated_at: now)
        described_class.run(db)

        described_class.rollback(db, target: 11)
        row = db[:feature_settings].where(feature: "faq").first
        expect(row[:channel_id]).not_to be_nil
        expect(row).not_to have_key(:room_id)

        expect { described_class.run(db) }.not_to raise_error
        expect(described_class.current?(db)).to be(true)
      end
    end
  end

  # The room-scoped index cannot constrain the community-default rows, because
  # their room_id is NULL and NULLs compare as distinct on every backend.
  describe "migration 048: the community-default row is unique per feature" do
    let(:now) { Time.now }

    before do
      described_class.run(db)
      @community_id = db[:communities].insert(slug: "c", name: "C", status: "active",
                                              settings: "{}", created_at: now, updated_at: now)
    end

    def default_row(feature:, enabled:, at: now)
      db[:feature_settings].insert(community_id: @community_id, room_id: nil, feature: feature,
                                   enabled: enabled, config: "{}", created_at: at, updated_at: at)
    end

    it "refuses a second default row for the same community and feature" do
      default_row(feature: "faq", enabled: true)

      expect { default_row(feature: "faq", enabled: false) }
        .to raise_error(Sequel::UniqueConstraintViolation)
    end

    it "still allows the same feature as a default in two different communities" do
      other_id = db[:communities].insert(slug: "d", name: "D", status: "active",
                                         settings: "{}", created_at: now, updated_at: now)
      default_row(feature: "faq", enabled: true)

      expect do
        db[:feature_settings].insert(community_id: other_id, room_id: nil, feature: "faq",
                                     enabled: false, config: "{}", created_at: now, updated_at: now)
      end.not_to raise_error
    end

    it "still allows a room row alongside the default for the same feature" do
      room_id = db[:rooms].insert(community_id: @community_id, room_key: "general", label: "GENERAL",
                                  display_name: "{}", created_at: now, updated_at: now)
      default_row(feature: "faq", enabled: true)

      expect do
        db[:feature_settings].insert(community_id: @community_id, room_id: room_id, feature: "faq",
                                     enabled: false, config: "{}", created_at: now, updated_at: now)
      end.not_to raise_error
    end

    it "collapses duplicate defaults already in the table, keeping the newest" do
      Sequel.extension :migration
      Sequel::Migrator.run(db, described_class::MIGRATIONS_DIR, target: 47)
      db[:feature_settings].insert(community_id: @community_id, room_id: nil, feature: "word_filter",
                                   enabled: true, config: '{"from":"old"}', created_at: now, updated_at: now)
      db[:feature_settings].insert(community_id: @community_id, room_id: nil, feature: "word_filter",
                                   enabled: false, config: '{"from":"new"}',
                                   created_at: now, updated_at: now + 10)

      described_class.run(db)

      rows = db[:feature_settings].where(feature: "word_filter").all
      expect(rows.size).to eq(1)
      expect(JSON.parse(rows.first[:config])).to eq("from" => "new")
    end
  end

  describe "migration 070: correcting legacy bare event times" do
    let(:cutoff) { Time.utc(2026, 8, 15, 15, 30, 0) }

    before do
      Sequel.extension :migration
      Sequel::Migrator.run(db, described_class::MIGRATIONS_DIR, target: 69)
      @community_id = db[:communities].insert(
        slug: "c", name: "C", status: "active", settings: "{}",
        created_at: cutoff - 86_400, updated_at: cutoff - 86_400
      )
      @room_id = db[:rooms].insert(
        community_id: @community_id, room_key: "general", label: "GENERAL", display_name: "{}",
        created_at: cutoff - 86_400, updated_at: cutoff - 86_400
      )
    end

    def legacy_event(timezone:, created_at: cutoff - 1, status: "scheduled", ends_at: nil)
      db[:events].insert(
        community_id: @community_id, room_id: @room_id, title: "Legacy", starts_at: Time.utc(2026, 8, 16, 20),
        ends_at: ends_at, timezone: timezone, kind: "general", rsvp_mode: "none", status: status,
        native_refs: "{}", created_at: created_at, updated_at: created_at
      )
    end

    it "preserves the intended Lisbon wall clock for old scheduled events" do
      id = legacy_event(timezone: "Europe/Lisbon", ends_at: Time.utc(2026, 8, 16, 22))

      described_class.run(db)

      row = db[:events][id: id]
      expect(row[:starts_at].utc).to eq(Time.utc(2026, 8, 16, 19))
      expect(row[:ends_at].utc).to eq(Time.utc(2026, 8, 16, 21))
    end

    it "does not alter UTC, later, or no-longer-scheduled events" do
      utc = legacy_event(timezone: "UTC")
      later = legacy_event(timezone: "Europe/Lisbon", created_at: cutoff)
      cancelled = legacy_event(timezone: "Europe/Lisbon", status: "cancelled")

      described_class.run(db)

      [utc, later, cancelled].each do |id|
        expect(db[:events][id: id][:starts_at].utc).to eq(Time.utc(2026, 8, 16, 20))
      end
    end
  end
end
