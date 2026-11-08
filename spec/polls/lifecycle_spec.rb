# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Polls::Lifecycle, :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }
  let(:room) { models.room.where(community_id: community.id, room_key: "gaming").first }
  let(:now) { Time.utc(2026, 8, 12, 18, 0, 0) }

  let(:writer) { Rubotty::ControlPlane::Polls.new(models: models, logger: Rubotty::Log.null, clock: -> { now }) }

  let(:board) do
    Class.new do
      attr_reader :opened, :results, :reposted

      def initialize = (@opened = []; @results = []; @reposted = [])

      def announce_opened(poll) = @opened << poll.id

      def announce_results(poll) = @results << poll.id

      def repost_if_buried(poll)
        @reposted << poll.id
        1
      end
    end.new
  end

  let(:timekeeper) do
    Class.new do
      attr_reader :armed, :cancelled

      def initialize = (@armed = []; @cancelled = [])

      def arm(poll) = @armed << poll.id

      def cancel_for(poll)
        @cancelled << poll.id
        2
      end
    end.new
  end

  subject(:lifecycle) do
    described_class.new(
      polls: writer, board: board, timekeeper: timekeeper, logger: Rubotty::Log.null, clock: -> { now }
    )
  end

  def a_poll(**overrides)
    writer.open(
      **{
        community: community, room: room, kind: Rubotty::Polls::Poll::KIND_POLL,
        question: "Which map?", options: [{ label: "Dust II" }, { label: "Inferno" }]
      }.merge(overrides)
    )
  end

  describe "#announce" do
    it "shows the card and starts both clocks" do
      poll = lifecycle.announce(a_poll)

      expect(board.opened).to eq([poll.id])
      expect(timekeeper.armed).to eq([poll.id])
    end
  end

  describe "#close" do
    it "closes the poll, withdraws its clocks and leaves the results behind" do
      poll = a_poll

      expect(lifecycle.close(poll.id)).to be(true)
      expect(writer.by_id(poll.id)).to be_closed
      expect(timekeeper.cancelled).to eq([poll.id])
      expect(board.results).to eq([poll.id])
    end

    # Closing is the gate, so two workers racing the same due job leave one
    # results message rather than two.
    it "posts the results exactly once however many times it is called" do
      poll = a_poll
      lifecycle.close(poll.id)

      expect(lifecycle.close(poll.id)).to be(false)
      expect(board.results).to eq([poll.id])
    end

    it "says nothing about a poll that is no longer there" do
      expect(lifecycle.close(9999)).to be(false)
      expect(board.results).to be_empty
    end
  end

  describe "#repost" do
    it "hands an open poll to the board" do
      poll = a_poll

      expect(lifecycle.repost(poll.id)).to eq(1)
      expect(board.reposted).to eq([poll.id])
    end

    it "withdraws the nudge for a poll that closed since it was armed" do
      poll = a_poll
      writer.close(poll: poll)

      expect(lifecycle.repost(poll.id)).to eq(0)
      expect(board.reposted).to be_empty
      expect(timekeeper.cancelled).to eq([poll.id])
    end
  end

  describe "#sweep" do
    it "closes every poll whose deadline has passed and leaves the rest alone" do
      overdue = a_poll(duration_hours: 1)
      later = a_poll(duration_hours: 24)

      lifecycle_at(now + 3601).tap { |sweeper| expect(sweeper.sweep).to eq(1) }

      expect(writer.by_id(overdue.id)).to be_closed
      expect(writer.by_id(later.id)).to be_open
    end

    it "is what the control-plane watcher ticks" do
      a_poll(duration_hours: 1)

      expect(lifecycle_at(now + 3601).check).to eq(1)
    end
  end

  def lifecycle_at(moment)
    described_class.new(
      polls: writer, board: board, timekeeper: timekeeper, logger: Rubotty::Log.null, clock: -> { moment }
    )
  end
end
