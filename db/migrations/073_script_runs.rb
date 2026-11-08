# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:script_runs) do
      primary_key :id
      foreign_key :community_id, :communities, null: false, on_delete: :cascade
      foreign_key :script_id, :community_scripts, null: false, on_delete: :cascade

      # UTC, as YYYY-MM-DD, so a row ages out by the day it counts rather than
      # by the day it was last touched, and so ordering is the same on every
      # backend.
      String :day, null: false, size: 10

      # What handed the script the work: traffic or the clock.
      String :source, null: false, size: 16

      Integer :runs,     null: false, default: 0
      Integer :failures, null: false, default: 0

      DateTime :created_at, null: false
      DateTime :updated_at, null: false

      index %i[script_id day source], unique: true, name: :script_runs_day_idx
      index [:day], name: :script_runs_age_idx
    end
  end
end
