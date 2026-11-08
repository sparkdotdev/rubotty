# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:channels) do
      add_column :provisioned_by_bot, TrueClass, null: false, default: false
    end
  end
end
