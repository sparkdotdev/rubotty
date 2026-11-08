# frozen_string_literal: true

# What a content policy action did, kept only long enough for an operator to
# disagree with it. The alert is a DM, so the reply needs something to name
# back: `code` is that handle, and the row carries what reversing needs. That
# includes the judged text and the model's own reasoning, which is what a
# reversal copies into the misfire log for prompt tuning. Short lived on
# purpose: the body is the most sensitive thing this schema holds, so it
# lapses on a window while the audit trail, which does live for the
# community's life, records the action and never the text.
Sequel.migration do
  change do
    create_table(:content_policy_actions) do
      primary_key :id
      foreign_key :community_id, :communities, null: false, on_delete: :cascade
      String   :code,             null: false, size: 12   # what an operator types back
      String   :adapter,          null: false, size: 32
      String   :endpoint_id,      null: false, size: 255
      String   :native_id,        null: false, size: 255  # the message acted on
      String   :author_native_id, size: 255
      String   :author_name,      size: 200
      String   :action,           null: false, size: 32   # notify, flag_notify, warn_and_delete, delete
      String   :policy,           size: 200
      String   :body,             text: true              # the text the policy matched
      String   :reasoning,        text: true              # the model's own sentence for the match
      Float    :confidence                                # how sure it was, 0 to 1
      Integer  :warning_id                                # the strike a warn_and_delete issued
      Integer  :sanction_id                               # what the ladder escalated that strike to
      DateTime :created_at,       null: false
      DateTime :reversed_at
      String   :reversed_by,      size: 200

      index %i[community_id code], unique: true, name: :content_policy_actions_code_idx
      # One message, one open record: an edit is re-judged and has to find the
      # row it already has rather than minting a second code for the same thing.
      index %i[community_id endpoint_id native_id], name: :content_policy_actions_message_idx
      index [:created_at], name: :content_policy_actions_age_idx
    end
  end
end
