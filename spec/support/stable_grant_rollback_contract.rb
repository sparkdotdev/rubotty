# frozen_string_literal: true

RSpec.shared_examples "stable grant rollback safety" do
  def migrate_grant_schema
    Rubotty::ControlPlane::Migrator.new(db).run(target: 102)
  end

  {
    dashboard_administrators: [:adapter],
    dashboard_viewers: [:adapter],
    community_viewers: %i[community_id adapter]
  }.each do |table, scope|
    it "refuses duplicate legacy keys on #{table} before changing the schema" do
      migrate_grant_schema
      values = { adapter: "matrix", handle: "@duplicate:example.org", granted_at: Time.now }
      values[:community_id] = 1 if scope.include?(:community_id)
      2.times { db[table].insert(values) }

      expect { Rubotty::ControlPlane::Migrator.new(db).run(target: 101) }
        .to raise_error(Rubotty::StorageError, /export and remove privileged grants/)
      expect(db[table].count).to eq(2)
      expect(db.schema(table).map(&:first)).to include(:native_id)
    end

    it "restores distinct legacy keys on #{table} without confusing another scope for a duplicate" do
      migrate_grant_schema
      values = { adapter: "matrix", handle: "@same-label:example.org", granted_at: Time.now }
      values[:community_id] = 1 if scope.include?(:community_id)
      db[table].insert(values)
      other = scope.include?(:community_id) ? values.merge(community_id: 2) : values.merge(adapter: "telegram")
      db[table].insert(other)

      Rubotty::ControlPlane::Migrator.new(db).run(target: 101)

      expect(db[table].count).to eq(2)
      expect(db.schema(table).map(&:first)).not_to include(:native_id)
      expect { db[table].insert(values) }.to raise_error(Sequel::UniqueConstraintViolation)
    end

    it "refuses a bound native identity on #{table} without discarding it" do
      migrate_grant_schema
      values = { adapter: "matrix", handle: "@bound:example.org", native_id: "@Bound:Example.org", granted_at: Time.now }
      values[:community_id] = 1 if scope.include?(:community_id)
      db[table].insert(values)

      expect { Rubotty::ControlPlane::Migrator.new(db).run(target: 101) }
        .to raise_error(Rubotty::StorageError, /export and remove privileged grants/)
      expect(db[table].first[:native_id]).to eq("@Bound:Example.org")
    end
  end
end
