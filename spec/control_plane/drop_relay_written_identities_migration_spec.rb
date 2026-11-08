# frozen_string_literal: true

require "spec_helper"
require "sequel"

# Migration 074: clears the observed identities that were never people, the
# rows a bridge's own puppeted copies wrote about themselves before the
# recorder started skipping bot authors. Seeds rows at the schema version just
# before the migration, since that is the shape a live directory really holds.
RSpec.describe "drop_relay_written_identities migration", :control_plane do
  let(:db) { Sequel.sqlite }
  let(:now) { Time.now }

  before { Rubotty::ControlPlane::Migrator.new(db).run(target: 73) }

  let(:community_id) do
    db[:communities].insert(slug: "c", name: "C", status: "active", settings: "{}", created_at: now, updated_at: now)
  end

  def insert_identity(native_id:, username:, display_name: nil, adapter: "discord")
    db[:observed_identities].insert(
      community_id: community_id, adapter: adapter, native_id: native_id,
      username: username, display_name: display_name, first_seen_at: now, last_seen_at: now
    )
  end

  def run_migration! = Rubotty::ControlPlane::Migrator.new(db).run(target: 74)

  def handles = db[:observed_identities].select_map(:username)

  it "drops a row whose handle is the label a relay posts a copy under" do
    insert_identity(native_id: "hook-1", username: "wren okafor [wrenzo@telegram]",
                    display_name: "Wren Okafor [wrenzo@telegram]")
    run_migration!

    expect(handles).to be_empty
  end

  it "drops the second copy of the same label written by another channel's relay" do
    insert_identity(native_id: "hook-1", username: "wren okafor [wrenzo@telegram]")
    insert_identity(native_id: "hook-2", username: "wren okafor [wrenzo@telegram]")
    run_migration!

    expect(handles).to be_empty
  end

  it "drops a federated label carrying its protocol qualifier" do
    insert_identity(native_id: "hook-3", username: "wren okafor [matrix::wrenzo@example.org]")
    run_migration!

    expect(handles).to be_empty
  end

  it "keeps a genuine person, handle and display name both" do
    insert_identity(native_id: "901", username: "wrenzo", display_name: "Wren Okafor")
    run_migration!

    expect(handles).to eq(["wrenzo"])
  end

  it "keeps a person whose display name imitates the label, since only the handle is keyed on" do
    insert_identity(native_id: "902", username: "wrenzo", display_name: "Wren Okafor [wrenzo@telegram]")
    run_migration!

    expect(handles).to eq(["wrenzo"])
  end

  it "keeps a handle that merely brackets a suffix, the way an IRC nick can" do
    insert_identity(native_id: "903", username: "wrenzo[away]", adapter: "irc")
    run_migration!

    expect(handles).to eq(["wrenzo[away]"])
  end

  it "keeps an address-shaped handle, which a federated platform really issues" do
    insert_identity(native_id: "904", username: "wrenzo@example.org", adapter: "xmpp")
    run_migration!

    expect(handles).to eq(["wrenzo@example.org"])
  end

  it "keeps a row with no handle at all rather than guessing from the display name" do
    insert_identity(native_id: "905", username: nil, display_name: "Wren Okafor [wrenzo@telegram]")
    run_migration!

    expect(db[:observed_identities].count).to eq(1)
  end
end
