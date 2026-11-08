# frozen_string_literal: true

require "spec_helper"
require "sequel"

# Verifies the SQL the store generates without needing a database, covering what
# breaks silently on a laptop: SQL a backend will not accept, or a query that
# quietly matches the wrong rows. CI runs the behavioural contract on a real server.
RSpec.describe Rubotty::Storage::SequelStore, "SQL generation" do
  let(:db) { Sequel.mock(host: "postgres", fetch: []) }
  subject(:store) { described_class.new(db: db) }

  def sql_for
    db.sqls.clear
    yield
    db.sqls
  end

  it "creates the table and its indexes" do
    allow(db).to receive(:table_exists?).and_return(false)
    allow(db).to receive(:indexes).and_return({})
    statements = sql_for { Rubotty::Storage::Schema.apply(db) }
    joined = statements.join(" ")
    expect(joined).to include("CREATE TABLE")
    expect(joined).to include("message_map_pair_idx")
    # The unique index is what makes record idempotent.
    expect(joined).to include("CREATE UNIQUE INDEX")
  end

  it "does not recreate an existing table" do
    allow(db).to receive(:table_exists?).and_return(true)
    allow(db).to receive(:indexes).and_return(
      {
        message_map_pair_idx: {}, message_map_source_idx: {},
        message_map_destination_idx: {}, message_map_expiry_idx: {},
        reaction_state_unique_idx: {}, reaction_state_message_idx: {},
        reaction_state_expiry_idx: {},
        relay_claims_unique_idx: {}, relay_claims_expiry_idx: {},
        multipost_fingerprints_unique_idx: {}, multipost_fingerprints_key_idx: {},
        multipost_fingerprints_expiry_idx: {}
      }
    )
    expect(sql_for { Rubotty::Storage::Schema.apply(db) }).to be_empty
  end

  it "creates the relay claim table with a unique key that guarantees one winner" do
    allow(db).to receive(:table_exists?).and_return(false)
    allow(db).to receive(:indexes).and_return({})
    joined = sql_for { Rubotty::Storage::Schema.apply(db) }.join(" ")
    expect(joined).to include("relay_claims")
    # The unique index over the whole key is what leaves two concurrent claims one
    # winner.
    expect(joined).to include("relay_claims_unique_idx")
    expect(joined).to include("CREATE UNIQUE INDEX")
  end

  # A plain INSERT trips the unique index so the loser can be told. An upsert would
  # let the duplicate succeed.
  it "claims a source event with a plain insert so a duplicate loses the race" do
    statements = sql_for do
      store.claim_relay(source: ref("tg", "5"), operation: "new", community: "c1")
    end
    expect(statements.first).to include("INSERT INTO")
    expect(statements.first).to include("relay_claims")
    expect(statements.first).not_to include("ON CONFLICT")
  end

  it "releases a claim by deleting exactly its row" do
    statements = sql_for do
      store.release_relay(source: ref("tg", "5"), operation: "new", community: "c1")
    end
    expect(statements.first).to include("DELETE")
    expect(statements.first).to include("relay_claims")
    expect(statements.first).to include("operation")
  end

  it "creates the reaction state table with a uniqueness guarantee per actor" do
    allow(db).to receive(:table_exists?).and_return(false)
    allow(db).to receive(:indexes).and_return({})
    joined = sql_for { Rubotty::Storage::Schema.apply(db) }.join(" ")
    expect(joined).to include("reaction_state")
    expect(joined).to include("reaction_state_unique_idx")
  end

  # Idempotency of record is what allows a retry after a partial failure.
  it "uses an upsert so a repeated record does not duplicate" do
    statements = sql_for do
      store.record(source: ref("tg", "1"), destination: ref("dc", "2"), room_id: "r")
    end
    expect(statements.first).to include("ON CONFLICT")
    expect(statements.first).to include("DO UPDATE")
  end

  it "filters expired rows on every read, not only on purge" do
    statements = sql_for { store.counterparts(ref("tg", "1")) }
    expect(statements.first).to include("expires_at")
  end

  it "narrows counterparts to one endpoint when asked" do
    statements = sql_for { store.counterparts(ref("tg", "1"), endpoint_id: "dc") }
    expect(statements.first).to include("destination_endpoint")
  end

  it "matches both sides when forgetting a ref" do
    statements = sql_for { store.forget(ref("tg", "1")) }
    expect(statements.first).to include("DELETE")
    expect(statements.first).to include("source_endpoint")
    expect(statements.first).to include("destination_endpoint")
  end

  it "never purges rows that have no expiry" do
    statements = sql_for { store.purge }
    expect(statements.first).to include("IS NOT NULL")
  end

  it "wraps a backend failure in a StorageError rather than leaking Sequel" do
    allow(db).to receive(:[]).and_raise(Sequel::DatabaseError, "connection lost")
    expect { store.counterparts(ref("tg", "1")) }.to raise_error(Rubotty::StorageError)
  end
