# frozen_string_literal: true

require "spec_helper"

# One row per reported MESSAGE, not per reporter: a report is a way for any
# member to make the bot alert every operator, which is an amplification vector
# before it is a feature.
RSpec.describe Rubotty::ControlPlane::MemberReports, :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:community) { models.community.first }
  let(:now) { [Time.now] }
  subject(:reports) { described_class.new(models: models, logger: Rubotty::Log.null, clock: -> { now[0] }) }

  def reporter(native_id: "u1", display: "Ada") = { adapter: :telegram, native_id: native_id, display: display }

  def file(native_id: "900", who: reporter)
    reports.file(community_id: community.id, reporter: who, route: "reply",
                 endpoint_id: "tg-general", native_id: native_id,
                 author: { native_id: "777", display: "Bo" }, body: "the words")
  end

  it "files a report with a code an operator can answer by" do
    filed = file

    expect(filed).to be_first
    expect(filed.row.code).to match(/\A[23456789bcdfghjkmnpqrstvwxyz]{4}\z/)
    expect(filed.row.body).to eq("the words")
    expect(filed.row.author_display).to eq("Bo")
  end

  it "reads a report back by its code, inside its own community" do
    code = file.row.code

    expect(reports.by_code(community_id: community.id, code: code)).not_to be_nil
    expect(reports.by_code(community_id: community.id, code: code.upcase)).not_to be_nil
  end

  # Twenty people reporting one thing is one thread with a count, not twenty
  # alerts each.
  it "counts a second report of the same message onto the first" do
    first = file
    second = file(who: reporter(native_id: "u2", display: "Cy"))

    expect(second).not_to be_first
    expect(second.row.id).to eq(first.row.id)
    expect(second.row.reports).to eq(2)
    expect(models.member_report.count).to eq(1)
  end

  it "opens a new thread for a different message" do
    file
    file(native_id: "901")

    expect(models.member_report.count).to eq(2)
  end

  # Reporting a message again after an operator dismissed it is a new thread,
  # not a louder version of the old one.
  it "opens a new thread once the first was settled" do
    reports.settle(file.row, "dismissed")
    again = file

    expect(again).to be_first
    expect(models.member_report.count).to eq(2)
  end

  it "stops one reporter past the rate limit" do
    described_class::RATE_LIMIT.times { |i| file(native_id: "90#{i}") }

    expect(file(native_id: "999")).to be_rate_limited
    expect(models.member_report.count).to eq(described_class::RATE_LIMIT)
  end

  it "lets a different reporter through the same window" do
    described_class::RATE_LIMIT.times { |i| file(native_id: "90#{i}") }

    expect(file(native_id: "999", who: reporter(native_id: "u2"))).not_to be_rate_limited
  end

  it "forgets the limit once the window has passed" do
    described_class::RATE_LIMIT.times { |i| file(native_id: "90#{i}") }
    now[0] += described_class::RATE_WINDOW + 1

    expect(file(native_id: "999")).not_to be_rate_limited
  end

  # A rising count of reports nobody could acknowledge means members are
  # reporting and believe nothing happened.
  it "counts the reports whose reporter could not be told" do
    filed = file
    file(native_id: "901")
    reports.acknowledged!(filed.row)

    expect(reports.unacknowledged(community_id: community.id)).to eq(1)
  end

  it "prunes what has aged out and keeps what has not" do
    file
    now[0] += (described_class::RETENTION_DAYS * 86_400) + 1
    file(native_id: "901")

    expect(reports.prune(now: now[0])).to eq(1)
    expect(models.member_report.count).to eq(1)
  end
end
