# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:community_scripts) do
      primary_key :id
      foreign_key :community_id, :communities, null: false, on_delete: :cascade

      String   :name,           null: false, size: 64
      String   :kind,           null: false, size: 16
      String   :language,       null: false, size: 16, default: "lua"
      String   :source,         text: true, null: false
      String   :compiled,       text: true

      String   :trigger_type,   null: false, size: 32
      String   :trigger_config, text: true

      TrueClass :enabled,       null: false, default: false

      String   :verified_digest, size: 64
      DateTime :verified_at
      String   :verification_notes, text: true

      Integer  :consecutive_failures, null: false, default: 0
      DateTime :disabled_at
      String   :disabled_reason, text: true

      String   :last_error,     text: true
      DateTime :last_error_at
      String   :recent_errors,  text: true

      DateTime :archived_at

      String   :created_by,     size: 128
      DateTime :created_at,     null: false
      DateTime :updated_at,     null: false

      index %i[community_id name], unique: true, name: :community_scripts_name_idx
      index %i[community_id enabled], name: :community_scripts_enabled_idx
    end
  end
end
