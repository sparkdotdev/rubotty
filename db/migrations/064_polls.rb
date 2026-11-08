# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:polls) do
      primary_key :id
      foreign_key :community_id, :communities, null: false, on_delete: :cascade
      foreign_key :room_id,      :rooms,       null: false, on_delete: :cascade
      String :kind,     null: false, size: 16
      String :question, null: false, size: 500
      String :detail,   size: 200
      String :timezone, size: 64
      TrueClass :multi_select,  null: false, default: false
      TrueClass :reply_votes,   null: false, default: true
      TrueClass :reply_options, null: false, default: false
      DateTime :closes_at, null: false
      String :status, null: false, size: 16, default: "open"
      String :created_by, size: 200
      # What the six-hourly repost is measured from.
      DateTime :last_posted_at
      DateTime :created_at, null: false
      DateTime :updated_at, null: false
      index %i[status closes_at], name: :polls_open_idx
      index %i[community_id room_id], name: :polls_room_idx
    end

    create_table(:poll_options) do
      primary_key :id
      foreign_key :poll_id, :polls, null: false, on_delete: :cascade
      Integer :position, null: false
      String  :label,    null: false, size: 200
      # Only a scheduling poll fills this in.
      DateTime :starts_at
      String   :suggested_by, size: 200
      DateTime :created_at, null: false
      index %i[poll_id position], unique: true, name: :poll_options_position_idx
    end

    create_table(:poll_votes) do
      primary_key :id
      foreign_key :poll_id,   :polls,        null: false, on_delete: :cascade
      foreign_key :option_id, :poll_options, null: false, on_delete: :cascade
      String :identity, null: false, size: 200
      String :platform, null: false, size: 32
      # Kept alongside the identity so rendering never goes back to the platform.
      String   :handle, size: 200
      DateTime :voted_at, null: false
      index %i[poll_id option_id identity], unique: true, name: :poll_votes_identity_idx
      index [:poll_id], name: :poll_votes_poll_idx
      index [:option_id], name: :poll_votes_option_idx
    end

    create_table(:poll_cards) do
      primary_key :id
      foreign_key :poll_id, :polls, null: false, on_delete: :cascade
      String :endpoint_id, null: false, size: 200
      String :native_id,   null: false, size: 200
      DateTime :created_at, null: false
      index %i[endpoint_id native_id], unique: true, name: :poll_cards_native_idx
      index [:poll_id], name: :poll_cards_poll_idx
    end
  end

  down do
    drop_table(:poll_cards)
    drop_table(:poll_votes)
    drop_table(:poll_options)
    drop_table(:polls)
  end
end
