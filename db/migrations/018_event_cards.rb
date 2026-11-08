# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:event_cards) do
      primary_key :id
      foreign_key :event_id, :events, null: false, on_delete: :cascade
      String :endpoint_id, null: false, size: 200
      String :native_id,   null: false, size: 200
      DateTime :created_at, null: false
      index %i[endpoint_id native_id], unique: true, name: :event_cards_native_idx
      index [:event_id], name: :event_cards_event_idx
    end
  end

  down do
    drop_table(:event_cards)
  end
end
