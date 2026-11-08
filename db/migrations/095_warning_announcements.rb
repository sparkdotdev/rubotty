# frozen_string_literal: true

# The in-room notice posted when a warning could not be DMed, paired with the
# message it was about. An operator who later removes that message through the
# bot should not leave the notice standing over a blank space, so the pairing is
# what lets the removal take the notice with it.
#
# Only ever written for a warning issued by reply, since a warning naming no
# message has nothing to be paired with. Kept no longer than the warning itself.
Sequel.migration do
  change do
    create_table(:warning_announcements) do
      primary_key :id
      foreign_key :community_id, :communities, null: false, on_delete: :cascade
      String   :adapter,             null: false, size: 32
      String   :endpoint_id,         null: false, size: 255  # where the warned message was said
      String   :native_id,           null: false, size: 255  # the warned message itself
      String   :notice_endpoint_id,  null: false, size: 255  # where the notice was posted
      String   :notice_native_id,    null: false, size: 255  # the notice to retract
      DateTime :expires_at,          null: false
      DateTime :created_at,          null: false

      # The read on every bot-mediated delete: is a notice paired with this?
      index %i[endpoint_id native_id], name: :warning_announcements_message_idx
      index [:expires_at], name: :warning_announcements_expiry_idx
    end
  end
end
