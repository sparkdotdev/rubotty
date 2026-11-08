# frozen_string_literal: true

require "spec_helper"
require "sequel"

# A bot cannot open a conversation on Telegram, so a warning issued to somebody
# who has never written in reaches nobody and used to be lost with only an audit
# line to say it existed. This keeps it until they write, and no longer than the
# warning it is about.
RSpec.describe Rubotty::ControlPlane::UndeliveredDms, :control_plane do
  let(:db) { Sequel.sqlite }
  let(:models) { Rubotty::ControlPlane.models(db) }
  let(:now) { Time.utc(2026, 8, 28, 12, 0, 0) }
  let(:clock) { -> { now } }
  let(:community) do
    models.community.create(slug: "first", name: "First", status: "active",
                            created_at: now, updated_at: now)
  end

  subject(:store) { described_class.new(models: models, logger: Rubotty::Log.null, clock: clock) }

  before { Rubotty::ControlPlane::Migrator.run(db) }

  def keep(native_id: "u9", body: "you were warned", expires_at: now + 600, event: "a warning")
    store.retain(community_id: community.id, adapter: :telegram, account: "bot",
                 native_id: native_id, display: "Ada", body: body, event: event,
                 expires_at: expires_at)
  end

  def owed(native_id: "u9") = store.pending_for(adapter: :telegram, account: "bot", native_id: native_id)

  it "keeps what could not be sent, and hands it back for that person" do
    keep

    expect(owed.map(&:body)).to eq(["you were warned"])
  end

  it "keeps them apart per person, so nobody reads somebody else's notice" do
    keep(native_id: "u9", body: "for ada")
    keep(native_id: "u10", body: "for mel")

    expect(owed(native_id: "u9").map(&:body)).to eq(["for ada"])
    expect(owed(native_id: "u10").map(&:body)).to eq(["for mel"])
  end

  it "answers with nothing on another connection, since a native id means nothing across platforms" do
    keep

    expect(store.pending_for(adapter: :discord, account: "bot", native_id: "u9")).to be_empty
  end

  # The whole retention promise: a notice about a warning that has since
  # decayed is never delivered late.
  it "withholds one whose warning has already lapsed, and prunes it" do
    keep(expires_at: now - 1)

    expect(owed).to be_empty
    expect(store.prune).to eq(1)
  end

  it "stops offering one once it has actually gone out" do
    keep
    store.delivered!(owed.first)

    expect(owed).to be_empty
  end

  it "leaves one still owed when the send was refused, so the next contact retries it" do
    keep

    expect(owed.length).to eq(1)
    expect(owed.first.delivered_at).to be_nil
  end

  it "hands them back oldest first, so a member reads them in the order they were written" do
    keep(body: "first")
    later = described_class.new(models: models, logger: Rubotty::Log.null, clock: -> { now + 60 })
    later.retain(community_id: community.id, adapter: :telegram, account: "bot", native_id: "u9",
                 display: "Ada", body: "second", event: "a warning", expires_at: now + 600)

    expect(owed.map(&:body)).to eq(%w[first second])
  end

  it "bounds one contact, so somebody returning to a long history is not buried" do
    (described_class::FLUSH_LIMIT + 3).times { |i| keep(body: "note #{i}") }

    expect(owed.length).to eq(described_class::FLUSH_LIMIT)
  end

  # A community can set a long decay, and a row must not outlive the retention
  # the document promises whatever it sets.
  it "caps retention however far off the warning's own expiry is" do
    row = keep(expires_at: now + (400 * 86_400))

    expect(row.expires_at).to be <= now + (described_class::MAX_RETENTION_DAYS * 86_400)
  end

  it "keeps nothing without a recipient or a body, since neither could ever be sent" do
    expect(keep(native_id: "")).to be_nil
    expect(keep(body: "")).to be_nil
  end
end
