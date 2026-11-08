# frozen_string_literal: true

# Session identity alone cannot distinguish a reclaimed job's successive claims.
Sequel.migration do
  change do
    alter_table(:scheduled_jobs) do
      add_column :claim_token, String, size: 36
    end
  end
end
