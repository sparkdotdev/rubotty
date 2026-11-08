# frozen_string_literal: true

# What "the same shape" means when two schemas are compared: column names with
# their null-ness and type, plus index names.
module SchemaShape
  module_function

  # The shape of one table.
  def of(db, table)
    columns = db.schema(table).to_h do |name, info|
      [name, { null: info[:allow_null], type: info[:type] }]
    end
    { columns: columns, indexes: db.indexes(table, include_partial: true).keys.sort }
  end

  # Every table in the database, keyed by name, minus the migrator's own bookkeeping.
  def all(db)
    (db.tables - [:schema_info]).sort.to_h { |table| [table, of(db, table)] }
  end
end
