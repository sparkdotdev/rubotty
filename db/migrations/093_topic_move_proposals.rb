# frozen_string_literal: true

# A move topic routing wants to make, waiting on an operator to say yes, and
# the training record it becomes once one does. One row covers the whole life:
# it starts pending, an operator approves or rejects it, or it lapses
# unanswered, and it then sits as a labelled sample of what the classifier got
# right and wrong. Kept from the MESSAGE's own date rather than the row's, so
# a proposal made about an old message is not kept longer than one about a
# fresh one, and the retention promise reads against the thing being retained.
Sequel.migration do
  change do
    create_table(:topic_move_proposals) do
      primary_key :id
      foreign_key :community_id, :communities, null: false, on_delete: :cascade
      String   :code,             null: false, size: 12   # what an operator types back
      String   :adapter,          null: false, size: 32
      String   :endpoint_id,      null: false, size: 255  # where the message was said
      String   :native_id,        null: false, size: 255
      String   :author_native_id, size: 255
      String   :author_name,      size: 200
      String   :from_room,        null: false, size: 255
      String   :to_room,          null: false, size: 255
      String   :body,             text: true              # the judged text, and the sample
      String   :reasoning,        text: true
      Float    :confidence
      Float    :here_confidence                           # how well it fitted where it was said
      String   :move_payload,     text: true              # the repostable copy, replayed on approval
      String   :state,            null: false, size: 16   # pending, approved, rejected, lapsed
      String   :decided_by,       size: 200
      String   :decision_reason,  text: true
      DateTime :decided_at
      DateTime :message_at,       null: false             # what retention is measured from
      DateTime :created_at,       null: false

      index %i[community_id code], unique: true, name: :topic_move_proposals_code_idx
      # The two reads: what is still open in a community, and what has lapsed.
      index %i[community_id state], name: :topic_move_proposals_state_idx
      index [:message_at], name: :topic_move_proposals_age_idx
    end
  end
end
