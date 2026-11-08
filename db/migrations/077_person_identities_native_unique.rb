# frozen_string_literal: true

# person_for (BridgedNicknames) does a read-then-create on (adapter,
# native_id) and only rescues Sequel::UniqueConstraintViolation, so it needs
# a real unique index to raise that. (adapter, native_id) alone is not
# unique though: the same platform account legitimately holds separate
# person_identity rows in separate communities, the same way
# observed_identities scopes its own handle uniqueness by community_id. So
# community_id (read off the row's person) joins the index here too, nullable
# so a row nothing has backfilled yet merely opts out rather than breaking the insert.
Sequel.migration do
  up do
    alter_table(:person_identities) do
      add_foreign_key :community_id, :communities, on_delete: :cascade
    end

    people_community = self[:people].to_hash(:id, :community_id)
    seen = {}
    self[:person_identities].order(:id).each do |row|
      community_id = people_community[row[:person_id]]
      next if community_id.nil?

      key = [community_id, row[:adapter], row[:native_id]]
      if row[:native_id] && seen[key]
        # A race already got here first: drop the later duplicate rather than
        # fail the migration, the same call this table's siblings made in 074.
        self[:person_identities].where(id: row[:id]).delete
        next
      end
      seen[key] = true if row[:native_id]
      self[:person_identities].where(id: row[:id]).update(community_id: community_id)
    end

    alter_table(:person_identities) do
      add_index %i[community_id adapter native_id], unique: true, name: :person_identities_community_native_idx
    end
  end

  down do
    # The foreign key has to go before the index: MariaDB reuses a compound
    # index as an FK's own supporting index whenever the FK's column leads it,
    # and refuses to drop that index out from under a constraint still using
    # it. Migration 016 hits the same ordering for the same reason.
    alter_table(:person_identities) { drop_foreign_key [:community_id] }
    alter_table(:person_identities) do
      drop_index %i[community_id adapter native_id], name: :person_identities_community_native_idx
    end
    alter_table(:person_identities) { drop_column :community_id }
  end
end
