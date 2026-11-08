# frozen_string_literal: true

# The messages rubotty put back, and the one person who may take each down
# again. A restored message is the bot's own post carrying somebody else's
# words, so the author has no ordinary way to delete it: /delete recognises
# its author by the replied-to message, and the author here is the bot.
# One row per posted copy, naming the member the copy speaks for, is what
# lets that member delete this and nothing else.
Sequel.migration do
  change do
    create_table(:content_policy_reposts) do
      primary_key :id
      foreign_key :community_id, :communities, null: false, on_delete: :cascade
      String   :adapter,           null: false, size: 32
      String   :endpoint_id,       null: false, size: 255
      String   :native_id,         null: false, size: 255  # the bot's own repost
      String   :author_native_id,  null: false, size: 255  # the only member who may delete it
      DateTime :created_at,        null: false

      # The lookup /delete makes, and the reason it can never match twice.
      index %i[endpoint_id native_id], unique: true, name: :content_policy_reposts_message_idx
      index [:created_at], name: :content_policy_reposts_age_idx
    end
  end
end
