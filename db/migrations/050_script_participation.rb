# frozen_string_literal: true

Sequel.migration do
  up do
    partial_unique_indexes = Rubotty::Storage::Dialect.for(self).partial_indexes?

    create_table(:script_sessions) do
      primary_key :id
      foreign_key :community_id, :communities, null: false, on_delete: :cascade

      String   :room_key, null: false, default: "", size: 128

      String   :kind,  null: false, size: 32
      String   :label, null: false, default: "", size: 200

      String   :state, null: false, default: "open", size: 16

      DateTime :opened_at, null: false
      DateTime :closed_at
      DateTime :created_at, null: false
      DateTime :updated_at, null: false

      if partial_unique_indexes
        index %i[community_id room_key state], unique: true,
              name: :script_sessions_open_idx, where: { state: "open" }
      else
        index %i[community_id room_key state], name: :script_sessions_open_idx
      end
      index [:updated_at], name: :script_sessions_age_idx
    end

    create_table(:script_rounds) do
      primary_key :id
      foreign_key :community_id, :communities, null: false, on_delete: :cascade
      foreign_key :session_id, :script_sessions, null: false, on_delete: :cascade

      Integer  :position, null: false, default: 1
      String   :prompt, null: false, default: "", size: 1000

      String   :answer, null: false, default: "", size: 200

      String   :options, text: true

      String   :state, null: false, default: "open", size: 16

      DateTime :opened_at, null: false
      DateTime :closed_at
      DateTime :created_at, null: false
      DateTime :updated_at, null: false

      if partial_unique_indexes
        index %i[session_id state], unique: true,
              name: :script_rounds_open_idx, where: { state: "open" }
      else
        index %i[session_id state], name: :script_rounds_open_idx
      end
      index %i[community_id id], name: :script_rounds_community_idx
    end

    create_table(:script_responses) do
      primary_key :id
      foreign_key :community_id, :communities, null: false, on_delete: :cascade
      foreign_key :round_id, :script_rounds, null: false, on_delete: :cascade

      String   :participant,  null: false, size: 200
      String   :display_name, null: false, default: "", size: 200

      String   :body, null: false, default: "", size: 500

      TrueClass :correct, null: false, default: false

      DateTime :first_at,   null: false
      DateTime :created_at, null: false
      DateTime :updated_at, null: false

      index %i[round_id participant], unique: true, name: :script_responses_person_idx
      index %i[community_id id], name: :script_responses_community_idx
    end

    create_table(:script_entries) do
      primary_key :id
      foreign_key :community_id, :communities, null: false, on_delete: :cascade
      foreign_key :session_id, :script_sessions, null: false, on_delete: :cascade

      String   :participant,  null: false, size: 200
      String   :display_name, null: false, default: "", size: 200

      Integer  :score,    null: false, default: 0
      Integer  :answered, null: false, default: 0

      DateTime :created_at, null: false
      DateTime :updated_at, null: false

      index %i[session_id participant], unique: true, name: :script_entries_person_idx
      index %i[session_id score], name: :script_entries_rank_idx
      index %i[community_id id], name: :script_entries_community_idx
    end
  end

  down do
    drop_table?(:script_entries)
    drop_table?(:script_responses)
    drop_table?(:script_rounds)
    drop_table?(:script_sessions)
  end
end
