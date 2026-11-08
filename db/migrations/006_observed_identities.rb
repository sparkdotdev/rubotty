# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:observed_identities) do
      primary_key :id
      foreign_key :community_id, :communities, null: false, on_delete: :cascade
      String   :adapter,      null: false, size: 32   # :telegram, :discord, ...
      String   :native_id,    null: false, size: 255  # platform user id (Telegram numeric, Discord snowflake)
      String   :username,     size: 200               # handle, lowercased and de-sigiled. May be nil (no handle set).
      String   :display_name, size: 200               # human display name as last seen. May be nil.
      DateTime :first_seen_at, null: false
      DateTime :last_seen_at,  null: false

      index %i[community_id adapter native_id], unique: true, name: :observed_identities_entry_idx
      index %i[community_id username],     name: :observed_identities_handle_idx
      index %i[community_id display_name], name: :observed_identities_display_idx
    end
  end
end
