# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:script_memos) do
      primary_key :id
      foreign_key :community_id, :communities, null: false, on_delete: :cascade
      foreign_key :community_script_id, :community_scripts, null: false, on_delete: :cascade

      String   :key,        null: false, size: 128
      String   :value,      text: true

      DateTime :expires_at, null: false
      DateTime :created_at, null: false
      DateTime :updated_at, null: false

      index %i[community_script_id key], unique: true, name: :script_memos_key_idx
      index [:expires_at], name: :script_memos_expiry_idx
    end
  end
end
