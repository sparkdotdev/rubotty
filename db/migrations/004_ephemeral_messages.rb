# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:ephemeral_messages) do
      primary_key :id
      String   :group_id,    null: false, size: 64
      String   :endpoint_id, null: false, size: 128
      String   :channel,     text: true
      String   :native_id,   null: false, size: 255
      DateTime :delete_at,   null: false
      String   :session_id,  null: false, size: 64
      DateTime :created_at,  null: false
      index %i[endpoint_id native_id], unique: true, name: :ephemeral_messages_msg_idx
      index [:group_id],   name: :ephemeral_messages_group_idx
      index [:delete_at],  name: :ephemeral_messages_delete_at_idx
      index [:session_id], name: :ephemeral_messages_session_idx
    end
  end
end
