# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Polls::Ballot, :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }
  let(:room) { models.room.where(community_id: community.id, room_key: "gaming").first }
  let(:now) { Time.utc(2026, 8, 12, 18, 0, 0) }
  let(:writer) { Rubotty::ControlPlane::Polls.new(models: models, logger: Rubotty::Log.null, clock: -> { now }) }

  subject(:ballot) { described_class.new(models: models, logger: Rubotty::Log.null, clock: -> { now }) }

  def poll_with(multi_select:)
    writer.open(
      community: community, room: room, kind: Rubotty::Polls::Poll::KIND_POLL,
      question: "Which map?", options: [{ label: "Dust II" }, { label: "Inferno" }, { label: "Nuke" }],
      multi_select: multi_select
    )
  end

  def vote(poll, position, identity, handle: identity, platform: "discord")
    ballot.record(poll: poll, option: writer.option_at(poll, position), identity: identity,
                  platform: platform, handle: handle)
  end

  # What the passive directory holds after somebody has been seen in the room.
  def observed(native_id:, username: nil, display_name: nil, adapter: "telegram")
    models.observed_identity.create(
      community_id: community.id, adapter: adapter, native_id: native_id,
      username: username, display_name: display_name, first_seen_at: now, last_seen_at: now
    )
  end

  describe "#record on a single-select poll" do
    it "refuses a stale open reaction after closure without changing the final votes" do
      poll = poll_with(multi_select: false)
      vote(poll, 1, "ada")
      stale = writer.by_id(poll.id)
      expect(writer.close(poll: poll)).to be(true)
      final_votes = models.poll_vote.where(poll_id: poll.id).order(:id).all.map(&:values)

      expect(stale).to be_open
      expect(vote(stale, 2, "bruno")).to be(false)
      expect(models.poll_vote.where(poll_id: poll.id).order(:id).all.map(&:values)).to eq(final_votes)
    end

    it "uses the locked poll's current selection policy rather than a stale flag" do
      poll = poll_with(multi_select: true)
      vote(poll, 1, "ada")
      models.poll.where(id: poll.id).update(multi_select: false)

      expect(poll).to be_multi_select
      expect(vote(poll, 2, "ada")).to be(true)
      expect(models.poll_vote.where(poll_id: poll.id, identity: "ada").select_map(:option_id))
        .to eq([writer.option_at(poll, 2).id])
    end

    it "serializes interleaved vote changes before withdrawing and inserting" do
      poll = poll_with(multi_select: false)
      first_ballot = described_class.new(models: models)
      second_ballot = described_class.new(models: models)
      entered, resume, started = Queue.new, Queue.new, Queue.new
      allow(first_ballot).to receive(:withdraw_others).and_wrap_original do |original, *args|
        original.call(*args)
        entered << :first
        resume.pop
      end
      allow(second_ballot).to receive(:withdraw_others).and_wrap_original do |original, *args|
        entered << :second
        original.call(*args)
      end
      first_option, second_option = writer.option_at(poll, 1), writer.option_at(poll, 2)
      first = Thread.new do
        first_ballot.record(poll: poll, option: first_option, identity: "ada", platform: "discord")
      end
      expect(entered.pop(timeout: 5)).to eq(:first)
      second = Thread.new do
        started << true
        second_ballot.record(poll: poll, option: second_option, identity: "ada", platform: "discord")
      end
      started.pop(timeout: 5)
      expect(entered.pop(timeout: 0.1)).to be_nil
      resume << true
      [first, second].each(&:value)
      expect(models.poll_vote.where(poll_id: poll.id, identity: "ada").select_map(:option_id))
        .to eq([second_option.id])
    ensure
      resume << true if resume
      [first, second].compact.each { |thread| thread.join(1); thread.kill if thread.alive? }
    end

    it "records a vote and reports the change" do
      poll = poll_with(multi_select: false)

      expect(vote(poll, 1, "ada")).to be(true)
      expect(ballot.by_option(poll)[writer.option_at(poll, 1).id].map(&:handle)).to eq(["ada"])
    end

    it "moves a voter rather than letting them back two options" do
      poll = poll_with(multi_select: false)
      vote(poll, 1, "ada")
      vote(poll, 2, "ada")

      by_option = ballot.by_option(poll)
      expect(by_option[writer.option_at(poll, 1).id]).to be_empty
      expect(by_option[writer.option_at(poll, 2).id].map(&:handle)).to eq(["ada"])
    end

    it "reports no change when the same person taps the same option twice" do
      poll = poll_with(multi_select: false)
      vote(poll, 1, "ada")

      expect(vote(poll, 1, "ada")).to be(false)
    end

    it "ignores a vote with no identity behind it" do
      poll = poll_with(multi_select: false)

      expect(vote(poll, 1, "")).to be(false)
      expect(ballot.by_option(poll)).to be_empty
    end
  end

  describe "#record on a multi-select poll" do
    it "honours multi-select enabled after the caller fetched its poll" do
      poll = poll_with(multi_select: false)
      vote(poll, 1, "ada")
      models.poll.where(id: poll.id).update(multi_select: true)

      expect(vote(poll, 2, "ada")).to be(true)
      expect(models.poll_vote.where(poll_id: poll.id, identity: "ada").select_map(:option_id))
        .to contain_exactly(writer.option_at(poll, 1).id, writer.option_at(poll, 2).id)
    end

    # The one behavioural difference between /poll and /schedule.
    it "lets one person back every option that works for them" do
      poll = poll_with(multi_select: true)
      vote(poll, 1, "ada")
      vote(poll, 3, "ada")

      by_option = ballot.by_option(poll)
      expect(by_option[writer.option_at(poll, 1).id].map(&:handle)).to eq(["ada"])
      expect(by_option[writer.option_at(poll, 3).id].map(&:handle)).to eq(["ada"])
    end
  end

  describe "#clear" do
    it "preserves final votes when a stale reaction withdrawal arrives after closure" do
      poll = poll_with(multi_select: true)
      vote(poll, 1, "ada")
      stale = writer.by_id(poll.id)
      option = writer.option_at(poll, 1)
      expect(writer.close(poll: poll)).to be(true)
      final_votes = models.poll_vote.where(poll_id: poll.id).order(:id).all.map(&:values)

      expect(stale).to be_open
      expect(ballot.clear(poll: stale, option: option, identity: "ada")).to be(false)
      expect(models.poll_vote.where(poll_id: poll.id).order(:id).all.map(&:values)).to eq(final_votes)
    end

    it "withdraws one vote and reports it, and says so when there was none" do
      poll = poll_with(multi_select: true)
      vote(poll, 1, "ada")
      option = writer.option_at(poll, 1)

      expect(ballot.clear(poll: poll, option: option, identity: "ada")).to be(true)
      expect(ballot.clear(poll: poll, option: option, identity: "ada")).to be(false)
      expect(ballot.by_option(poll)[option.id]).to be_empty
    end
  end

  # One inline keyboard serves everybody who can see the card, so a press says
  # only which option it was; this is what tells an addition from a withdrawal.
  describe "#holds?" do
    it "answers for the one voter asked about and nobody else" do
      poll = poll_with(multi_select: true)
      vote(poll, 1, "ada")
      option = writer.option_at(poll, 1)

      expect(ballot.holds?(poll: poll, option: option, identity: "ada")).to be(true)
      expect(ballot.holds?(poll: poll, option: option, identity: "bruno")).to be(false)
      expect(ballot.holds?(poll: poll, option: writer.option_at(poll, 2), identity: "ada")).to be(false)
    end

    it "answers no for a voter with no identity to go on" do
      poll = poll_with(multi_select: true)

      expect(ballot.holds?(poll: poll, option: writer.option_at(poll, 1), identity: "")).to be(false)
    end
  end

  describe "#by_option" do
    it "keeps each option's voters oldest first, so the names a card shows are the first to answer" do
      poll = poll_with(multi_select: true)
      %w[ada bruno cleo].each_with_index do |handle, index|
        described_class.new(models: models, clock: -> { now + index }).record(
          poll: poll, option: writer.option_at(poll, 1), identity: handle, platform: "discord", handle: handle
        )
      end

      expect(ballot.by_option(poll)[writer.option_at(poll, 1).id].map(&:handle)).to eq(%w[ada bruno cleo])
    end

    it "carries the platform each vote came from" do
      poll = poll_with(multi_select: true)
      vote(poll, 1, "44120", handle: "bruno", platform: "telegram")

      voter = ballot.by_option(poll)[writer.option_at(poll, 1).id].first
      expect(voter.platform).to eq("telegram")
      expect(voter.identity).to eq("44120")
      expect(voter.handle).to eq("bruno")
    end

    it "takes the directory's name for a vote whose platform gave no handle" do
      poll = poll_with(multi_select: true)
      vote(poll, 1, "5502187744", handle: nil, platform: "telegram")
      observed(native_id: "5502187744", display_name: "Pinniped Pete")

      voter = ballot.by_option(poll)[writer.option_at(poll, 1).id].first
      expect(voter.handle).to be_nil
      expect(voter.name).to eq("Pinniped Pete")
      expect(Rubotty::Core::VoteRoster.inline([voter], on_platform: "telegram")).to eq("Pinniped Pete")
    end

    it "leaves the name empty for a voter the directory has never seen" do
      poll = poll_with(multi_select: true)
      vote(poll, 1, "5502187744", handle: nil, platform: "telegram")

      voter = ballot.by_option(poll)[writer.option_at(poll, 1).id].first
      expect(voter.name).to be_nil
      expect(Rubotty::Core::VoteRoster.inline([voter], on_platform: "telegram")).to eq("someone")
    end

    it "does not go to the directory at all for a vote that already carries a handle" do
      poll = poll_with(multi_select: true)
      vote(poll, 1, "5502187744", handle: "pete", platform: "telegram")
      observed(native_id: "5502187744", username: "pete", display_name: "Pinniped Pete")

      voter = ballot.by_option(poll)[writer.option_at(poll, 1).id].first
      expect(voter.name).to be_nil
      expect(Rubotty::Core::VoteRoster.inline([voter], on_platform: "telegram")).to eq("@pete")
    end
  end
end
