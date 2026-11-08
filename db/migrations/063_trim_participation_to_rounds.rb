# frozen_string_literal: true

# Trims structured participation down to what the harness actually keeps: a
# session and a round, with no game specific column. Scoring and per-response
# bookkeeping that lived in script_responses and script_entries moves to
# script_ledgers, the same store rubotty.add and rubotty.entries already use.
# A round gains a deadline (closes_at), which script to wake (on_close) and a
# payload (data), and loses the trivia specific prompt, answer and options.
#
# See migrations 001 and 050 for the up/down and portability rationale.
Sequel.migration do
  up do
    drop_table?(:script_entries)
    drop_table?(:script_responses)

    alter_table(:script_rounds) do
      drop_column :prompt
      drop_column :answer
      drop_column :options
      add_column :on_close, String, size: 200
      add_column :closes_at, DateTime
      add_column :data, String, text: true
    end
  end

  down do
    alter_table(:script_rounds) do
      drop_column :on_close
      drop_column :closes_at
      drop_column :data
      add_column :prompt, String, null: false, default: "", size: 1000
      add_column :answer, String, null: false, default: "", size: 200
      add_column :options, String, text: true
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
end
