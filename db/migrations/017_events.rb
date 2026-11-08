# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:events) do
      primary_key :id
      foreign_key :community_id, :communities, null: false, on_delete: :cascade
      foreign_key :room_id,      :rooms,       null: false, on_delete: :cascade
      String   :title,       null: false, size: 200
      String   :description, text: true
      DateTime :starts_at, null: false
      DateTime :ends_at
      String :timezone, size: 64
      String :kind,           null: false, size: 16
      String :game_title,     size: 200
      String :server_address, size: 255
      String :url,            size: 500
      String :rsvp_mode, null: false, size: 16, default: "none"
      String :status,    null: false, size: 16, default: "scheduled"
      String :reminder_intervals, text: true
      String :native_refs, text: true, null: false, default: "{}"
      String   :created_by, size: 200
      DateTime :created_at, null: false
      DateTime :updated_at, null: false
      index %i[community_id room_id starts_at], name: :events_room_starts_idx
    end

    create_table(:event_rsvps) do
      primary_key :id
      foreign_key :event_id, :events, null: false, on_delete: :cascade
      String :identity, null: false, size: 200
      String :platform, null: false, size: 32
      String   :response,     null: false, size: 16
      DateTime :responded_at, null: false
      index %i[event_id identity], unique: true, name: :event_rsvps_identity_idx
      index [:event_id], name: :event_rsvps_event_idx
    end
  end

  down do
    drop_table(:event_rsvps)
    drop_table(:events)
  end
end
