# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:script_endpoints) do
      add_column :query_params, String, text: true

      add_column :body_template, String, text: true
    end
  end
end
