# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:redirection_window_messages) do
      primary_key :id
      foreign_key :community_id, :communities, null: false, on_delete: :cascade

      String :room_key, null: false, size: 128

      String :endpoint_id, null: false, size: 255
      String :native_id, null: false, size: 255

      String :author_id, size: 255
      String :author_handle, size: 200
      String :author_name, size: 200

      String :body, text: true, null: false, default: ""
      String :spans, text: true
      String :attachments, text: true

      DateTime :created_at, null: false

      index %i[community_id room_key id], name: :redirection_window_room_seq_idx
      index %i[community_id endpoint_id native_id], name: :redirection_window_native_idx
      index [:created_at], name: :redirection_window_age_idx
    end
  end

  down do
    drop_table(:redirection_window_messages)
  end
end
