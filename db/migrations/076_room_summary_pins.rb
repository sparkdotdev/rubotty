# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:room_summary_pins) do
      primary_key :id
      foreign_key :community_id, :communities, null: false, on_delete: :cascade

      String :room_key, null: false, size: 128
      String :endpoint_id, null: false, size: 255
      String :native_id, null: false, size: 255
      DateTime :updated_at, null: false

      index %i[community_id room_key endpoint_id], name: :room_summary_pins_scope_idx, unique: true
    end
  end

  down do
    drop_table(:room_summary_pins)
  end
end
