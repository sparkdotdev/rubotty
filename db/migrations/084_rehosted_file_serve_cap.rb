# frozen_string_literal: true

# A rehosted link served anyone holding it, unlimited times, for the whole
# retention window. served_count and serve_limit let RehostedFiles refuse
# once a link passes its ceiling; see RehostedFiles#store_file and
# FileStorage::App#serve. 100 as the serve_limit default matches the flat
# ceiling every existing row gets on backfill, since none of them has ever
# been counted before now.
Sequel.migration do
  change do
    alter_table(:rehosted_files) do
      add_column :served_count, Integer, null: false, default: 0
      add_column :serve_limit, Integer, null: false, default: 100
    end
  end
end
