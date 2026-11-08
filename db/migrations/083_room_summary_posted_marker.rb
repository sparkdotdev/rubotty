# frozen_string_literal: true

# Service#run posted a summary, then advanced the watermark in a separate
# step. A retry after the post succeeded but before that second step landed
# re-fetched the same unconsumed messages and posted again. posted_message_id
# is a narrower claim written right after a successful post, so a retry can
# tell the post already happened and skip straight to the watermark advance.
Sequel.migration do
  change do
    alter_table(:room_summary_watermarks) do
      add_column :posted_message_id, Integer, null: false, default: 0
    end
  end
end
