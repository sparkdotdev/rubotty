# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:person_identities) do
      add_column :claimed_at, DateTime
    end
  end
end
