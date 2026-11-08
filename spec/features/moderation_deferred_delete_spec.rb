# frozen_string_literal: true

require "spec_helper"

# `/delete <time>` books the removal instead of doing it now. The booking is
# durable rather than an in-process timer, since the times this exists for are
# hours or days out and must survive a restart.
RSpec.describe Rubotty::Features::Moderation, "a delete that named a time" do
  let(:tg) { endpoint("tg") }
  let(:adapter) { Fakes::ReactingAdapter.new }
  let(:storage) { Rubotty::Storage::Memory.new }
  let(:operator) { Rubotty::Core::Moderation::Operator.new(name: "Op", identities: { fake: ["55"] }) }
  let(:directory) { Rubotty::Core::Moderation::Directory.new([operator]) }
  let(:commands) do
    Rubotty::Core::Commands.new(actions: Rubotty::Core::Moderation::ACTIONS, logger: Rubotty::Log.null)
  end
  let(:scheduler) { Rubotty::Core::Scheduler.new(logger: Rubotty::Log.null) }
  let(:ephemeral) do
    Rubotty::Core::EphemeralMessage.new(
      adapters: Hash.new(adapter), session_id: "s", topology: topology(room("r", tg)),
      logger: Rubotty::Log.null
    )
  end

  # Stands in for the durable scheduler, keeping what it was asked to book.
  class DeferralBook
    attr_reader :booked

    def initialize = @booked = []

    def schedule(**args)
      @booked << args
      Struct.new(:id).new(@booked.length)
    end
  end

  let(:deferrals) { DeferralBook.new }

  def feature(book: deferrals)
    described_class.new(
      topology: topology(room("r", tg)), adapters: Hash.new(adapter), storage: storage,
      logger: Rubotty::Log.null, commands: commands, cleanup: scheduler,
      cleanup_after: 0, acknowledge: true, ephemeral: ephemeral, deferrals: book
    )
  end

  def issue(text, reply: true)
    feature.call(
      Rubotty::Features::Context.new(
        message: message(
          tg, text: text, native_id: "1000", author: author(native_id: "55"),
              reply_to: (reply ? ref("tg", "900") : nil),
              reply_preview: (Rubotty::Core::ReplyPreview.new(author: author(native_id: "900")) if reply)
        ),
        operators: directory
      )
    )
  end

  def posted = adapter.delivered_to("tg").map { |sent| sent.body.text }.join("\n")

  # The acknowledgement self-deletes on the standard window, so every example
  # here leaves a live scheduler job behind unless it is stopped.
  after { scheduler.stop }

  it "books the removal rather than doing it now" do
    issue("/delete 25 minutes")

    expect(adapter.deleted).not_to include(%w[tg 900])
    expect(deferrals.booked.length).to eq(1)
    expect(deferrals.booked.first[:kind]).to eq(Rubotty::Core::DeferredDeletion::KIND)
  end

  it "books it for the time the operator named" do
    issue("/delete 25 minutes")

    booked_at = deferrals.booked.first[:run_at]
    expect(booked_at).to be > Time.now + (24 * 60)
    expect(booked_at).to be < Time.now + (26 * 60)
  end

  it "reads a weekday and a clock time, the same vocabulary /event takes" do
    issue("/delete tuesday 5pm")

    expect(deferrals.booked.length).to eq(1)
    expect(deferrals.booked.first[:run_at]).to be > Time.now
  end

  it "names the message rather than carrying what it said" do
    issue("/delete 2 hours")

    payload = deferrals.booked.first[:payload]
    expect(payload[Rubotty::Core::DeferredDeletion::NATIVE_KEY]).to eq("900")
    expect(payload[Rubotty::Core::DeferredDeletion::ENDPOINT_KEY]).to eq("tg")
    expect(payload.values.join).not_to include("900 said")
  end

  it "tells the operator when it will happen, and takes the invocation away" do
    issue("/delete 25 minutes")

    expect(posted).to include("I will delete that message at")
    expect(adapter.deleted).to include(%w[tg 1000])
  end

  # Every argument to /delete meant something else before this existed, so one
  # that is not a time still deletes now rather than being refused.
  it "deletes at once when the words are not a time" do
    issue("/delete because it was spam")

    expect(adapter.deleted).to include(%w[tg 900])
    expect(deferrals.booked).to be_empty
  end

  # "now" parses, and is not in the future, so it means what it says.
  it "deletes at once for a time that has already passed" do
    issue("/delete now")

    expect(adapter.deleted).to include(%w[tg 900])
    expect(deferrals.booked).to be_empty
  end

  # Without a reply, /delete already reads its argument as the TEXT of the
  # message to find. Reading a time there would silently retarget a command
  # that has always meant something else.
  it "leaves the reply-less form alone, where an argument names text to match" do
    issue("/delete 25 minutes", reply: false)

    expect(deferrals.booked).to be_empty
  end

  it "says so rather than going quiet when the booking cannot be made" do
    broken = Class.new { def schedule(**) = nil }.new
    feature(book: broken).call(
      Rubotty::Features::Context.new(
        message: message(tg, text: "/delete 25 minutes", native_id: "1000", author: author(native_id: "55"),
                             reply_to: ref("tg", "900"),
                             reply_preview: Rubotty::Core::ReplyPreview.new(author: author(native_id: "900"))),
        operators: directory
      )
    )

    expect(posted).to include("could not book that deletion")
  end

  # Halting here would leave the verb doing nothing at all on a deployment
  # with no control plane: neither booking the removal nor carrying it out.
  it "deletes at once with no durable scheduler at all, which is how it degrades" do
    feature(book: nil).call(
      Rubotty::Features::Context.new(
        message: message(tg, text: "/delete 25 minutes", native_id: "1000", author: author(native_id: "55"),
                             reply_to: ref("tg", "900"),
                             reply_preview: Rubotty::Core::ReplyPreview.new(author: author(native_id: "900"))),
        operators: directory
      )
    )

    expect(adapter.deleted).to include(%w[tg 900])
  end
end
