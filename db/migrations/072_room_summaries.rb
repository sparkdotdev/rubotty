# frozen_string_literal: true

Sequel.migration do
  up do
    # A short-lived 071 revision created these tables before they were moved to
    # this free version. Accept that already-applied shape while marking 072 as
    # complete, rather than failing a deployment that saw the earlier revision.
    unless table_exists?(:room_summary_messages)
      create_table(:room_summary_messages) do
        primary_key :id
        foreign_key :community_id, :communities, null: false, on_delete: :cascade

        String :room_key, null: false, size: 128
        String :endpoint_id, null: false, size: 255
        String :native_id, null: false, size: 255
        String :author_label, size: 200
        String :body, text: true, null: false, default: ""
        DateTime :created_at, null: false

        index %i[community_id room_key id], name: :room_summary_messages_room_seq_idx
        index %i[community_id endpoint_id native_id], name: :room_summary_messages_native_idx, unique: true
      end
    end

    unless table_exists?(:room_summary_watermarks)
      create_table(:room_summary_watermarks) do
        primary_key :id
        foreign_key :community_id, :communities, null: false, on_delete: :cascade

        String :room_key, null: false, size: 128
        Integer :last_message_id, null: false
        DateTime :completed_at, null: false

        index %i[community_id room_key], name: :room_summary_watermarks_room_idx, unique: true
      end
    end
  end

  down do
    drop_table(:room_summary_watermarks)
    drop_table(:room_summary_messages)
  end
end
