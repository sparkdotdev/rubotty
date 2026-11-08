# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:bridged_nicknames) do
      primary_key :id
      foreign_key :community_id, :communities, null: false, on_delete: :cascade
      foreign_key :person_id, :people, null: false, on_delete: :cascade
      String   :adapter,  null: false, size: 32
      String   :nickname, null: false, size: 64
      String   :nickname_key, null: false, size: 64
      String   :set_by, null: false, size: 200
      DateTime :created_at, null: false
      DateTime :updated_at, null: false

      index %i[community_id person_id adapter], unique: true, name: :bridged_nicknames_person_idx
      index %i[community_id adapter nickname_key], unique: true, name: :bridged_nicknames_claim_idx
    end
  end
end
