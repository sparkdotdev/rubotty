# frozen_string_literal: true

Sequel.migration do
  up do
    partial_unique_indexes = Rubotty::Storage::Dialect.for(self).partial_indexes?

    create_table(:dashboard_viewers) do
      primary_key :id

      String :adapter, null: false, size: 32
      String :handle, null: false, size: 255
      String :label, size: 200

      DateTime :granted_at, null: false
      String :granted_by, size: 200

      index %i[adapter handle], unique: true, name: :dashboard_viewers_unique_idx
    end

    create_table(:dashboard_viewer_requests) do
      primary_key :id

      String :adapter, null: false, size: 32
      String :requester_native_id, null: false, size: 255
      String :requester_username, size: 200
      String :requester_display, size: 200
      String :state, null: false, size: 16, default: "pending"

      DateTime :requested_at, null: false
      DateTime :decided_at
      String :decided_by, size: 200

      index [:state], name: :dashboard_viewer_requests_state_idx
      if partial_unique_indexes
        index %i[adapter requester_native_id state], unique: true,
              name: :dashboard_viewer_requests_open_idx, where: { state: "pending" }
      else
        index %i[adapter requester_native_id state], name: :dashboard_viewer_requests_open_idx
      end
    end
  end

  down do
    drop_table?(:dashboard_viewer_requests)
    drop_table?(:dashboard_viewers)
  end
end
