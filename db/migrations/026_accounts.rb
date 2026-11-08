# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:accounts) do
      primary_key :id
      String :adapter, null: false, size: 32
      String :name, null: false, size: 64
      String :settings, text: true, null: false, default: "{}"
      String :source, null: false, size: 32, default: "dashboard"
      DateTime :created_at, null: false
      DateTime :updated_at, null: false
      index %i[adapter name], unique: true, name: :accounts_identity_idx
    end
  end
end
