# frozen_string_literal: true

# The corpus held only false positives, because /vindicate was the only way
# into it: a policy that fired when it should not have. A miss is the same
# mistake from the other side, and tuning a description needs both, so a row
# now says which kind it is.
#
# Existing rows are all reversals, which is what the default says.
Sequel.migration do
  change do
    alter_table(:content_policy_misfires) do
      add_column :kind, String, size: 16, null: false, default: "false_positive"
      add_index %i[community_id kind], name: :content_policy_misfires_kind_idx
    end
  end
end
