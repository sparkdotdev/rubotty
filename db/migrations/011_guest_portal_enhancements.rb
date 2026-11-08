# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:guest_messages) do
      add_column :ref_id, Integer
    end

    create_table(:guest_uploads) do
      primary_key :id
      foreign_key :community_id, :communities, null: false, on_delete: :cascade
      foreign_key :channel_id,   :channels,    null: false, on_delete: :cascade
      String   :token, null: false, size: 64
      String   :filename, size: 255
      String   :content_type, size: 128
      String   :data, text: true, null: false
      Integer  :byte_size, null: false, default: 0
      DateTime :created_at, null: false
      index [:token], unique: true, name: :guest_uploads_token_idx
      index [:channel_id], name: :guest_uploads_channel_idx
    end
  end
end