end

# The same store and code on a different dialect: MariaDB spells the upsert ON
# DUPLICATE KEY UPDATE and the dialect seam routes to it. Checked on a mock so a
# laptop with no MariaDB catches a regression that would otherwise wait for a real server.
RSpec.describe Rubotty::Storage::SequelStore, "SQL generation on MariaDB" do
  let(:db) { Sequel.mock(host: "mysql", fetch: []) }
  subject(:store) { described_class.new(db: db) }

  def first_sql
    db.sqls.clear
    yield
    db.sqls.first
  end

  it "records with ON DUPLICATE KEY UPDATE rather than ON CONFLICT" do
    sql = first_sql { store.record(source: ref("tg", "1"), destination: ref("dc", "2"), room_id: "r") }
    expect(sql).to include("ON DUPLICATE KEY UPDATE")
    expect(sql).not_to include("ON CONFLICT")
  end

  it "upserts durable state with ON DUPLICATE KEY UPDATE" do
    sql = first_sql { store.put_state("k", "v") }
    expect(sql).to include("ON DUPLICATE KEY UPDATE")
    expect(sql).to include("bridge_state")
  end

  it "still claims a relay with a plain insert so a duplicate trips the unique key" do
    sql = first_sql { store.claim_relay(source: ref("tg", "5"), operation: "new", community: "c1") }
    expect(sql).to include("INSERT INTO")
    expect(sql).not_to include("ON DUPLICATE KEY UPDATE")
  end
end

# The ephemeral store's durable write is an upsert too, and it spelled ON CONFLICT
# inline until it raised on MariaDB in production, breaking the startup banner and
# leaving every moderation acknowledgement in the channel forever. Same mock-dialect
# check as the message map above, so a laptop with no MariaDB catches a repeat.
RSpec.describe Rubotty::Core::EphemeralStore::Sequel, "SQL generation per dialect" do
  def add_sql(host)
    db = Sequel.mock(host: host, fetch: [])
    store = described_class.new(db: db)
    db.sqls.clear
    store.add(group_id: "g", endpoint_id: "tg", native_id: "1",
              delete_at: Time.now, session_id: "s", channel: "{}")
    db.sqls.first
  end

  it "records a pending deletion with ON DUPLICATE KEY UPDATE on MariaDB" do
    sql = add_sql("mysql")
    expect(sql).to include("ephemeral_messages")
    expect(sql).to include("ON DUPLICATE KEY UPDATE")
    expect(sql).not_to include("ON CONFLICT")
  end

  it "records a pending deletion with ON CONFLICT DO UPDATE on Postgres" do
    sql = add_sql("postgres")
    expect(sql).to include("ephemeral_messages")
    expect(sql).to include("ON CONFLICT")
    expect(sql).to include("DO UPDATE")
  end

  it "overwrites every mutable column on a conflict, on either dialect" do
    %w[mysql postgres].each do |host|
      sql = add_sql(host)
      %w[group_id channel delete_at session_id].each do |column|
        expect(sql.scan(column).size).to be > 1, "expected #{column} in the conflict update on #{host}"
      end
    end
  end
end
