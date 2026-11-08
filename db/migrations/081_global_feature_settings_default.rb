# frozen_string_literal: true

require "json"

# feature_settings has always scoped a row to one community (community_id
# NOT NULL); room_id was already nullable for the community-wide default
# every room inherits. This makes community_id nullable too: both NULL is
# the deployment-wide default, since a database-only deployment's static config has none.
Sequel.migration do
  # SQLite has no ALTER COLUMN, so relaxing this NOT NULL means rebuilding the
  # whole table. Sequel's own rebuild rewrites every foreign key (room_id's
  # included) as table-level, which SQLite's DROP COLUMN then refuses to ever
  # undo, breaking a rollback past migration 012; this rebuilds it by hand instead.
  rebuild_feature_settings = ->(db, community_id_null) {
    db.create_table(:feature_settings_081_rebuild) do
      primary_key :id
      foreign_key :community_id, :communities, null: community_id_null, on_delete: :cascade
      String :feature, null: false, size: 64
      TrueClass :enabled, null: false, default: false
      String :config, text: true, null: false, default: "{}"
      DateTime :created_at, null: false
      DateTime :updated_at, null: false
      foreign_key :room_id, :rooms, on_delete: :cascade
    end
    db[:feature_settings_081_rebuild].insert(
      db[:feature_settings].select(:id, :community_id, :feature, :enabled, :config, :created_at, :updated_at,
                                    :room_id)
    )
    db.drop_table(:feature_settings)
    db.rename_table(:feature_settings_081_rebuild, :feature_settings)
    db.alter_table(:feature_settings) do
      add_index %i[community_id room_id feature], unique: true, name: :feature_settings_room_idx
      add_index [:updated_at], name: :feature_settings_updated_at_idx
    end
  }

  up do
    if database_type == :sqlite
      rebuild_feature_settings.call(self, true)
    else
      alter_table(:feature_settings) { set_column_allow_null :community_id, true }
    end

    if Rubotty::Storage::Dialect.for(self).partial_indexes?
      # feature_settings_default_idx may or may not have survived the change
      # above depending on dialect; dropping it first, and tolerating that it
      # is already gone, then adding it back lands every dialect on the exact
      # same pair of indexes either way.
      begin
        alter_table(:feature_settings) { drop_index %i[community_id feature], name: :feature_settings_default_idx }
      rescue Sequel::DatabaseError
        nil
      end
      alter_table(:feature_settings) do
        add_index %i[community_id feature], unique: true, name: :feature_settings_default_idx,
                  where: { room_id: nil }
        add_index :feature, unique: true, name: :feature_settings_global_idx,
                  where: { community_id: nil, room_id: nil }
      end
    end

    next if self[:feature_settings].where(community_id: nil, room_id: nil, feature: "moderation").any?

    # Seeds the moderation row with what an accepted command meant before
    # there was anywhere live to read a bridge-wide default from:
    # DEFAULT_TTL_SECONDS and acknowledging on.
    now = Time.now
    self[:feature_settings].insert(
      community_id: nil, room_id: nil, feature: "moderation", enabled: true,
      config: JSON.generate(
        "ack_ttl_seconds" => Rubotty::Core::CommandAck::DEFAULT_TTL_SECONDS,
        "acknowledge" => true
      ),
      created_at: now, updated_at: now
    )
  end

  down do
    self[:feature_settings].where(community_id: nil).delete

    if Rubotty::Storage::Dialect.for(self).partial_indexes?
      begin
        alter_table(:feature_settings) { drop_index :feature, name: :feature_settings_global_idx }
      rescue Sequel::DatabaseError
        nil
      end
      begin
        alter_table(:feature_settings) { drop_index %i[community_id feature], name: :feature_settings_default_idx }
      rescue Sequel::DatabaseError
        nil
      end
    end

    if database_type == :sqlite
      rebuild_feature_settings.call(self, false)
    else
      alter_table(:feature_settings) { set_column_allow_null :community_id, false }
    end

    if Rubotty::Storage::Dialect.for(self).partial_indexes?
      alter_table(:feature_settings) do
        add_index %i[community_id feature], unique: true, name: :feature_settings_default_idx,
                  where: { room_id: nil }
      end
    end
  end
end
