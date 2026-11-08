# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:community_scripts) do
      add_column :yaml_data, String, text: true
    end
  end

  down do
    alter_table(:community_scripts) do
      drop_column :yaml_data
    end
  end
end
