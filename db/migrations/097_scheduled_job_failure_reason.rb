# frozen_string_literal: true

# A durable job that gave up left the row marked failed and nothing else. The
# only thing saying why was a warn line in the log ring buffer, which a restart
# wipes, so four features could stop one after another with the dashboard
# showing a healthy deployment throughout.
#
# The reason and the moment are kept on the row itself, which outlives the
# restart the buffer does not, and gives an operator surface something to read.
Sequel.migration do
  change do
    alter_table(:scheduled_jobs) do
      add_column :failed_reason, String, text: true
      add_column :failed_at, DateTime
      add_index %i[status failed_at], name: :scheduled_jobs_failed_idx
    end
  end
end
