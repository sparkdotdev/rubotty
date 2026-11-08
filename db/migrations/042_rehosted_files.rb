# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:rehosted_files) do
      primary_key :id
      foreign_key :community_id, :communities, null: false, on_delete: :cascade

      String :room_key, size: 128

      String :token_hash, null: false, size: 64

      String :object_key, null: false, size: 255

      String :iv, null: false, size: 64
      String :auth_tag, null: false, size: 64

      String :filename, size: 255
      String :content_type, size: 128

      Integer :byte_size, null: false, default: 0
      Integer :sealed_bytes, null: false, default: 0

      String :source, null: false, size: 16, default: "relay"

      String :created_by, size: 200

      DateTime :created_at, null: false
      DateTime :expires_at, null: false

      index [:token_hash], unique: true, name: :rehosted_files_token_idx
      index [:expires_at], name: :rehosted_files_expiry_idx
      index %i[community_id id], name: :rehosted_files_community_idx
    end

    create_table(:rehosted_upload_tickets) do
      primary_key :id
      foreign_key :community_id, :communities, null: false, on_delete: :cascade

      String :room_key, size: 128

      String :token_hash, null: false, size: 64

      String :endpoint_key, null: false, size: 255

      String :requested_by_adapter, size: 64
      String :requested_by_native_id, size: 255
      String :requested_by_label, size: 200

      DateTime :created_at, null: false
      DateTime :expires_at, null: false
      DateTime :used_at

      String :pending_secret, size: 64
      Integer :pending_file_id

      index [:token_hash], unique: true, name: :rehosted_tickets_token_idx
      index [:expires_at], name: :rehosted_tickets_expiry_idx
      index %i[community_id id], name: :rehosted_tickets_community_idx
    end
  end

  down do
    drop_table(:rehosted_upload_tickets)
    drop_table(:rehosted_files)
  end
end
