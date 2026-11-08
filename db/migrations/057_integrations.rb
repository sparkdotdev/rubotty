# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:integrations) do
      primary_key :id

      String :name, null: false, size: 64

      String :url, size: 1000
      String :api_key, size: 500

      String :config, text: true

      DateTime :created_at, null: false
      DateTime :updated_at, null: false

      index [:name], unique: true, name: :integrations_name_idx
    end
  end
end
