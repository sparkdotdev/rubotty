# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:irc_networks) do
      primary_key :id
      foreign_key :community_id, :communities, null: false, on_delete: :cascade
      String    :name, null: false, size: 64
      String    :host, null: false, size: 255
      Integer   :port, null: false, default: 6697
      TrueClass :tls,  null: false, default: true
      String    :nick, null: false, size: 128
      String :sasl_user, size: 128
      String :sasl_password_env, size: 128
      String   :channels, text: true, null: false, default: "[]"
      DateTime :created_at, null: false
      DateTime :updated_at, null: false
      index %i[community_id name], unique: true, name: :irc_networks_name_idx
      index [:community_id], name: :irc_networks_community_idx
    end
  end
end
