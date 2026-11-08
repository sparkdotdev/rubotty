# frozen_string_literal: true

# The policies that got it wrong, kept so the descriptions behind them can be
# rewritten against real examples. A row is written only when an operator
# reverses an action with /vindicate, so every one of them is a human's own
# judgement rather than a guess. It carries the judged text, the model's
# reasoning and confidence, and the operator's stated reason, which together
# are the whole sample. No author: who wrote a message teaches a prompt
# nothing, so the corpus deliberately holds the text and never the person.
Sequel.migration do
  change do
    create_table(:content_policy_misfires) do
      primary_key :id
      foreign_key :community_id, :communities, null: false, on_delete: :cascade
      String   :adapter,     null: false, size: 32
      String   :endpoint_id, null: false, size: 255
      String   :policy,      size: 200
      String   :action,      null: false, size: 32   # what had been done before it was reversed
      String   :body,        text: true              # the text the policy matched
      String   :reasoning,   text: true              # the model's own sentence for the match
      Float    :confidence
      String   :statement,   text: true              # why the operator disagreed
      String   :reversed_by, size: 200
      DateTime :acted_at,    null: false             # when the policy fired
      DateTime :created_at,  null: false             # when an operator called it wrong

      index %i[community_id created_at], name: :content_policy_misfires_recent_idx
      index [:created_at], name: :content_policy_misfires_age_idx
    end
  end
end
