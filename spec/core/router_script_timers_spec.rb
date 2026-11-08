# frozen_string_literal: true

require "spec_helper"

# Repeating timers and calling them off. schedule used to book exactly one
# wake with no handle, and every wake spent one of the five hops a chain
# gets, so a ten round game stopped after five rounds. A repeat now books
# all of its wakes as siblings one hop from the caller, not a chain.
RSpec.describe Rubotty::Core::Router, "repeating timers", :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:community) { models.community.first }
  let(:scripts) { Rubotty::ControlPlane::Scripts.new(models: models, logger: Rubotty::Log.null) }
  let(:booked) { [] }

  # Just enough of a scheduler to see what was asked of it. The real one is
  # covered by its own suite; what is under test here is the arithmetic that
  # decides how many bookings there are and what each one carries.
  let(:scheduler) do
    store = booked
    Class.new do
      define_method(:initialize) { @store = store }
      define_method(:schedule) do |kind:, run_at:, payload:, community: nil|
        @store << { kind: kind, run_at: run_at, payload: payload, community: community }
      end
      # kind is accepted and ignored: this store holds one kind, so what is
      # under test here is the predicate and the community together.
      define_method(:cancel) do |kind:, community: nil, &predicate|
        matched = ->(job) { job[:community] == community && predicate.call(job[:payload]) }
        dropped = @store.select(&matched)
        @store.reject!(&matched)
        dropped.length
      end
    end.new
  end

  before do
    scripts.save(community: community, name: "quiz", kind: "callback",
                 source: "return nil", trigger_type: "always")
  end

  def handler(generation: 0, script_name: "quiz", room_key: "general")
    described_class.allocate.send(:script_schedule_handler, community, scripts, scheduler,
                                  { generation: generation, script_name: script_name,
                                    room_key: room_key })
  end

  def canceller(script_name: "quiz", room_key: "general")
    described_class.allocate.send(:script_unschedule_handler, community, scheduler,
                                  { script_name: script_name, room_key: room_key })
  end

  def refusal(answer) = answer.is_a?(Rubotty::Scripting::Answer) ? answer.values.last : nil

  def epoch = Time.now.to_i

  describe "a single booking, which is what it always did" do
    it "books one wake and answers a tag to cancel it by" do
      tag = handler.call({ "after" => 60 })

      expect(tag).to be_a(String)
      expect(tag).not_to be_empty
      expect(booked.length).to eq(1)
    end

    it "takes a tag the script chose" do
      expect(handler.call({ "after" => 60, "tag" => "round-timer" })).to eq("round-timer")
    end

    it "refuses a tag that is not a name, the way a memo bucket is refused" do
      expect(refusal(handler.call({ "after" => 60, "tag" => "not: a name" })))
        .to include("not a tag name")
    end
  end

  describe "a repeat" do
    it "books every wake up front, evenly spaced" do
      handler.call({ "every" => 30, "until_at" => epoch + 300, "tag" => "rounds" })

      # Ten rather than eleven: with no `after`, the first wake lands at the
      # ten second floor a delay already has, so the run is 10s to 300s.
      expect(booked.length).to eq(10)
      expect((booked[1][:run_at] - booked[0][:run_at]).round).to eq(30)
    end

    # The whole point. Each wake is one hop from the caller, so a ten round game
    # finishes where a self-scheduling chain stopped at five.
    it "spends one hop however many wakes it books" do
      handler(generation: 2).call({ "every" => 30, "until_at" => epoch + 300 })

      expect(booked.map { |job| job[:payload]["generation"] }.uniq).to eq([3])
    end

    it "is still refused once the chain that booked it is out of hops" do
      answer = handler(generation: Rubotty::Core::Router::MAX_GENERATIONS)
               .call({ "every" => 30, "until_at" => epoch + 300 })

      expect(refusal(answer)).to include("stops after")
      expect(booked).to be_empty
    end

    it "refuses a repeat with no end, which is the bound it stands on" do
      expect(refusal(handler.call({ "every" => 30 }))).to include("needs until_at")
      expect(booked).to be_empty
    end

    it "refuses a repeat faster than the floor a single delay has" do
      expect(refusal(handler.call({ "every" => 1, "until_at" => epoch + 300 })))
        .to include("more often than every 10 seconds")
    end

    it "refuses a repeat that would book more than the ceiling, saying what to change" do
      answer = handler.call({ "every" => 10, "until_at" => epoch + 100_000 })

      expect(refusal(answer)).to include("Raise every")
      expect(booked).to be_empty
    end

    it "refuses an until_at that has already gone by" do
      expect(refusal(handler.call({ "every" => 30, "until_at" => epoch - 500 })))
        .to include("finished before it started")
    end
  end

  describe "calling a booking off" do
    before { handler.call({ "every" => 30, "until_at" => epoch + 300, "tag" => "rounds" }) }

    it "drops every booking under the tag and says how many went" do
      expect(canceller.call("rounds")).to eq(10)
      expect(booked).to be_empty
    end

    it "answers zero for a tag nothing was booked under" do
      expect(canceller.call("nothing")).to eq(0)
      expect(booked.length).to eq(10)
    end

    # A tag is the booking script's, in its room. Two rules that both call their
    # timer "rounds" must not be able to cancel each other.
    it "never reaches a booking another script made under the same tag" do
      expect(canceller(script_name: "other").call("rounds")).to eq(0)
      expect(canceller(room_key: "elsewhere").call("rounds")).to eq(0)
      expect(booked.length).to eq(10)
    end
  end
end
