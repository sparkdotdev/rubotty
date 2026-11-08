# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:backfill_proposals) do
      primary_key :id
      foreign_key :community_id, :communities, null: false, on_delete: :cascade
      String   :endpoint_id, null: false, size: 200
      String   :status, null: false, size: 16, default: "pending"
      Integer  :fetched, null: false, default: 0
      Integer  :gaps, null: false, default: 0
      Integer  :ours, null: false, default: 0
      Integer  :claimed, null: false, default: 0
      Integer  :below_floor, null: false, default: 0
      DateTime :swept_since, null: true
      DateTime :expires_at, null: false
      String   :decided_by, null: true, size: 200
      DateTime :decided_at, null: true
      DateTime :created_at, null: false
      DateTime :updated_at, null: false

      index %i[community_id status], name: :backfill_proposals_status_idx
      index %i[endpoint_id status], name: :backfill_proposals_endpoint_idx
      index :expires_at, name: :backfill_proposals_expiry_idx
    end

    create_table(:backfill_proposal_items) do
      primary_key :id
      foreign_key :proposal_id, :backfill_proposals, null: false, on_delete: :cascade
      String   :native_id, null: false, size: 128
      String   :author_label, null: true, size: 200
      String   :preview, null: true, size: 500
      DateTime :sent_at, null: true
      DateTime :created_at, null: false

      index %i[proposal_id native_id], unique: true, name: :backfill_proposal_items_idx
    end
  end
end
