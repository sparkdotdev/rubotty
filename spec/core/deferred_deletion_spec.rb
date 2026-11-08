# frozen_string_literal: true

require "spec_helper"

# The other end of a `/delete <time>`: the job comes due, possibly in a
# different process from the one that booked it, and the removal runs.
RSpec.describe Rubotty::Core::DeferredDeletion do
  let(:tg) { endpoint("tg") }
  let(:rooms) { topology(room("r", tg)) }

  # Stands in for Watchdog::Removal, keeping what it was asked to remove.
  class RecordingRemoval
    attr_reader :removed

    def initialize(fail_with: nil)
      @removed = []
      @fail_with = fail_with
    end

    def remove_everywhere(message)
      raise @fail_with if @fail_with

      @removed << [message.origin.id, message.ref.native_id]
      @removed.last
    end
  end

  class RecordingAudit
    attr_reader :events

    def initialize = @events = []

    def record(**event) = @events << event
  end

  let(:removal) { RecordingRemoval.new }
  let(:audit) { RecordingAudit.new }

  def service(remover: removal)
    described_class.new(topology: rooms, removal: remover, audit: audit, logger: Rubotty::Log.null)
  end

  def job(payload, community: "sample")
    Struct.new(:payload, :community).new(payload, community)
  end

  def payload(endpoint_id: "tg", native_id: "900", issued_by: "Op")
    {
      described_class::ENDPOINT_KEY => endpoint_id,
      described_class::NATIVE_KEY => native_id,
      described_class::ISSUER_KEY => issued_by
    }
  end

  describe "#run" do
    it "removes the message the job names" do
      service.run(job(payload))

      expect(removal.removed).to eq([%w[tg 900]])
    end

    it "writes the removal down against the operator who asked for it" do
      service.run(job(payload(issued_by: "Quillsharp")))

      expect(audit.events.first).to include(community: "sample", action: "delete", actor: "Quillsharp")
      expect(audit.events.first[:target_ref]).to eq("tg:900")
    end

    # A room unmapped since the booking is not an error worth retrying: the
    # job has done all it can.
    it "does nothing for an endpoint that no longer resolves" do
      service.run(job(payload(endpoint_id: "gone")))

      expect(removal.removed).to be_empty
      expect(audit.events).to be_empty
    end

    it "does nothing for a job naming no message" do
      service.run(job(payload(native_id: "")))

      expect(removal.removed).to be_empty
    end

    # The scheduler retries a raising handler, and a message already gone would
    # raise on every attempt until the job gave up.
    it "swallows a removal that fails rather than raising at the scheduler" do
      expect { service(remover: RecordingRemoval.new(fail_with: RuntimeError.new("gone"))).run(job(payload)) }
        .not_to raise_error
    end

    it "survives a payload that lost its keys entirely" do
      expect { service.run(job({})) }.not_to raise_error
      expect(removal.removed).to be_empty
    end
  end

  describe ".book" do
    # Stands in for the durable scheduler.
    class BookingScheduler
      attr_reader :booked

      def initialize = @booked = []

      def schedule(**args)
        @booked << args
        :booked
      end
    end

    let(:scheduler) { BookingScheduler.new }
    let(:at) { Time.now + 3600 }

    it "books a durable job naming the message and the time" do
      described_class.book(scheduler: scheduler, community: "sample", origin: tg,
                           ref: ref("tg", "900"), at: at, issuer: "Op")

      booked = scheduler.booked.first
      expect(booked[:kind]).to eq(described_class::KIND)
      expect(booked[:run_at]).to eq(at)
      expect(booked[:community]).to eq("sample")
      expect(booked[:payload][described_class::NATIVE_KEY]).to eq("900")
    end

    # The payload names a message, never its text, so nothing about what was
    # said waits in the job store for the delete to come due.
    it "discards the payload once the job is done, and never carries the text" do
      described_class.book(scheduler: scheduler, community: "sample", origin: tg,
                           ref: ref("tg", "900"), at: at, issuer: "Op")

      booked = scheduler.booked.first
      expect(booked[:discard_payload]).to be(true)
      expect(booked[:payload].keys).to contain_exactly(
        described_class::ENDPOINT_KEY, described_class::NATIVE_KEY, described_class::ISSUER_KEY
      )
    end

    it "books nothing without a scheduler, a message or an endpoint" do
      expect(described_class.book(scheduler: nil, community: "c", origin: tg, ref: ref("tg", "900"), at: at))
        .to be_nil
      expect(described_class.book(scheduler: scheduler, community: "c", origin: nil,
                                  ref: ref("tg", "900"), at: at)).to be_nil
      expect(described_class.book(scheduler: scheduler, community: "c", origin: tg,
                                  ref: ref("tg", ""), at: at)).to be_nil
      expect(scheduler.booked).to be_empty
    end
  end
end
