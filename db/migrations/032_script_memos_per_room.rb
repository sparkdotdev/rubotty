# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:script_memos) do
      add_column :room_key, String, null: false, default: "", size: 128
      add_index [:community_script_id], name: :script_memos_script_idx
      drop_index %i[community_script_id key], name: :script_memos_key_idx
      add_index %i[community_script_id room_key key], unique: true,
                                                      name: :script_memos_room_key_idx
    end
  end

  down do
    from(:script_memos).exclude(room_key: "").delete

    alter_table(:script_memos) do
      drop_index %i[community_script_id room_key key], name: :script_memos_room_key_idx
      add_index %i[community_script_id key], unique: true, name: :script_memos_key_idx
      drop_index [:community_script_id], name: :script_memos_script_idx
      drop_column :room_key
    end
  end
end
