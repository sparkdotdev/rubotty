# frozen_string_literal: true

# GuestRetention#reclaim_for needs a database-level compare-and-swap so a
# revoke racing an already-claimed expiry job cannot both post the
# departure notice; this is what that claim is recorded against.
Sequel.migration do
  change do
    alter_table(:guest_invites) do
      add_column :reclaimed_at, DateTime
    end
  end
end
