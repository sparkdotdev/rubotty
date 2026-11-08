# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:communities) do
      add_index [:updated_at], name: :communities_updated_at_idx
    end
    alter_table(:rooms) do
      add_index [:updated_at], name: :rooms_updated_at_idx
    end
    alter_table(:channels) do
      add_index [:updated_at], name: :channels_updated_at_idx
    end
    alter_table(:room_channels) do
      add_index [:created_at], name: :room_channels_created_at_idx
    end
    alter_table(:operators) do
      add_index [:granted_at], name: :operators_granted_at_idx
    end
  end
end
