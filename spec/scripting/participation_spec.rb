# frozen_string_literal: true

require "spec_helper"
require "rubotty"

# The storage behind a scripted round: a session, and the rounds inside it. Rubotty holds
# a bounded interval with a deadline, a continuation and a payload, and nothing about what
# the round is for; the scoring a game does with it is exercised separately, in
# spec/scripting/examples_spec.rb.
RSpec.describe Rubotty::ControlPlane::Participation, :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:community) { models.community.first }
  let(:now) { Time.now }

  subject(:runs) { described_class.new(models: models, logger: Rubotty::Log.null, clock: -> { now }) }

  def start(kind: "trivia", room_key: "general")
    runs.open_session(community: community, room_key: room_key, kind: kind, label: "Friday quiz")
  end

  def ask(room_key: "general", close_after: nil, on_close: nil, data: nil)
    runs.open_round(community: community, room_key: room_key, close_after: close_after,
                    on_close: on_close, data: data)
  end

  describe "a session" do
    it "is nil until something is started" do
      expect(runs.session(community: community, room_key: "general")).to be_nil
    end

    it "reads back what it was opened with" do
      start

      expect(runs.session(community: community, room_key: "general"))
        .to include("kind" => "trivia", "label" => "Friday quiz", "state" => "open", "rounds" => 0)
    end

    # Two games in one room make an answer ambiguous, and guessing which one
    # somebody meant is worse than saying so.
    it "refuses a second one in the same room, with a reason" do
      start

      expect(start).to eq([false, "something is already running in this room"])
    end

    it "leaves the next room alone" do
      start

      expect(start(room_key: "kitchen")).to be(true)
    end

    it "refuses a kind that is not a name" do
      expect(runs.open_session(community: community, kind: "trivia; drop table")).to eq(
        [false, "that is not a session kind"]
      )
    end

    it "can be started again once the first is closed" do
      start
      runs.close_session(community: community, room_key: "general")

      expect(start).to be(true)
    end

    it "says so when there is nothing to close" do
      expect(runs.close_session(community: community, room_key: "general"))
        .to eq([false, "nothing is running in this room"])
    end
  end

  describe "a round" do
    before { start }

    it "is nil until one is opened" do
      expect(runs.round(community: community, room_key: "general")).to be_nil
    end

    it "carries its position, its payload, and no deadline when none was booked" do
      ask(data: { "prompt" => "Capital of Portugal?" })

      round = runs.round(community: community, room_key: "general")
      expect(round).to include("position" => 1, "data" => { "prompt" => "Capital of Portugal?" })
      expect(round).not_to have_key("closes_at")
    end

    it "carries a deadline when close_after booked one" do
      ask(close_after: 60, on_close: "round_close")

      expect(runs.round(community: community, room_key: "general")["closes_at"]).to eq((now + 60).to_i)
    end

    it "answers the new round's id, which the caller needs to book its own close" do
      id = ask
      expect(id).to be_a(Integer)
      expect(runs.round(community: community, room_key: "general")["id"]).to eq(id)
    end

    it "closes the one before it when the next is opened" do
      ask(data: { "n" => 1 })
      ask(data: { "n" => 2 })

      expect(runs.round(community: community, room_key: "general")).to include("position" => 2,
                                                                                "data" => { "n" => 2 })
    end

    it "needs a session to belong to" do
      expect(ask(room_key: "kitchen")).to eq([false, "nothing is running in this room"])
    end

    it "needs an on_close script whenever close_after is given" do
      expect(ask(close_after: 60)).to eq([false, "close_after needs an on_close script to wake"])
    end

    it "refuses a close_after under the floor" do
      expect(ask(close_after: 1, on_close: "round_close"))
        .to eq([false, "close_after has to be at least 10 seconds"])
    end

    it "refuses a close_after over the ceiling" do
      expect(ask(close_after: described_class::MAX_CLOSE_AFTER + 1, on_close: "round_close"))
        .to eq([false, "close_after has to be under #{described_class::MAX_CLOSE_AFTER} seconds"])
    end

    it "refuses a payload too large to keep" do
      expect(ask(data: { "text" => "x" * described_class::MAX_DATA_BYTES }))
        .to eq([false, "data is too large to keep against a round"])
    end

    it "takes at most the round ceiling" do
      stub_const("#{described_class}::MAX_ROUNDS", 1)
      ask

      expect(ask).to eq([false, "this session already has 1 rounds, which is the limit"])
    end
  end

  describe "closing a round" do
    before do
      start
      ask(data: { "prompt" => "Capital of Portugal?" })
    end

    it "shuts the round" do
      expect(runs.close_round(community: community, room_key: "general")).to be(true)
      expect(runs.round(community: community, room_key: "general")).to be_nil
    end

    it "replaces the round's payload with whatever data it is given before it closes" do
      row_id = runs.round(community: community, room_key: "general")["id"]
      runs.close_round(community: community, room_key: "general", data: { "winner" => "ada" })

      expect(models.script_round[row_id].data).to include("winner")
    end

    it "leaves the payload alone when no data is given" do
      row_id = runs.round(community: community, room_key: "general")["id"]
      runs.close_round(community: community, room_key: "general")

      expect(models.script_round[row_id].data).to include("prompt")
    end

    it "says so when no round is open" do
      runs.close_round(community: community, room_key: "general")

      expect(runs.close_round(community: community, room_key: "general"))
        .to eq([false, "no round is open in this room"])
    end
  end

  # The rows hold a script's own free text payload, so the whole session ages
  # out rather than sitting there once the game is over.
  describe "the retention" do
    it "drops a session past it, and its rounds with it" do
      start
      ask

      expect(runs.prune(now: now + described_class::RETENTION + 1)).to eq(1)
      expect(models.script_round.count).to eq(0)
    end

    it "leaves a session still inside it alone" do
      start

      expect(runs.prune(now: now + described_class::RETENTION - 1)).to eq(0)
      expect(runs.session(community: community, room_key: "general")).not_to be_nil
    end
  end
end
