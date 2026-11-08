# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:audit_events) do
      primary_key :id
      String   :community, null: false, size: 64
      String   :source, null: false, size: 64
      String   :action, null: false, size: 48
      String   :adapter, size: 32
      String   :channel, size: 255
      String   :actor, size: 200
      String   :actor_native_id, size: 255
      String   :subject, size: 200
      String   :subject_native_id, size: 255
      String   :target_ref, size: 255
      String   :reason, text: true
      String   :outcome, size: 64
      String   :metadata, text: true
      DateTime :created_at, null: false
      index %i[community created_at], name: :audit_events_community_time_idx
      index %i[community subject_native_id], name: :audit_events_subject_idx
    end
  end
end
