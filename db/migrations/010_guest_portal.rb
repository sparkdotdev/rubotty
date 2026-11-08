# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:guest_invites) do
      primary_key :id
      foreign_key :community_id, :communities, null: false, on_delete: :cascade
      foreign_key :channel_id, :channels, null: false, on_delete: :cascade
      String   :nickname,  null: false, size: 80
      String   :token_hash, null: false, size: 64
      String   :created_by, size: 200
      DateTime :expires_at, null: false
      DateTime :revoked_at
      DateTime :joined_at
      Integer  :join_cursor
      TrueClass :announced_join,   null: false, default: false
      TrueClass :announced_expiry, null: false, default: false
      DateTime :created_at, null: false
      DateTime :updated_at, null: false
      index [:token_hash], unique: true, name: :guest_invites_token_idx
      index [:channel_id], name: :guest_invites_channel_idx
      index [:community_id], name: :guest_invites_community_idx
      index [:expires_at], name: :guest_invites_expiry_idx
    end

    create_table(:guest_messages) do
      primary_key :id
      foreign_key :community_id, :communities, null: false, on_delete: :cascade
      foreign_key :channel_id,   :channels,    null: false, on_delete: :cascade
      foreign_key :invite_id, :guest_invites, on_delete: :cascade
      String   :direction, null: false, size: 8
      String   :author_label, size: 200
      String   :body, text: true, null: false, default: ""
      String   :attachments, text: true, null: false, default: "[]"
      String   :kind, null: false, size: 16, default: "chat"
      DateTime :relayed_at
      DateTime :created_at, null: false
      index %i[channel_id id], name: :guest_messages_channel_seq_idx
      index %i[direction relayed_at], name: :guest_messages_relay_idx
      index [:invite_id], name: :guest_messages_invite_idx
    end
  end
end
