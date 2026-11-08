# frozen_string_literal: true

# The claim ordered by run_at alone, so a moderation check waited behind every
# topic routing check queued before it, and each of those blocks on a model
# call. Priority orders the due window ahead of run_at, which bounds that wait
# at whatever one job is already in flight rather than the whole backlog.
#
# Higher runs first. The old due index led with run_at and has no reader left
# once the ordering changes, so it goes rather than costing every write.
Sequel.migration do
  up do
    alter_table(:scheduled_jobs) do
      add_column :priority, Integer, null: false, default: 0
      add_index %i[status priority run_at], name: :scheduled_jobs_priority_due_idx
      drop_index %i[status run_at], name: :scheduled_jobs_due_idx
    end
  end

  down do
    alter_table(:scheduled_jobs) do
      add_index %i[status run_at], name: :scheduled_jobs_due_idx
      drop_index %i[status priority run_at], name: :scheduled_jobs_priority_due_idx
      drop_column :priority
    end
  end
end
