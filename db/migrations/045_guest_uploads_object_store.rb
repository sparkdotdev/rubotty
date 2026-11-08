# frozen_string_literal: true

Sequel.migration do
  up do
    self[:guest_uploads].delete

    alter_table(:guest_uploads) do
      rename_column :token, :token_hash

      add_column :object_key, String, size: 255, null: false, default: ""
      add_column :iv, String, size: 64, null: false, default: ""
      add_column :auth_tag, String, size: 64, null: false, default: ""
      add_column :sealed_bytes, Integer, null: false, default: 0

      drop_column :data
    end
  end

  down do
    self[:guest_uploads].delete

    alter_table(:guest_uploads) do
      drop_column :sealed_bytes
      drop_column :auth_tag
      drop_column :iv
      drop_column :object_key

      rename_column :token_hash, :token
    end

    alter_table(:guest_uploads) { add_column :data, String, text: true }
    self[:guest_uploads].update(data: "")
    alter_table(:guest_uploads) { set_column_not_null :data }
  end
end
