# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:channels) do
      drop_index %i[adapter account route_key], name: :channels_route_idx
      add_index %i[adapter account route_key], name: :channels_route_idx
    end

    next unless Rubotty::Storage::Dialect.for(self).partial_indexes?

    alter_table(:channels) do
      add_index %i[adapter account route_key], unique: true,
                name: :channels_route_receiving_idx, where: { receives: true }
    end
  end

  down do
    if Rubotty::Storage::Dialect.for(self).partial_indexes?
      alter_table(:channels) do
        drop_index %i[adapter account route_key], name: :channels_route_receiving_idx
      end
    end

    alter_table(:channels) do
      drop_index %i[adapter account route_key], name: :channels_route_idx
      add_index %i[adapter account route_key], unique: true, name: :channels_route_idx
    end
  end
end
