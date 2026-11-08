# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:script_endpoints) do
      primary_key :id
      foreign_key :community_id, :communities, null: false, on_delete: :cascade

      String   :name,        null: false, size: 64
      String   :description, text: true

      String   :http_method, null: false, size: 8, default: "GET"

      String   :url,         text: true, null: false

      String   :headers,     text: true

      TrueClass :allow_sync, null: false, default: false

      Integer  :timeout_seconds, null: false, default: 2

      Integer  :cache_seconds,   null: false, default: 30

      TrueClass :enabled,    null: false, default: true
      String   :created_by,  size: 128
      DateTime :created_at,  null: false
      DateTime :updated_at,  null: false

      index %i[community_id name], unique: true, name: :script_endpoints_name_idx
    end
  end
end
