# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:feature_settings) do
      add_foreign_key :room_id, :rooms, on_delete: :cascade
    end

    unless self[:feature_settings].empty?
      room_id_by_channel_id = self[:room_channels].to_hash(:channel_id, :room_id)
      self[:feature_settings].exclude(channel_id: nil).each do |row|
        room_id = room_id_by_channel_id[row[:channel_id]]
        self[:feature_settings].where(id: row[:id]).update(room_id: room_id) if room_id
      end

      rows = self[:feature_settings].select(:id, :community_id, :room_id, :feature, :updated_at).all
      rows.group_by { |row| [row[:community_id], row[:room_id], row[:feature]] }.each_value do |group|
        next if group.size <= 1

        keep = group.max_by { |row| [row[:updated_at], row[:id]] }
        (group - [keep]).each { |row| self[:feature_settings].where(id: row[:id]).delete }
      end
    end

    alter_table(:feature_settings) do
      add_index %i[community_id room_id feature], unique: true, name: :feature_settings_room_idx
    end
    alter_table(:feature_settings) do
      drop_index %i[community_id channel_id feature], name: :feature_settings_idx
    end
    alter_table(:feature_settings) { drop_foreign_key [:channel_id] } if database_type == :mysql
    alter_table(:feature_settings) do
      drop_column :channel_id
    end
  end

  down do
    alter_table(:feature_settings) do
      add_foreign_key :channel_id, :channels, on_delete: :cascade
    end

    unless self[:feature_settings].empty?
      self[:feature_settings].exclude(room_id: nil).each do |row|
        join = self[:room_channels].where(room_id: row[:room_id]).order(:id).first
        self[:feature_settings].where(id: row[:id]).update(channel_id: join[:channel_id]) if join
      end
    end

    alter_table(:feature_settings) do
      add_index %i[community_id channel_id feature], unique: true, name: :feature_settings_idx
    end
    alter_table(:feature_settings) do
      drop_index %i[community_id room_id feature], name: :feature_settings_room_idx
    end
    alter_table(:feature_settings) { drop_foreign_key [:room_id] } if database_type == :mysql
    alter_table(:feature_settings) do
      drop_column :room_id
    end
  end
end
