# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:platform_connections) do
      add_column :settings, String, text: true, null: false, default: "{}"
    end
  end
end
