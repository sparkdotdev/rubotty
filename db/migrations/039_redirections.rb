# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:redirections) do
      primary_key :id
      foreign_key :community_id, :communities, null: false, on_delete: :cascade

      String :source_endpoint_id, null: false, size: 255
      String :target_room_id, null: false, size: 255

      String :operator, null: false, size: 200
      String :operator_native_id, size: 255

      Integer :message_count, null: false, default: 0
      String :status, null: false, size: 16
      Integer :step_index, null: false, default: 0
      String :plan, text: true

      DateTime :created_at, null: false
      DateTime :updated_at, null: false
      DateTime :completed_at

      index %i[community_id created_at], name: :redirections_community_time_idx
      index [:status], name: :redirections_status_idx
    end
  end

  down do
    drop_table(:redirections)
  end
end
