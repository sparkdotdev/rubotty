# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:feature_settings) do
      primary_key :id
      foreign_key :community_id, :communities, null: false, on_delete: :cascade
      foreign_key :channel_id,   :channels,    on_delete: :cascade   # NULL => community default
      String    :feature, null: false, size: 64     # "bridge" | "moderation" | "word_filter" | "faq" | ...
      TrueClass :enabled, null: false, default: false
      String    :config,  text: true, null: false, default: "{}"  # feature-specific config (JSON)
      DateTime  :created_at, null: false
      DateTime  :updated_at, null: false
      index %i[community_id channel_id feature], unique: true, name: :feature_settings_idx
    end
  end
end
