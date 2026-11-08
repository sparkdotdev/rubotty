# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:irc_networks) do
      add_column :mode, String, size: 16, null: false, default: "per_room"
      add_column :hub_channel, String, size: 255
      add_column :channel_keys, String, text: true, null: false, default: "{}"
    end
  end
end
