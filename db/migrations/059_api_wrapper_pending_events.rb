# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:api_wrapper_pending_events) do
      primary_key :id

      String :account, null: false, size: 64

      String :kind, null: false, size: 32

      String :channel_id, null: false, size: 255

      String :target_native_id, size: 64

      String :reply_to_native_id, size: 64

      String :author_native_id,    size: 255
      String :author_display_name, size: 255
      String :author_avatar_url,   size: 1000

      String :body, text: true

      String :attachments, text: true

      String :reaction_emoji,       size: 64
      String :reaction_custom_id,   size: 64
      String :reaction_custom_name, size: 128

      DateTime :created_at, null: false

      index [:account, :id], name: :api_wrapper_pending_events_account_idx
    end
  end
end
