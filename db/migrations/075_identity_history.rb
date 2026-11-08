# frozen_string_literal: true

Sequel.migration do
  change do
    # One row per name a person has worn, closed out (ended_at set) the moment
    # it changes rather than overwritten, unlike observed_identities itself.
    # Only written when the identity_history feature is on for the community.
    create_table(:observed_identity_names) do
      primary_key :id
      foreign_key :community_id, :communities, null: false, on_delete: :cascade
      String   :adapter,      null: false, size: 32
      String   :native_id,    null: false, size: 255
      String   :username,     size: 200
      String   :display_name, size: 200
      DateTime :started_at, null: false
      DateTime :ended_at

      index %i[community_id adapter native_id started_at], name: :observed_identity_names_entry_idx
      index %i[community_id adapter native_id ended_at],    name: :observed_identity_names_open_idx
    end

    # Same idea for a bridged nickname (migration 051): one row per stretch a
    # person held a given nickname on a given platform within the community.
    create_table(:bridged_nickname_history) do
      primary_key :id
      foreign_key :community_id, :communities, null: false, on_delete: :cascade
      foreign_key :person_id, :people, null: false, on_delete: :cascade
      String   :adapter,  null: false, size: 32
      String   :nickname, size: 64
      DateTime :started_at, null: false
      DateTime :ended_at

      index %i[community_id person_id adapter started_at], name: :bridged_nickname_history_entry_idx
      index %i[community_id person_id adapter ended_at],    name: :bridged_nickname_history_open_idx
    end
  end
end
