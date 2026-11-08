# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:api_request_log) do
      add_index [:created_at], name: :api_request_log_age_idx
    end
  end
end
