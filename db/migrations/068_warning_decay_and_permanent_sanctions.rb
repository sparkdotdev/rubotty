# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:warnings) do
      add_column :account, String, size: 64
    end

    alter_table(:active_sanctions) do
      set_column_allow_null :until_at, true
    end
  end
end
