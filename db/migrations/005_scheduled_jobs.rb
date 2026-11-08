# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:scheduled_jobs) do
      primary_key :id
      String   :community, size: 64
      String   :kind,      null: false, size: 64
      String   :payload,   text: true, null: false, default: "{}"
      DateTime :run_at,    null: false
      String   :recurrence, size: 64
      String   :status,    null: false, size: 16, default: "pending"
      Integer  :attempts,  null: false, default: 0
      DateTime :claimed_at
      String   :claimed_by, size: 64
      DateTime :created_at, null: false
      index %i[status run_at], name: :scheduled_jobs_due_idx
      index %i[status claimed_at], name: :scheduled_jobs_claimed_idx
      index [:community], name: :scheduled_jobs_community_idx
    end
  end
end
