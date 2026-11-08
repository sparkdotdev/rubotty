# frozen_string_literal: true

require "spec_helper"
require "sequel"

# With no timezone configured, Sequel stores a DateTime column's wall-clock
# digits and hands them back tagged with the reading process's own zone. Every
# expiry gate in the deployment then depends on all containers agreeing on TZ;
# disagreement looks like wrong data rather than a wrong clock.
RSpec.describe "the database timezone" do
  let(:db) do
    db = Sequel.sqlite
    db.create_table(:gates) do
      primary_key :id
      DateTime :expires_at, null: false
    end
    db
  end

  it "is pinned to UTC on all three of Sequel's knobs" do
    Rubotty::Storage::Factory.use_utc!

    expect(Sequel.database_timezone).to eq(:utc)
    expect(Sequel.application_timezone).to eq(:utc)
    expect(Sequel.typecast_timezone).to eq(:utc)
  end

  it "round-trips a Time as the same instant, whatever zone it was written in" do
    written = Time.new(2027, 1, 15, 8, 0, 0, "+09:00")
    db[:gates].insert(expires_at: written)

    expect(db[:gates].first[:expires_at]).to eq(written)
  end

  it "reads the same instant back for a row written in another zone" do
    east = Time.new(2027, 1, 15, 8, 0, 0, "+09:00")
    west = Time.new(2027, 1, 14, 18, 0, 0, "-05:00")
    expect(east).to eq(west) # the same instant, spelled two ways

    db[:gates].insert(expires_at: east)

    expect(db[:gates].first[:expires_at]).to eq(west)
  end

  it "hands back a UTC Time, so a comparison in a reader's own zone is right" do
    db[:gates].insert(expires_at: Time.new(2027, 1, 15, 8, 0, 0, "+09:00"))

    stored = db[:gates].first[:expires_at]
    expect(stored.utc?).to be(true)
    # 23:00 UTC on the 14th is before the row, 00:00 on the 15th is after, and
    # neither answer depends on what TZ this process was started with.
    expect(stored).to be > Time.utc(2027, 1, 14, 22, 0, 0)
    expect(stored).to be < Time.utc(2027, 1, 15, 0, 0, 0)
  end

  it "is already set for a control-plane database, since migrate! sets it" do
    Sequel.default_timezone = nil
    Rubotty::ControlPlane.migrate!(Sequel.sqlite)

    expect(Sequel.database_timezone).to eq(:utc)
  ensure
    Rubotty::Storage::Factory.use_utc!
  end
end
