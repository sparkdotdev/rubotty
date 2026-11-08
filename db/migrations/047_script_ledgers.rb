# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:script_ledgers) do
      primary_key :id
      foreign_key :community_id, :communities, null: false, on_delete: :cascade

      String :bucket, null: false, size: 64
      String :key, null: false, size: 128

      Integer :value, null: false, default: 0

      DateTime :created_at, null: false
      DateTime :updated_at, null: false

      index %i[community_id bucket key], unique: true, name: :script_ledgers_key_idx
      index %i[community_id bucket value], name: :script_ledgers_top_idx
    end
  end
end
