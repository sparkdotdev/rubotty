# frozen_string_literal: true

# A bounded digest ledger invalidates queued policy decisions when their source
# changes, including edits that no longer need classification. No text is kept.
Sequel.migration do
  change do
    create_table(:content_policy_revisions) do
      primary_key :id
      foreign_key :community_id, :communities, null: false, on_delete: :cascade
      String :endpoint_id, null: false, size: 255
      String :native_id, null: false, size: 255
      String :digest, size: 64
      String :kind, null: false, size: 8
      DateTime :expires_at, null: false

      index %i[community_id endpoint_id native_id], unique: true, name: :content_policy_revision_scope_idx
      index :expires_at, name: :content_policy_revision_expiry_idx
    end
  end
end
