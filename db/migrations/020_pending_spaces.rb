# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:pending_spaces) do
      primary_key :id
      String   :adapter,     null: false, size: 32    # telegram | discord | ...
      String   :account,     null: false, size: 64    # which credential (shared token) reported it
      String   :external_id, null: false, size: 255   # the coarse space id
      String   :name,        size: 200                # space title/name as reported at join time

      String  :inviter_native_id, size: 255
      String  :inviter_username,  size: 200
      String  :inviter_display,   size: 200

      Integer :member_count                            # best-effort, nil when unknown
      String  :sample_channels, text: true, null: false, default: "[]"  # JSON array of channel names

      String :state, null: false, size: 16, default: "pending"

      foreign_key :community_id, :communities, null: true, on_delete: :set_null

      String   :decided_by, size: 200                  # e.g. "dashboard:administrator"
      DateTime :decided_at

      DateTime :left_at

      DateTime :notice_posted_at
      DateTime :inert_notice_posted_at

      Integer  :job_id
      DateTime :expires_at, null: false

      DateTime :created_at, null: false
      DateTime :updated_at, null: false

      index %i[adapter account external_id], unique: true, name: :pending_spaces_addr_idx
      index [:state], name: :pending_spaces_state_idx
    end
  end
end
