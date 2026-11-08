# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:guest_invites) do
      add_foreign_key :room_id, :rooms, on_delete: :cascade
    end
    alter_table(:guest_messages) do
      add_foreign_key :room_id, :rooms, on_delete: :cascade
    end
    alter_table(:guest_uploads) do
      add_foreign_key :room_id, :rooms, on_delete: :cascade
    end

    room_id_by_channel_id = self[:room_channels].to_hash(:channel_id, :room_id)
    unless room_id_by_channel_id.empty?
      %i[guest_invites guest_messages guest_uploads].each do |table|
        next if self[table].empty?

        self[table].exclude(channel_id: nil).each do |row|
          room_id = room_id_by_channel_id[row[:channel_id]]
          self[table].where(id: row[:id]).update(room_id: room_id) if room_id
        end
      end
    end

    alter_table(:guest_invites)  { set_column_allow_null :channel_id, true }
    alter_table(:guest_messages) { set_column_allow_null :channel_id, true }
    alter_table(:guest_uploads)  { set_column_allow_null :channel_id, true }

    alter_table(:guest_invites) do
      add_index [:room_id], name: :guest_invites_room_idx
    end
    alter_table(:guest_messages) do
      add_index %i[room_id id], name: :guest_messages_room_seq_idx
    end
    alter_table(:guest_uploads) do
      add_index [:room_id], name: :guest_uploads_room_idx
    end
  end

  down do
    alter_table(:guest_invites)  { drop_foreign_key [:room_id] }
    alter_table(:guest_messages) { drop_foreign_key [:room_id] }
    alter_table(:guest_uploads)  { drop_foreign_key [:room_id] }

    alter_table(:guest_invites) do
      drop_index [:room_id], name: :guest_invites_room_idx
    end
    alter_table(:guest_messages) do
      drop_index %i[room_id id], name: :guest_messages_room_seq_idx
    end
    alter_table(:guest_uploads) do
      drop_index [:room_id], name: :guest_uploads_room_idx
    end

    alter_table(:guest_invites)  { drop_column :room_id }
    alter_table(:guest_messages) { drop_column :room_id }
    alter_table(:guest_uploads)  { drop_column :room_id }
  end
end
