# frozen_string_literal: true

# announced_join and announced_expiry (migration 010) never got wired to
# anything: GuestInvites#record_join gates on joined_at, and
# GuestRetention#reclaim_for gates on being called once per invite, not on
# either column. They have sat at their false default in every row since.
Sequel.migration do
  up do
    alter_table(:guest_invites) do
      drop_column :announced_join
      drop_column :announced_expiry
    end
  end

  down do
    alter_table(:guest_invites) do
      add_column :announced_join, TrueClass, null: false, default: false
      add_column :announced_expiry, TrueClass, null: false, default: false
    end
  end
end
