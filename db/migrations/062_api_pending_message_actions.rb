# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:api_pending_message_actions) do
      primary_key :id
      foreign_key :community_id, :communities, null: false, on_delete: :cascade
      foreign_key :room_id,      :rooms,       null: false, on_delete: :cascade
      foreign_key :api_key_id,   :api_keys,    on_delete: :set_null
      String   :message_id,   null: false, size: 32
      String   :kind,         null: false, size: 32
      String   :body,         text: true
      String   :reaction_emoji,       size: 64
      String   :reaction_custom_id,   size: 64
      String   :reaction_custom_name, size: 128
      String   :author_label, null: false, size: 200
      DateTime :created_at,   null: false
      index [:community_id], name: :api_pending_message_actions_community_idx
      index [:room_id], name: :api_pending_message_actions_room_idx
      index [:api_key_id], name: :api_pending_message_actions_key_idx
    end
  end

  down do
    drop_table(:api_pending_message_actions)
  end
end
