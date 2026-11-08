# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:dashboard_action_permissions) do
      primary_key :id
      String :action, null: false, unique: true
      TrueClass :operator_writable, null: false, default: false
      DateTime :created_at, null: false
      DateTime :updated_at, null: false
    end
  end
end