# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Translation::Relay do
  include Builders

  # Named apart from the video relay's own list scheduler on purpose: a class
  # opened inside a describe block is top level, so two files sharing one
  # name have the later-loaded definition win for both.
  class TranslationListScheduler
    Job = Struct.new(:kind, :run_at, :payload, :community, :discard_payload, keyword_init: true)

    def initialize
      @jobs = []
      @handler = nil
    end

    attr_reader :jobs

    def register(kind, max_age: nil, priority: nil, &block)
      @handler = block
      self
    end

    def schedule(kind:, run_at:, payload: {}, community: nil, recurrence: nil, discard_payload: false)
      @jobs << Job.new(kind: kind.to_s, run_at: run_at, payload: payload, community: community,
                       discard_payload: discard_payload)
    end

    def run_all
      @jobs.shift.tap { |job| @handler.call(job) } until @jobs.empty?
    end
  end

  class FakeTranslateClient
    def initialize(&block)
      @block = block || ->(text, source:, target:) { "[#{target}] #{text}" }
      @calls = []
    end

    attr_reader :calls

    def translate(text, source:, target:)
      @calls << [text, source, target]
      @block.call(text, source: source, target: target)
    end
  end

  let(:ep_a) { endpoint("a", adapter: :fake, account: "acct-a") }
  let(:ep_b) { endpoint("b", adapter: :fake, account: "acct-b") }
  let(:room_b) { room("room-b", ep_b) }
  let(:topology_obj) { topology(room("room-a", ep_a), room_b) }

  let(:adapter_b) { Fakes::RecordingAdapter.new(account: "acct-b") }
  let(:adapters) { { [:fake, "acct-b"] => adapter_b } }

  let(:storage) { Rubotty::Storage::Memory.new }
  let(:loop_guard) { Rubotty::Core::LoopGuard.new(storage: storage) }
  let(:scheduler) { TranslationListScheduler.new }
  let(:client) { FakeTranslateClient.new }

  let(:relay) do
    described_class.new(scheduler: scheduler, storage: storage, topology: topology_obj, adapters: adapters,
                        loop_guard: loop_guard, logger: Rubotty::Log.null, client: client)
  end

  let(:sender_label) { Rubotty::Core::SenderLabel.for(author: author(username: "ada"), platform: "telegram") }

  it "does nothing without a scheduler" do
    inert = described_class.new(scheduler: nil, storage: storage, topology: topology_obj, adapters: adapters)

    expect(inert.enqueue_new(source_ref: ref("a", "1"), source_language: "en", target_room: room_b,
                             target_language: "pt", body: rich("hi"), sender_label: sender_label)).to be_nil
  end

  it "asks the scheduler to discard the payload once a new-message job settles, so the audit trail does not keep the message" do
    relay.enqueue_new(source_ref: ref("a", "1"), source_language: "en", target_room: room_b,
                      target_language: "pt", body: rich("hello"), sender_label: sender_label)

    expect(scheduler.jobs.last.discard_payload).to be(true)
  end

  it "asks the scheduler to discard the payload once an edit job settles too" do
    relay.enqueue_edit(source_ref: ref("a", "1"), source_language: "en", text: "hello again")

    expect(scheduler.jobs.last.discard_payload).to be(true)
  end

  it "delivers a translated copy to every sending endpoint of the target room" do
    relay.enqueue_new(source_ref: ref("a", "1"), source_language: "en", target_room: room_b,
                      target_language: "pt", body: rich("hello"), sender_label: sender_label)
    scheduler.run_all

    expect(adapter_b.delivered.length).to eq(1)
    message = adapter_b.delivered.first.last
    expect(message.body.text).to include("[pt] hello")
    expect(message.sender_label.to_s).to include("ada")
  end

  it "records the copy in the shared message map and the loop guard's ledger, at the point of creation" do
    relay.enqueue_new(source_ref: ref("a", "1"), source_language: "en", target_room: room_b,
                      target_language: "pt", body: rich("hello"), sender_label: sender_label)
    scheduler.run_all

    copy = storage.counterparts(ref("a", "1"), endpoint_id: "b").first
    expect(copy).not_to be_nil
    expect(loop_guard.recently_delivered?(copy)).to be(true)
  end

  it "skips the LibreTranslate call for a message with nothing translatable in it" do
    relay.enqueue_new(source_ref: ref("a", "1"), source_language: "en", target_room: room_b,
                      target_language: "pt", body: rich("https://example.com/x"), sender_label: sender_label)
    scheduler.run_all

    expect(client.calls).to be_empty
    expect(adapter_b.delivered.first.last.body.text).to include("https://example.com/x")
  end

  it "relays the original verbatim when the translated answer cannot be trusted to reconstruct" do
    broken = FakeTranslateClient.new { |_text, **| "nothing you can put back together" }
    relay_with_broken = described_class.new(scheduler: scheduler, storage: storage, topology: topology_obj,
                                             adapters: adapters, loop_guard: loop_guard, client: broken)

    relay_with_broken.enqueue_new(source_ref: ref("a", "1"), source_language: "en", target_room: room_b,
                                  target_language: "pt", body: rich("see https://example.com/x"),
                                  sender_label: sender_label)
    scheduler.run_all

    expect(adapter_b.delivered.first.last.body.text).to include("https://example.com/x")
  end

  it "never blocks: a failing translate call raises so the durable scheduler retries it, not the caller" do
    failing = Class.new { def translate(*, **) = raise Rubotty::Translation::Client::Error, "down" }.new
    relay_with_failing = described_class.new(scheduler: scheduler, storage: storage, topology: topology_obj,
                                              adapters: adapters, loop_guard: loop_guard, client: failing)
    relay_with_failing.enqueue_new(source_ref: ref("a", "1"), source_language: "en", target_room: room_b,
                                   target_language: "pt", body: rich("hello"), sender_label: sender_label)

    expect { scheduler.run_all }.to raise_error(Rubotty::Translation::Client::Error)
    expect(adapter_b.delivered).to be_empty
  end

  it "drops a job whose target room no longer exists rather than raising" do
    relay.enqueue_new(source_ref: ref("a", "1"), source_language: "en", target_room: room("gone", ep_b),
                      target_language: "pt", body: rich("hello"), sender_label: sender_label)

    expect { scheduler.run_all }.not_to raise_error
    expect(adapter_b.delivered).to be_empty
  end

  describe "an edit" do
    it "re-translates the new text and edits the destination it remembered" do
      relay.enqueue_new(source_ref: ref("a", "1"), source_language: "en", target_room: room_b,
                        target_language: "pt", body: rich("hello"), sender_label: sender_label)
      scheduler.run_all
      copy = storage.counterparts(ref("a", "1"), endpoint_id: "b").first

      relay.enqueue_edit(source_ref: ref("a", "1"), source_language: "en", text: "hello there")
      scheduler.run_all

      expect(adapter_b.edited.length).to eq(1)
      endpoint_id, native_id, message = adapter_b.edited.first
      expect(endpoint_id).to eq("b")
      expect(native_id).to eq(copy.native_id)
      expect(message.body.text).to include("[pt] hello there")
    end

    it "does nothing for a source ref that was never translated anywhere" do
      relay.enqueue_edit(source_ref: ref("a", "9"), source_language: "en", text: "edited")

      expect { scheduler.run_all }.not_to raise_error
      expect(adapter_b.edited).to be_empty
    end
  end
end
