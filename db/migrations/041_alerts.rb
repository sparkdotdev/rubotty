# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:alerts) do
      primary_key :id
      foreign_key :community_id, :communities, null: false, on_delete: :cascade

      String :room_key, null: false, default: "", size: 128
      String :script, null: false, default: "", size: 120

      String :text, null: false, size: 500
      String :mode, null: false, size: 8

      Integer :delivered_to, null: false, default: 0

      DateTime :seen_at
      DateTime :created_at, null: false

      index %i[community_id created_at], name: :alerts_community_time_idx
      index %i[community_id seen_at], name: :alerts_community_seen_idx
    end
  end

  down do
    drop_table(:alerts)
  end
end
