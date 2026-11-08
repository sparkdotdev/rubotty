# frozen_string_literal: true

# operator_requests.decided_by was a foreign key to operators.id, the only one
# of its kind: dashboard_viewer_requests, community_viewer_requests and
# operators.granted_by itself all use a free-text label instead. That FK meant
# a request approved or denied by a deployment-configured-only operator (no operators row
# to name) recorded nothing at all. Brings decided_by in line with its
# siblings; existing rows are relabelled from the operator they pointed at, so
# nothing already recorded is lost, only reformatted.
Sequel.migration do
  up do
    alter_table(:operator_requests) { add_column :decider_label, String, size: 200 }

    operators_by_id = self[:operators].select(:id, :person_id).all.to_h { |row| [row[:id], row[:person_id]] }
    people_by_id = self[:people].select(:id, :name).all.to_h { |row| [row[:id], row[:name]] }

    self[:operator_requests].exclude(decided_by: nil).each do |row|
      person_id = operators_by_id[row[:decided_by]]
      name = person_id && people_by_id[person_id]
      label = (name.nil? || name.strip.empty?) ? "operator:#{row[:decided_by]}" : name
      self[:operator_requests].where(id: row[:id]).update(decider_label: label)
    end

    # MariaDB alone refuses to drop a column still backing a foreign key's
    # index, where Postgres and SQLite drop the constraint with the column.
    # Guarded to MariaDB alone: run unguarded on SQLite and this same call
    # rebuilds the whole table, silently dropping the partial unique index migration 002 added.
    alter_table(:operator_requests) { drop_foreign_key [:decided_by] } if database_type == :mysql

    alter_table(:operator_requests) do
      drop_column :decided_by
      rename_column :decider_label, :decided_by
    end
  end

  down do
    # Lossy going forward too: a label naming a deployment-configured-only approver has no
    # operators row to point back at, so the FK is restored empty rather than
    # guessed at.
    alter_table(:operator_requests) do
      drop_column :decided_by
      add_foreign_key :decided_by, :operators, on_delete: :set_null
    end
  end
end
