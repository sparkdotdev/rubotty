# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:events) do
      add_column :recurrence_interval, Integer
    end
  end
end
