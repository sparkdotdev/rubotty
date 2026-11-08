# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:feature_settings) do
      add_index [:updated_at], name: :feature_settings_updated_at_idx
    end
  end
end
