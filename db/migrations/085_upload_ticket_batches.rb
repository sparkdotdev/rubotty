# frozen_string_literal: true

# /upload now hands a whole selection through one ticket, not one file, so the
# hand-off to UploadAnnouncer needs an ordered list rather than a single
# secret and file id. pending_files carries a JSON array of {secret, file_id}
# pairs in selection order; pending_failed carries the filenames of anything
# in the same batch that could not be stored, so the room notice can name
# them. Both default to an empty array, the same shape guest_feed_entries'
# own attachments column uses.
Sequel.migration do
  up do
    alter_table(:rehosted_upload_tickets) do
      add_column :pending_files, String, text: true, null: false, default: "[]"
      add_column :pending_failed, String, text: true, null: false, default: "[]"
      drop_column :pending_secret
      drop_column :pending_file_id
    end
  end

  down do
    alter_table(:rehosted_upload_tickets) do
      add_column :pending_secret, String, size: 64
      add_column :pending_file_id, Integer
      drop_column :pending_files
      drop_column :pending_failed
    end
  end
end
