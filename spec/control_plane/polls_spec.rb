# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::ControlPlane::Polls, :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }
  let(:room) { models.room.where(community_id: community.id, room_key: "gaming").first }
  let(:other_room) { models.room.where(community_id: community.id, room_key: "general").first }
  let(:now) { Time.utc(2026, 8, 12, 18, 0, 0) }

  subject(:polls) { described_class.new(models: models, logger: Rubotty::Log.null, clock: -> { now }) }

  def open_poll(**overrides)
    polls.open(
      **{
        community: community, room: room, kind: Rubotty::Polls::Poll::KIND_POLL,
        question: "Which map?", options: [{ label: "Dust II" }, { label: "Inferno" }]
      }.merge(overrides)
    )
  end

  describe "#open" do
    it "writes the poll and its options in the order they were given" do
      poll = open_poll(options: [{ label: "One" }, { label: "Two" }, { label: "Three" }])

      expect(poll.question).to eq("Which map?")
      expect(poll).to be_open
      expect(polls.options(poll).map(&:label)).to eq(%w[One Two Three])
      expect(polls.options(poll).map(&:position)).to eq([1, 2, 3])
    end

    it "counts the deadline from the moment it was opened" do
      expect(open_poll(duration_hours: 4).closes_at).to eq(now + (4 * 3600))
    end

    it "defaults to the twenty-four hour deadline" do
      expect(open_poll.closes_at).to eq(now + (24 * 3600))
    end

    it "refuses a duration outside the ladder" do
      expect { open_poll(duration_hours: 3) }
        .to raise_error(described_class::Invalid, /duration must be one of 1h, 2h/)
    end

    it "refuses fewer than two options, and more than nine" do
      expect { open_poll(options: [{ label: "Only" }]) }
        .to raise_error(described_class::Invalid, /at least two options/)
      expect { open_poll(options: (1..10).map { |i| { label: "Option #{i}" } }) }
        .to raise_error(described_class::Invalid, /at most 9 options/)
    end

    it "refuses a blank question and an unknown kind" do
      expect { open_poll(question: "  ") }.to raise_error(described_class::Invalid, /needs a question/)
      expect { open_poll(kind: "vote") }.to raise_error(described_class::Invalid, /kind must be/)
    end

    it "refuses a room in another community" do
      other = models.community.create(slug: "elsewhere", name: "Elsewhere", created_at: now, updated_at: now)

      expect do
        polls.open(community: other, room: room, kind: "poll", question: "Q",
                   options: [{ label: "a" }, { label: "b" }])
      end.to raise_error(described_class::Invalid, /does not belong/)
    end

    it "carries the multi-select and reply flags onto the row" do
      poll = open_poll(multi_select: true, reply_votes: false, reply_options: true)

      reloaded = polls.by_id(poll.id)
      expect(reloaded).to be_multi_select
      expect(reloaded).not_to be_reply_votes
      expect(reloaded).to be_reply_options
    end
  end

  describe "#add_option" do
    it "appends at the next position" do
      poll = open_poll
      option = polls.add_option(poll: poll, label: "Nuke", suggested_by: "discord:ada")

      expect(option.position).to eq(3)
      expect(option.suggested_by).to eq("discord:ada")
      expect(polls.options(poll).map(&:label)).to eq(["Dust II", "Inferno", "Nuke"])
    end

    it "refuses one the poll already carries, however it was capitalised" do
      poll = open_poll

      expect { polls.add_option(poll: poll, label: "  inferno ") }
        .to raise_error(described_class::Invalid, /already on the list/)
    end

    it "matches a scheduling slot on the instant it names rather than its wording" do
      slot = Time.utc(2026, 8, 18, 19, 0, 0)
      poll = polls.open(
        community: community, room: room, kind: Rubotty::Polls::Poll::KIND_SCHEDULE,
        question: "Raid night",
        options: [{ label: "Tue 7pm", starts_at: slot }, { label: "Wed 7pm", starts_at: slot + 86_400 }]
      )

      expect { polls.add_option(poll: poll, label: "next tuesday 7pm", starts_at: slot) }
        .to raise_error(described_class::Invalid, /already on the list/)
    end

    it "refuses a tenth option and a closed poll" do
      poll = open_poll
      (3..9).each { |i| polls.add_option(poll: poll, label: "Option #{i}") }

      expect { polls.add_option(poll: poll, label: "Option 10") }
        .to raise_error(described_class::Invalid, /all 9 options/)

      polls.close(poll: poll)
      expect { polls.add_option(poll: polls.by_id(poll.id), label: "Late") }
        .to raise_error(described_class::Invalid, /already closed/)
    end
  end

  describe "#close" do
    it "allows only one independently fetched open object to win closure" do
      poll = open_poll
      first = polls.by_id(poll.id)
      second = polls.by_id(poll.id)
      expect(polls.close(poll: first)).to be(true)
      expect(first).to be_closed
      expect(polls.close(poll: second)).to be(false)
    end

    it "closes once and reports it, and is a silent no-op after that" do
      poll = open_poll

      expect(polls.close(poll: poll)).to be(true)
      expect(polls.by_id(poll.id)).to be_closed
      expect(polls.close(poll: polls.by_id(poll.id))).to be(false)
    end
  end

  describe "#due and #open_polls" do
    it "answers only the open polls whose deadline has arrived" do
      soon = open_poll(duration_hours: 1)
      later = open_poll(duration_hours: 24)

      expect(polls.open_polls.map(&:id)).to contain_exactly(soon.id, later.id)
      expect(polls.due(now: now + 3601).map(&:id)).to eq([soon.id])
      expect(polls.due(now: now).map(&:id)).to be_empty
    end

    it "scopes to one community when given one, leaving the no-arg call unscoped" do
      ours = open_poll
      other = models.community.create(slug: "elsewhere", name: "Elsewhere", created_at: now, updated_at: now)
      other_room = models.room.create(
        community_id: other.id, room_key: "gaming", label: "Gaming", created_at: now, updated_at: now
      )
      elsewhere = polls.open(
        community: other, room: other_room, kind: Rubotty::Polls::Poll::KIND_POLL,
        question: "Elsewhere's poll", options: [{ label: "a" }, { label: "b" }]
      )

      expect(polls.open_polls(community: community).map(&:id)).to contain_exactly(ours.id)
      expect(polls.open_polls.map(&:id)).to contain_exactly(ours.id, elsewhere.id)
    end
  end

  describe "#find and #room_for_endpoint_key" do
    it "scopes a lookup by id to one community" do
      poll = open_poll
      other = models.community.create(slug: "elsewhere", name: "Elsewhere", created_at: now, updated_at: now)

      expect(polls.find(community: community, id: poll.id).id).to eq(poll.id)
      expect(polls.find(community: other, id: poll.id)).to be_nil
    end

    it "resolves a channel's endpoint key back to the room it is bridged into" do
      channel = models.channel.where(community_id: community.id).first
      resolved = polls.room_for_endpoint_key(community: community, endpoint_key: channel.endpoint_key)

      expect(resolved).not_to be_nil
      expect(polls.room_for_endpoint_key(community: community, endpoint_key: "nowhere")).to be_nil
    end
  end

  describe "#mark_posted" do
    it "records when the card was last put in front of the room" do
      poll = open_poll
      polls.mark_posted(poll: poll, at: now + 60)

      expect(polls.by_id(poll.id).last_posted_at).to eq(now + 60)
    end
  end
end
