# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:api_keys) do
      add_column :platform_account, String, size: 64
      add_index [:community_id, :platform_account], name: :api_keys_platform_account_idx
    end
  end
end
