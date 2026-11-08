# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::ControlPlane::ReportLane, :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:community) { models.community.first }
  let(:registry) { Rubotty::ControlPlane::Registry.new(models: models) }
  let(:reports) { Rubotty::ControlPlane::MemberReports.new(models: models) }
  let(:identities) { Rubotty::ControlPlane::IdentityDirectory.new(models: models) }
  let(:reporter) { author(native_id: "new-member", first_name: "Reporter", username: "new-member") }
  let(:alerts) { [] }
  let(:notifier) do
    double("notifier").tap do |value|
      allow(value).to receive(:notify_operators!) do |**event|
        alerts << event
        Rubotty::ControlPlane::AdminNotifier::Delivery.new(audience: 2, reached: 1, refused: 1, unreachable: 0)
      end
    end
  end
  let(:lane) do
    described_class.new(reports: reports, registry: registry, notifier: notifier,
      identities: identities, logger: Rubotty::Log.null)
  end
  let(:source) do
    registry.current.community_by_id(community.id).rooms.flat_map(&:endpoints)
            .find { |candidate| candidate.id == "tg-general" }
  end

  def link(native_id = "901")
    chat = source.settings.fetch(:chat_id).to_s.delete_prefix("-100")
    parts = [chat, source.settings[:thread_id], native_id].compact
    "https://t.me/c/#{parts.join('/')}"
  end

  def dm(text = "/report #{link}", subject: nil, who: reporter, service: lane)
    service.from_dm(adapter: :telegram, account: "telegram", author: who, text: text, subject: subject)
  end

  def forwarded(target: nil, body: "the reported words")
    described_class::Subject.new(author: author(native_id: "quoted-user", first_name: "Quoted"),
      target: target, body: body, adapter: :telegram, reporter_native_id: reporter.native_id)
  end

  def remember(member_of = community)
    now = Time.now
    models.observed_identity.create(community_id: member_of.id, adapter: "telegram",
      native_id: reporter.native_id, first_seen_at: now, last_seen_at: now)
  end

  def another_community
    now = Time.now
    models.community.create(slug: "private-other", name: "Private Other", status: "active",
      settings: "{}", created_at: now, updated_at: now).tap { registry.reload }
  end

  it "lets a member with no operator grant report an exact linked message" do
    reply = dm
    row = models.member_report.first

    expect(row).to have_attributes(community_id: community.id, endpoint_id: source.id, native_id: "901",
      route: "link", reporter_native_id: reporter.native_id, acknowledged: true)
    expect(reply).to include(row.code, "The operators have been told")
    expect(alerts.map { |event| event[:community_id] }).to eq([community.id])
    expect(models.operator.count).to eq(1)
  end

  it "keeps a forwarded origin and evidence in the matching community" do
    subject = forwarded(target: Rubotty::Core::Permalink.parse(link("902")))

    dm("/report", subject: subject)

    expect(models.member_report.first).to have_attributes(community_id: community.id, native_id: "902",
      endpoint_id: source.id, route: "forward", author_native_id: "quoted-user", body: "the reported words")
  end

  it "uses a pasted link before a conflicting forwarded origin" do
    dm("/report #{link('903')}", subject: forwarded(target: Rubotty::Core::Permalink.parse(link("904"))))

    expect(models.member_report.first).to have_attributes(native_id: "903", route: "link")
  end

  it "asks for evidence when neither a usable link nor a forward was supplied" do
    expect(dm("/report")).to eq(described_class::NOTHING_NAMED)
    expect(dm("/report https://unrelated.example/message")).to eq(described_class::NOTHING_NAMED)
    expect(models.member_report.count).to eq(0)
    expect(alerts).to be_empty
  end

  it "does not enumerate private communities for an unknown message link" do
    other = another_community
    reply = dm("/report https://t.me/c/123456789/999")

    expect(reply).not_to include(community.name, other.name, community.slug, other.slug)
    expect(models.member_report.count).to eq(0)
    expect(alerts).to be_empty
  end

  it "files originless evidence only for the reporter's sole known membership" do
    remember

    reply = dm("/report", subject: forwarded)

    expect(models.member_report.first).to have_attributes(community_id: community.id,
      endpoint_id: nil, native_id: nil, body: "the reported words")
    expect(reply).to include(models.member_report.first.code)
  end

  it "does not guess a community when the reporter is unknown" do
    expect(dm("/report", subject: forwarded)).to eq(described_class::NOWHERE_KNOWN)
    expect(models.member_report.count).to eq(0)
    expect(alerts).to be_empty
  end

  it "does not reveal a membership menu when more than one community matches" do
    other = another_community
    remember
    remember(other)

    reply = dm("/report", subject: forwarded)

    expect(reply).to eq(described_class::NOWHERE_KNOWN)
    expect(reply).not_to include(community.name, other.name, other.slug)
    expect(models.member_report.count).to eq(0)
  end

  it "grants no fallback when membership lookup fails" do
    allow(identities).to receive(:entry).and_raise(Sequel::DatabaseError, "synthetic outage")

    expect(dm("/report", subject: forwarded)).to eq(described_class::NOWHERE_KNOWN)
    expect(models.member_report.count).to eq(0)
  end

  it "deduplicates a second reporter without sending another operator alert" do
    dm
    second = dm(who: author(native_id: "another-member", first_name: "Another"))

    expect(models.member_report.count).to eq(1)
    expect(models.member_report.first.reports).to eq(2)
    expect(alerts.length).to eq(1)
    expect(second).to include("added to", models.member_report.first.code)
  end

  it "refuses a rate-limited report before storing or notifying it" do
    Rubotty::ControlPlane::MemberReports::RATE_LIMIT.times { |index| dm("/report #{link(index.to_s)}") }

    expect(dm("/report #{link('999999')}")).to eq(described_class::RATE_LIMITED)
    expect(models.member_report.count).to eq(Rubotty::ControlPlane::MemberReports::RATE_LIMIT)
    expect(alerts.length).to eq(Rubotty::ControlPlane::MemberReports::RATE_LIMIT)
  end

  it "keeps a report but does not claim notification when nobody was reached" do
    allow(notifier).to receive(:notify_operators!).and_return(Rubotty::ControlPlane::AdminNotifier::Delivery.none)

    reply = dm

    expect(reply).to include("saved as", "could not notify", models.member_report.first.code)
    expect(reply).not_to include("have been told")
    expect(models.member_report.first.acknowledged).to be(true)
  end

  it "keeps a report and gives a truthful acknowledgement when the notifier raises" do
    allow(notifier).to receive(:notify_operators!).and_raise(IOError, "synthetic outage")

    reply = dm

    expect(reply).to include("saved as", "could not notify")
    expect(models.member_report.count).to eq(1)
  end

  it "does not claim operators were contacted when no notifier is configured" do
    bare = described_class.new(reports: reports, registry: registry)

    expect(dm(service: bare)).to include("saved as", "could not notify")
  end

  it "bounds the alert quote while retaining evidence only in the scoped report" do
    remember
    body = ("x" * described_class::QUOTE_CHARS) + "unquoted-tail"

    dm("/report", subject: forwarded(body: body))

    expect(alerts.first[:text]).to include("x" * described_class::QUOTE_CHARS)
    expect(alerts.first[:text]).not_to include("unquoted-tail")
    expect(models.member_report.first.body).to eq(body)
  end
end
