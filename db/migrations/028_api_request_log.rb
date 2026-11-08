# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:api_request_log) do
      primary_key :id
      foreign_key :api_key_id, :api_keys, null: false, on_delete: :cascade
      DateTime :created_at, null: false
      index %i[api_key_id created_at], name: :api_request_log_key_time_idx
    end
  end
end
