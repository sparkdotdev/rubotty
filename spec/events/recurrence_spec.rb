# frozen_string_literal: true

require "spec_helper"

# Advances a Rubotty-native recurring event's occurrence once it is past due,
# writing through the same ControlPlane::EventScheduling#update path a manual
# edit takes, so Events::Lifecycle picks the change up and re-announces and
# reschedules reminders on its own next poll.
RSpec.describe Rubotty::Events::Recurrence, :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }
  let(:room) { models.room.where(community_id: community.id, room_key: "gaming").first }

  let(:base) { Time.utc(2026, 8, 1, 12, 0, 0) }
  let(:clock_time) { [base] }
  let(:clock) { -> { clock_time.first } }
  let(:now) { base }
  def advance(seconds) = clock_time[0] = clock_time.first + seconds

  let(:controls) { Rubotty::ControlPlane::FeatureControls.new(models: models) }
  let(:scheduling) { Rubotty::ControlPlane::EventScheduling.new(models: models, clock: clock) }

  subject(:recurrence) do
    described_class.new(models: models, event_scheduling: scheduling, logger: Rubotty::Log.null, clock: clock)
  end

  before { controls.enable(community: community, selector: room.room_key, feature: "events") }

  def create!(overrides = {})
    scheduling.create(
      **{
        community: community, room: room, as: :operator, title: "Weekly Raid",
        starts_at: now - 3600, kind: "gaming", recurrence_interval: 604_800
      }.merge(overrides)
    )
  end

  def reload(event) = scheduling.find(community: community, id: event.id)

  it "leaves a one-off event (no recurrence_interval) alone" do
    event = create!(recurrence_interval: nil, starts_at: now - 3600)
    expect(recurrence.check).to eq(0)
    expect(reload(event).starts_at).to eq(event.starts_at)
  end

  it "leaves a recurring event that has not started yet alone" do
    event = create!(starts_at: now + 3600)
    expect(recurrence.check).to eq(0)
    expect(reload(event).starts_at).to eq(event.starts_at)
  end

  it "advances a past-due event by exactly one interval" do
    event = create!(starts_at: now - 3600)
    expect(recurrence.check).to eq(1)
    expect(reload(event).starts_at).to eq(event.starts_at + 604_800)
  end

  it "preserves the event's duration when it has an announced end" do
    event = create!(starts_at: now - 3600, ends_at: now - 1800)
    advanced = reload(event)
    recurrence.check
    advanced = reload(event)
    expect(advanced.ends_at - advanced.starts_at).to eq(1800)
  end

  it "catches up through several missed occurrences after a long downtime" do
    event = create!(starts_at: now - (3 * 604_800) - 3600)
    recurrence.check
    expect(reload(event).starts_at).to be > now
    expect(reload(event).starts_at).to eq(event.starts_at + (4 * 604_800))
  end

  it "bumps updated_at, the signal Events::Lifecycle polls on" do
    event = create!(starts_at: now - 3600)
    before_stamp = event.row.updated_at
    advance(60)
    recurrence.check
    expect(reload(event).row.updated_at).to be > before_stamp
  end

  it "leaves a cancelled recurring event alone" do
    event = create!(starts_at: now - 3600)
    scheduling.cancel(event: event)
    expect(recurrence.check).to eq(0)
  end

  it "never touches another event's occurrence" do
    due = create!(starts_at: now - 3600, title: "Due")
    not_due = create!(starts_at: now + 3600, title: "Not due")
    recurrence.check
    expect(reload(due).starts_at).not_to eq(due.starts_at)
    expect(reload(not_due).starts_at).to eq(not_due.starts_at)
  end

  it "is a harmless no-op with nothing recurring at all" do
    create!(recurrence_interval: nil, starts_at: now + 3600)
    expect(recurrence.check).to eq(0)
  end
end
