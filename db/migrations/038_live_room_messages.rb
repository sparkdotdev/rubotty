# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:live_room_messages) do
      primary_key :id
      foreign_key :community_id, :communities, null: false, on_delete: :cascade
      String   :room_key,     null: false, size: 128
      String   :origin_key,   size: 200
      String   :author_label, size: 200
      String   :body,         text: true, null: false, default: ""
      String   :kind,         null: false, size: 16, default: "chat"
      DateTime :created_at,   null: false
      index %i[community_id room_key id], name: :live_room_messages_room_seq_idx
      index [:created_at], name: :live_room_messages_age_idx
    end
  end

  down do
    drop_table(:live_room_messages)
  end
end
