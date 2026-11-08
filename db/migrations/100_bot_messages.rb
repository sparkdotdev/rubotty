# frozen_string_literal: true

# Every message rubotty posts in a room and never takes back: a summary, a
# startup banner, an announcement. The self-deleting ones reap themselves off
# their own pending-deletion row, so only the permanent ones are written here,
# which makes this exactly the set /clean has to remove.
#
# There is no other way to find them again: Telegram's Bot API gives a bot no
# read of its own history (Core::HistorySweep skips it for that reason). Ids
# only, no author and no text; what the bot said is already in the room.
Sequel.migration do
  up do
    create_table(:bot_messages) do
      primary_key :id
      foreign_key :community_id, :communities, null: false, on_delete: :cascade

      String :room_key, null: false, size: 128
      String :endpoint_id, null: false, size: 255
      String :native_id, null: false, size: 255
      # What posted it, taken from the ephemeral group's name: "summary",
      # "bridge" and so on, so a sweep can be narrowed to one kind later.
      String :kind, null: false, size: 64, default: ""

      DateTime :posted_at, null: false

      # The sweep's own read: every message this community left in one room.
      index %i[community_id room_key], name: :bot_messages_room_idx
      # Idempotent recording, and the lookup a single deletion needs.
      index %i[endpoint_id native_id], name: :bot_messages_native_idx, unique: true
      index [:posted_at], name: :bot_messages_age_idx
    end

    # Seed the one thing already recoverable: the summary rubotty last pinned
    # in each room. Nothing else posted before this table existed can be found
    # again, so this is the whole backlog /clean can reach.

    # Row by row rather than INSERT ... SELECT: the unique index spans
    # (endpoint, native id) while a pin is keyed by room too, so a hub endpoint
    # holding one pin in two rooms would otherwise fail the whole migration.
    seen = {}
    from(:room_summary_pins).order(:id).each do |pin|
      key = [pin[:endpoint_id].to_s, pin[:native_id].to_s]
      next if pin[:native_id].to_s.empty? || seen[key]

      seen[key] = true
      from(:bot_messages).insert(
        community_id: pin[:community_id], room_key: pin[:room_key].to_s,
        endpoint_id: pin[:endpoint_id].to_s, native_id: pin[:native_id].to_s,
        kind: "summary", posted_at: pin[:updated_at] || Time.now
      )
    end
  end

  down do
    drop_table(:bot_messages)
  end
end
