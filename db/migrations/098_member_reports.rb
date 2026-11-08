# frozen_string_literal: true

# Everything that reached an operator was something rubotty noticed by itself;
# a member who saw something wrong had no way to say so. One row per reported
# MESSAGE rather than per reporter, so twenty people reporting one thing is one
# thread with a count rather than twenty alerts. The body is kept because a
# reported message is often gone before anybody looks, which makes this one of
# the few places holding message text; a window bounds that, and PRIVACY.md
# carries the entry.
Sequel.migration do
  change do
    create_table(:member_reports) do
      primary_key :id
      foreign_key :community_id, :communities, null: false, on_delete: :cascade
      String   :code,        null: false, size: 8   # what an operator answers by
      String   :endpoint_id, size: 255              # where the message is, nil for a forward that lost its origin
      String   :native_id,   size: 255              # the message itself, nil for the same reason
      String   :route,       null: false, size: 16  # reply, forward or link
      String   :author_native_id, size: 255
      String   :author_display,   size: 200
      String   :body,        text: true             # what it said, since it is often gone by the time anybody looks
      String   :reporter_adapter,   null: false, size: 32
      String   :reporter_native_id, null: false, size: 255
      String   :reporter_display,   size: 200
      Integer  :reports,     null: false, default: 1  # how many members reported this message
      TrueClass :acknowledged, null: false, default: false # whether the first reporter could be told
      String   :status,      null: false, size: 16, default: "open"
      DateTime :created_at,  null: false
      DateTime :expires_at,  null: false
      index %i[community_id code], name: :member_reports_code_idx, unique: true
      index %i[community_id endpoint_id native_id], name: :member_reports_message_idx
      index %i[community_id reporter_adapter reporter_native_id created_at],
            name: :member_reports_reporter_idx
      index [:expires_at], name: :member_reports_expiry_idx
    end
  end
end
