# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:dashboard_appearances) do
      primary_key :id

      String :name, null: false, size: 32
      String :theme, null: false, size: 64
      String :swatch, null: false, size: 64
      String :chart_style, null: false, size: 64
      DateTime :created_at, null: false
      DateTime :updated_at, null: false

      index [:name], unique: true, name: :dashboard_appearances_name_idx
    end
  end
end
