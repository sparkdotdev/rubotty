# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:auth_tokens) do
      primary_key :id

      String :public_id, null: false, size: 36
      String :token_hash, null: false, size: 64

      Integer :community_id
      TrueClass :grants_operator, null: false, default: false
      TrueClass :grants_viewer, null: false, default: false

      String :label, size: 200
      String :created_by, size: 200

      DateTime :created_at, null: false
      DateTime :expires_at, null: false
      DateTime :revoked_at

      DateTime :redeemed_at
      String :redeemed_adapter, size: 32
      String :redeemed_native_id, size: 255
      String :redeemed_username, size: 200

      index [:token_hash], unique: true, name: :auth_tokens_hash_idx
      index [:public_id], unique: true, name: :auth_tokens_public_idx
      index [:community_id], name: :auth_tokens_community_idx
    end

    create_table(:auth_token_redemptions) do
      primary_key :id

      String :adapter, null: false, size: 32
      String :native_id, null: false, size: 255
      String :outcome, null: false, size: 16
      DateTime :attempted_at, null: false

      index %i[adapter native_id attempted_at], name: :auth_token_redemptions_actor_idx
    end
  end

  down do
    drop_table?(:auth_token_redemptions)
    drop_table?(:auth_tokens)
  end
end
