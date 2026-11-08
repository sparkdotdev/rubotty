# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:script_memos) do
      add_column :scope, String, size: 96
      set_column_allow_null :community_script_id
    end

    from(:script_memos).update(scope: Sequel.join(["s:", Sequel.cast(:community_script_id, String)]))

    alter_table(:script_memos) do
      drop_index %i[community_script_id room_key key], name: :script_memos_room_key_idx
      add_index %i[community_id scope room_key key], unique: true, name: :script_memos_scope_idx
    end
  end

  down do
    from(:script_memos).where(community_script_id: nil).delete

    alter_table(:script_memos) do
      add_index [:community_id], name: :script_memos_community_idx
      drop_index %i[community_id scope room_key key], name: :script_memos_scope_idx
      add_index %i[community_script_id room_key key], unique: true, name: :script_memos_room_key_idx
      drop_column :scope
    end

    alter_table(:script_memos) do
      set_column_not_null :community_script_id
    end
  end
end
