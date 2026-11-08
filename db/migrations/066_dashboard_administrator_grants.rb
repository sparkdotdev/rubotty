# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:dashboard_administrators) do
      primary_key :id

      String :adapter, null: false, size: 32
      String :handle, null: false, size: 255
      String :label, size: 200

      DateTime :granted_at, null: false
      String :granted_by, size: 200

      index %i[adapter handle], unique: true, name: :dashboard_administrators_unique_idx
    end

    # A token can already hand over operator and viewer; this is the third
    # column, and it is only ever set on a deployment-wide token.
    alter_table(:auth_tokens) do
      add_column :grants_administrator, TrueClass, null: false, default: false
    end
  end

  down do
    alter_table(:auth_tokens) do
      drop_column :grants_administrator
    end
    drop_table?(:dashboard_administrators)
  end
end
