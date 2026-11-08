# frozen_string_literal: true

# A DM the bot meant to send a member and could not, kept until it can. On
# Telegram a bot cannot open a conversation at all, so a warning issued to
# somebody who has never messaged the bot reaches nobody: the room notice says
# as much, and the detail the DM carried was simply lost. Retained here and
# sent the moment that member first writes to the bot.
#
# Kept only as long as what it is about. A warning's own expiry is the ceiling,
# so a notice about a warning that has since decayed is never delivered late.
Sequel.migration do
  change do
    create_table(:undelivered_dms) do
      primary_key :id
      foreign_key :community_id, :communities, null: false, on_delete: :cascade
      String   :adapter,     null: false, size: 32
      String   :account,     null: false, size: 64
      String   :native_id,   null: false, size: 255  # who it is for, on that platform
      String   :display,     size: 200               # how they were named when it was written
      String   :event,       null: false, size: 32   # what it was about, for the audit trail
      String   :body,        null: false, text: true
      DateTime :expires_at,  null: false             # never delivered after this
      DateTime :created_at,  null: false
      DateTime :delivered_at

      # The read on every inbound DM: what is still owed to this person here.
      index %i[adapter account native_id delivered_at], name: :undelivered_dms_recipient_idx
      # The prune, and the sweep that drops what has expired undelivered.
      index [:expires_at], name: :undelivered_dms_expiry_idx
    end
  end
end
