# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:script_stats) do
      primary_key :id
      foreign_key :community_id, :communities, null: false, on_delete: :cascade

      String   :stat,      null: false, size: 64
      String   :row_name,  null: false, size: 120
      String   :room_key,  null: false, default: "", size: 128

      Integer  :value,     null: false, default: 0

      DateTime :created_at, null: false
      DateTime :updated_at, null: false

      index %i[community_id stat row_name room_key], unique: true, name: :script_stats_row_idx
      index [:updated_at], name: :script_stats_age_idx
    end
  end
end
