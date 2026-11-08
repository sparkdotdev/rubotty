# frozen_string_literal: true

Sequel.migration do
  up do
    {
      dashboard_administrators: [:adapter],
      dashboard_viewers: [:adapter],
      community_viewers: %i[community_id adapter]
    }.each do |table, scope|
      native_options = { size: 255 }
      # Existing tables may predate the deployment's binary default collation.
      native_options[:collate] = "utf8mb4_bin" if database_type == :mysql
      alter_table(table) do
        add_column :native_id, String, **native_options
        drop_index [*scope, :handle], name: :"#{table}_unique_idx"
        add_index [*scope, :native_id], unique: true, name: :"#{table}_native_unique_idx"
      end

      # Legacy labels were normalised, including Matrix MXIDs. Lost identity
      # case cannot be recovered from a label; every legacy row needs regrant.
    end
  end

  down do
    tables = {
      dashboard_administrators: [:adapter],
      dashboard_viewers: [:adapter],
      community_viewers: %i[community_id adapter]
    }
    # Refuse to discard a binding or collapse recycled labels. Empty databases
    # remain reversible for disposable validation and migration-chain checks.
    tables.each do |table, scope|
      bound = self[table].exclude(native_id: nil).count.positive?
      keys = [*scope, :handle]
      duplicate = self[table].select(*keys).group(*keys).having { count.function.* > 1 }.count.positive?
      if bound || duplicate
        raise Sequel::Error, "export and remove privileged grants before rolling back stable grant identities"
      end
    end
    tables.each do |table, scope|
      alter_table(table) do
        drop_index [*scope, :native_id], name: :"#{table}_native_unique_idx"
        drop_column :native_id
        add_index [*scope, :handle], unique: true, name: :"#{table}_unique_idx"
      end
    end
  end
end
