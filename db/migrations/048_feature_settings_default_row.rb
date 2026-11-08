# frozen_string_literal: true

Sequel.migration do
  up do
    rows = self[:feature_settings].where(room_id: nil)
                                  .select(:id, :community_id, :feature, :updated_at).all
    rows.group_by { |row| [row[:community_id], row[:feature]] }.each_value do |group|
      next if group.size <= 1

      keep = group.max_by { |row| [row[:updated_at], row[:id]] }
      (group - [keep]).each { |row| self[:feature_settings].where(id: row[:id]).delete }
    end

    next unless Rubotty::Storage::Dialect.for(self).partial_indexes?

    alter_table(:feature_settings) do
      add_index %i[community_id feature], unique: true,
                name: :feature_settings_default_idx, where: { room_id: nil }
    end
  end

  down do
    next unless Rubotty::Storage::Dialect.for(self).partial_indexes?

    alter_table(:feature_settings) do
      drop_index %i[community_id feature], name: :feature_settings_default_idx
    end
  end
end
