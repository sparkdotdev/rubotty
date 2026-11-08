# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:channels) do
      add_column :suggested, TrueClass, null: false, default: false
    end
  end
end
