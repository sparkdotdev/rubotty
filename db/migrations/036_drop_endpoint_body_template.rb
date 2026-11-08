# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:script_endpoints) do
      drop_column :body_template
    end
  end

  down do
    alter_table(:script_endpoints) do
      add_column :body_template, String, text: true
    end
  end
end
