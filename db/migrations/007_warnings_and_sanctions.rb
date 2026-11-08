# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:warnings) do
      primary_key :id
      String   :community, null: false, size: 64
      String   :adapter,           null: false, size: 32
      String   :subject_native_id, null: false, size: 255
      String   :subject_username, size: 200
      String   :subject_display,  size: 200
      String   :reason, text: true
      String   :issued_by, size: 200
      TrueClass :active, null: false, default: true
      DateTime :issued_at, null: false
      DateTime :deactivated_at
      index %i[community adapter subject_native_id active], name: :warnings_subject_idx
    end

    create_table(:active_sanctions) do
      primary_key :id
      String   :community,         null: false, size: 64
      String   :adapter,           null: false, size: 32
      String   :subject_native_id, null: false, size: 255
      String   :subject_username,  size: 200
      String   :action, null: false, size: 16
      String   :endpoints, text: true, null: false, default: "[]"
      DateTime :until_at, null: false
      String   :job_id, size: 64
      TrueClass :active, null: false, default: true
      DateTime :created_at, null: false
      DateTime :lifted_at
      index %i[community adapter subject_native_id active], name: :active_sanctions_subject_idx
    end
  end
end
