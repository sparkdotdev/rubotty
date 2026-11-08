# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:api_pending_messages) do
      primary_key :id
      foreign_key :community_id, :communities, null: false, on_delete: :cascade
      foreign_key :room_id,      :rooms,       null: false, on_delete: :cascade
      foreign_key :api_key_id,   :api_keys,    on_delete: :set_null
      String   :author_label, null: false, size: 200
      String   :author_kind,  null: false, size: 16, default: "api"
      String   :body,         text: true, null: false, default: ""
      DateTime :created_at,   null: false
      index [:community_id], name: :api_pending_messages_community_idx
      index [:room_id], name: :api_pending_messages_room_idx
      index [:api_key_id], name: :api_pending_messages_key_idx
    end
  end

  down do
    drop_table(:api_pending_messages)
  end
end
