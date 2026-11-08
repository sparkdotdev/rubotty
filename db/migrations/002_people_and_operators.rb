# frozen_string_literal: true

Sequel.migration do
  up do
    partial_unique_indexes = Rubotty::Storage::Dialect.for(self).partial_indexes?

    create_table(:people) do
      primary_key :id
      foreign_key :community_id, :communities, null: false, on_delete: :cascade
      String   :name, null: false, size: 200
      DateTime :created_at, null: false
      DateTime :updated_at, null: false
      index [:community_id], name: :people_community_idx
    end

    create_table(:person_identities) do
      primary_key :id
      foreign_key :person_id, :people, null: false, on_delete: :cascade
      String   :adapter,   null: false, size: 32
      String   :native_id, size: 255                 # platform user id (Telegram numeric, Discord snowflake)
      String   :username,  size: 200                 # handle, lowercased. Telegram @mentions carry no id.
      DateTime :created_at, null: false
      index %i[person_id adapter], name: :person_identities_person_idx
      index %i[adapter native_id], name: :person_identities_native_idx
      index %i[adapter username],  name: :person_identities_handle_idx
    end

    create_table(:operators) do
      primary_key :id
      foreign_key :community_id, :communities, null: false, on_delete: :cascade
      foreign_key :person_id,    :people,      null: false, on_delete: :cascade
      String   :actions, text: true, null: false, default: '"all"'  # JSON: "all" or ["delete","ban",...]
      String   :scope,   text: true, null: false, default: '"all"'  # JSON: "all" or ["<room_key>", ...]
      DateTime :granted_at, null: false
      String   :granted_by, size: 200                                # audit: who approved
      index %i[community_id person_id], unique: true, name: :operators_unique_idx
    end

    create_table(:operator_requests) do
      primary_key :id
      foreign_key :community_id, :communities, null: false, on_delete: :cascade
      String   :adapter,             null: false, size: 32
      String   :requester_native_id, null: false, size: 255
      String   :requester_username,  size: 200
      String   :requester_display,   size: 200
      String   :state, null: false, size: 16, default: "pending"  # pending | approved | denied | expired
      String   :prompt_ref, size: 255
      DateTime :requested_at, null: false
      DateTime :decided_at
      foreign_key :decided_by, :operators, on_delete: :set_null
      index %i[community_id state], name: :operator_requests_state_idx
      if partial_unique_indexes
        index %i[community_id adapter requester_native_id state], unique: true,
              name: :operator_requests_open_idx, where: { state: "pending" }
      else
        index %i[community_id adapter requester_native_id state],
              name: :operator_requests_open_idx
      end
    end
  end

  down do
    drop_table?(:operator_requests)
    drop_table?(:operators)
    drop_table?(:person_identities)
    drop_table?(:people)
  end
end
