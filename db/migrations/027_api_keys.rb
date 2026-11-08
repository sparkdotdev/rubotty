# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:api_keys) do
      primary_key :id
      String :public_id, null: false, size: 36
      String :key_hash, null: false, size: 64
      String :scope, null: false, size: 16
      foreign_key :community_id, :communities, on_delete: :cascade
      String :label, null: false, size: 200
      String :created_by, size: 200
      DateTime :revoked_at
      DateTime :last_used_at
      DateTime :created_at, null: false
      DateTime :updated_at, null: false
      index [:key_hash], unique: true, name: :api_keys_key_hash_idx
      index [:public_id], unique: true, name: :api_keys_public_id_idx
      index [:community_id], name: :api_keys_community_idx
    end
  end
end
