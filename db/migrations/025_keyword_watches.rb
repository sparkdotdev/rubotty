# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:keyword_watches) do
      primary_key :id
      String :community, null: false, size: 64
      String :subscriber_adapter,   null: false, size: 32
      String :subscriber_account,   null: false, size: 200
      String :subscriber_native_id, null: false, size: 255
      String :subscriber_username,  size: 200
      String :subscriber_display,   size: 200
      String :keyword, null: false, size: 200
      String :notify_via, null: false, size: 16, default: "mention"
      DateTime :created_at, null: false
      DateTime :expires_at, null: false
      DateTime :cancelled_at
      DateTime :last_notified_at
      String :job_id, size: 64

      index %i[community cancelled_at expires_at], name: :keyword_watches_active_idx
      index %i[community subscriber_adapter subscriber_native_id cancelled_at],
            name: :keyword_watches_subscriber_idx
    end
  end
end
