# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:webhook_subscriptions) do
      primary_key :id
      foreign_key :community_id, :communities, null: false, on_delete: :cascade

      String :public_id, null: false, size: 36

      String :url, null: false, size: 1000
      String :label, null: false, default: "", size: 200

      String :event_types, null: false, text: true

      String :room_key, null: false, default: "", size: 128

      String :secret, null: false, size: 100
      String :previous_secret, size: 100
      DateTime :previous_secret_expires_at

      TrueClass :active, null: false, default: true

      DateTime :created_at, null: false
      DateTime :updated_at, null: false

      index %i[community_id active], name: :webhook_subs_community_idx
      index [:public_id], unique: true, name: :webhook_subs_public_idx
    end

    create_table(:webhook_deliveries) do
      primary_key :id
      foreign_key :community_id, :communities, null: false, on_delete: :cascade
      foreign_key :subscription_id, :webhook_subscriptions, null: false, on_delete: :cascade

      String :event_id, null: false, size: 64
      String :event_type, null: false, size: 64
      String :room_key, null: false, default: "", size: 128

      String :payload, null: false, text: true

      String :status, null: false, default: "queued", size: 16
      Integer :attempts, null: false, default: 0

      DateTime :next_attempt_at, null: false

      Integer :response_status
      String :last_error, size: 500

      DateTime :created_at, null: false
      DateTime :delivered_at

      index %i[subscription_id status id], name: :webhook_deliveries_queue_idx
      index %i[community_id id], name: :webhook_deliveries_community_idx
      index [:created_at], name: :webhook_deliveries_age_idx
    end
  end

  down do
    drop_table(:webhook_deliveries)
    drop_table(:webhook_subscriptions)
  end
end
