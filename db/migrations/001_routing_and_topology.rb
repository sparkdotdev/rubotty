# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:communities) do
      primary_key :id
      String   :slug,   null: false, size: 64      # dashboard handle, e.g. "sample"
      String   :name,   null: false, size: 200
      String   :status, null: false, size: 32, default: "active"  # active | suspended
      String   :settings, text: true, null: false, default: "{}"  # community-wide defaults (JSON)
      String   :bootstrap_source, size: 200                        # e.g. "bridge.config.yaml"
      DateTime :created_at, null: false
      DateTime :updated_at, null: false
      index [:slug], unique: true, name: :communities_slug_idx
    end

    create_table(:platform_connections) do
      primary_key :id
      foreign_key :community_id, :communities, null: false, on_delete: :cascade
      String   :adapter,     null: false, size: 32     # telegram | discord
      String   :account,     null: false, size: 64     # which credential (shared token) serves it
      String   :external_id, null: false, size: 255    # telegram chat_id (supergroup), discord guild_id
      String   :label,       size: 200
      DateTime :created_at,  null: false
      DateTime :updated_at,  null: false
      index %i[adapter account external_id], unique: true, name: :platform_conn_addr_idx
      index [:community_id], name: :platform_conn_community_idx
    end

    create_table(:channels) do
      primary_key :id
      foreign_key :community_id,           :communities,          null: false, on_delete: :cascade
      foreign_key :platform_connection_id, :platform_connections, null: false, on_delete: :cascade
      String   :adapter,      null: false, size: 32
      String   :account,      null: false, size: 64
      String   :route_key,    null: false, size: 255
      String   :endpoint_key, null: false, size: 128
      String   :label,        size: 200
      TrueClass :receives,    null: false, default: true
      TrueClass :sends,       null: false, default: true
      String   :relay,        text: true, null: false, default: "{}"  # per-endpoint relay policy (JSON)
      String   :display_name, text: true, null: false, default: "{}"  # sender name template overrides (JSON)
      String   :settings,     text: true, null: false, default: "{}"  # adapter addressing + owned keys (JSON)
      DateTime :created_at,   null: false
      DateTime :updated_at,   null: false
      index %i[adapter account route_key], unique: true, name: :channels_route_idx
      index [:endpoint_key], unique: true, name: :channels_endpoint_key_idx
      index [:community_id], name: :channels_community_idx
    end

    create_table(:rooms) do
      primary_key :id
      foreign_key :community_id, :communities, null: false, on_delete: :cascade
      String   :room_key,     null: false, size: 128   # stable id, becomes Core::Room#id (e.g. "general")
      String   :label,        size: 200
      String   :display_name, text: true, null: false, default: "{}"  # room-level name template overrides (JSON)
      DateTime :created_at,   null: false
      DateTime :updated_at,   null: false
      index %i[community_id room_key], unique: true, name: :rooms_key_idx
      index [:community_id], name: :rooms_community_idx
    end

    create_table(:room_channels) do
      primary_key :id
      foreign_key :room_id,    :rooms,    null: false, on_delete: :cascade
      foreign_key :channel_id, :channels, null: false, on_delete: :cascade
      DateTime :created_at, null: false
      index %i[room_id channel_id], unique: true, name: :room_channels_unique_idx
      index [:channel_id], name: :room_channels_channel_idx
    end
  end
end
