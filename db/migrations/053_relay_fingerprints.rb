# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:relay_fingerprints) do
      primary_key :id
      foreign_key :community_id, :communities, null: false, on_delete: :cascade

      String :endpoint_id, null: false, size: 255
      String :digest, null: false, size: 64

      DateTime :created_at, null: false

      index %i[community_id endpoint_id digest], name: :relay_fingerprints_lookup_idx, unique: true
      index [:created_at], name: :relay_fingerprints_age_idx
    end
  end

  down do
    drop_table(:relay_fingerprints)
  end
end
