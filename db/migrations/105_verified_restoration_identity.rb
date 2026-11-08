# frozen_string_literal: true

# Old rows name only the target platform, so the original identity namespace
# cannot be proven. Keep their message tracking but grant no deletion authority.
Sequel.migration do
  up do
    alter_table(:content_policy_reposts) do
      add_column :identity_verified, TrueClass, null: false, default: false
    end
  end

  down do
    unless self[:content_policy_reposts].empty?
      raise Sequel::Error, "resolve restoration tracking before rolling back verified deletion identities"
    end

    alter_table(:content_policy_reposts) do
      drop_column :identity_verified
    end
  end
end
