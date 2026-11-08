# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:fluxer_instances) do
      primary_key :id
      foreign_key :community_id, :communities, null: false, on_delete: :cascade
      String :label, null: false, size: 200
      String :kind, null: false, size: 32, default: "self_hosted"
      String :endpoint_url, size: 255
      String :api_key_env, null: false, size: 128
      DateTime :created_at, null: false
      DateTime :updated_at, null: false
      index %i[community_id label], unique: true, name: :fluxer_instances_label_idx
      index [:community_id], name: :fluxer_instances_community_idx
    end
  end
end
