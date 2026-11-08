# frozen_string_literal: true

# When a platform last refused to deliver a DM to this account, and what it
# said. A bot cannot open a private chat with somebody who has never opened
# one with it, so an operator can hold a perfectly good grant and still hear
# nothing; without this the refusal lived in a log line and the dashboard
# went on showing an audience nobody was in. Nil until a DM is actually
# refused, and cleared again the moment one lands.
Sequel.migration do
  change do
    alter_table(:person_identities) do
      add_column :dm_refused_at, DateTime
      add_column :dm_refused_reason, String, size: 200
    end
  end
end
