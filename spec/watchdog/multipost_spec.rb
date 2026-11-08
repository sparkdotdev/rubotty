# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Watchdog::Multipost do
  let(:tg) { endpoint("tg") }
  let(:dc) { endpoint("dc") }
  let(:irc) { endpoint("irc") }
  let(:storage) { Rubotty::Storage::Memory.new }

  # A watchdog on a clock the specs advance, so the window is deterministic.
  before { @now = Time.now }

  let(:watchdog) { described_class.new(storage: storage, clock: -> { @now }) }

  def spam = "join my brand new channel right now"

  # Evaluate one post: the same author and content by default, from +origin+, so
  # a spec drives the cross-channel window by varying only the channel.
  def evaluate(origin, text: spam, author_id: "u1", config: default_config)
    msg = message(origin, text: text, author: author(native_id: author_id))
    watchdog.evaluate(Rubotty::Features::Context.new(message: msg, config: config))
  end

  def default_config = { channel_threshold: 2, window_seconds: 300, min_length: 10 }

  describe "detecting a cross-post" do
    it "lets the first post stand: one channel is below the threshold" do
      expect(evaluate(tg)).to be_pass
    end

    it "removes the same content once it reaches a second distinct channel" do
      evaluate(tg)
      verdict = evaluate(dc)
      expect(verdict).to be_remove
      expect(verdict.reason).to eq("Posting the same message across multiple channels is not allowed.")
    end

    it "keeps removing every further cross-post while the window is warm" do
      evaluate(tg)
      expect(evaluate(dc)).to be_remove
      expect(evaluate(irc)).to be_remove
    end

    it "carries the channel count and threshold as audit metadata" do
      evaluate(tg)
      verdict = evaluate(dc)
      expect(verdict.metadata).to eq(channels: 2, threshold: 2)
    end

    it "normalises case and whitespace, so trivial reformatting does not evade it" do
      evaluate(tg, text: "Join My Brand   New Channel RIGHT now")
      expect(evaluate(dc, text: "join my brand new channel right now")).to be_remove
    end
  end

  describe "what it leaves alone" do
    it "does not trip on a repeat in the SAME channel: that is one distinct channel" do
      evaluate(tg)
      expect(evaluate(tg)).to be_pass
    end

    it "does not trip once the first post has aged out of the window" do
      evaluate(tg)
      @now += 400 # past the 300s window
      expect(evaluate(dc)).to be_pass
    end

    it "ignores trivially short messages, so common short lines are not mistaken for spam" do
      evaluate(tg, text: "ok")
      expect(evaluate(dc, text: "ok")).to be_pass
    end

    it "keeps distinct authors independent: two people are not one cross-poster" do
      evaluate(tg, author_id: "u1")
      expect(evaluate(dc, author_id: "u2")).to be_pass
    end

    it "keeps distinct content independent" do
      evaluate(tg, text: "the first announcement here")
      expect(evaluate(dc, text: "an entirely different message")).to be_pass
    end

    it "stays inert when there is no attributable author" do
      msg = message(tg, text: spam, author: author(native_id: nil))
      expect(watchdog.evaluate(Rubotty::Features::Context.new(message: msg, config: default_config))).to be_pass
    end
  end

  describe "configuration" do
    it "honours a higher channel_threshold before it removes" do
      config = default_config.merge(channel_threshold: 3)
      expect(evaluate(tg, config: config)).to be_pass
      expect(evaluate(dc, config: config)).to be_pass
      expect(evaluate(irc, config: config)).to be_remove
    end

    it "treats a threshold of one (or less) as unset, staying inert" do
      config = default_config.merge(channel_threshold: 1)
      evaluate(tg, config: config)
      expect(evaluate(dc, config: config)).to be_pass
    end

    it "honours a per-scope removal_reason override in the verdict" do
      config = default_config.merge(removal_reason: "One channel is enough")
      evaluate(tg, config: config)
      expect(evaluate(dc, config: config).reason).to eq("One channel is enough")
    end

    it "respects a per-scope min_length, ignoring messages below it" do
      config = default_config.merge(min_length: 100)
      evaluate(tg, config: config)
      expect(evaluate(dc, config: config)).to be_pass
    end

    it "accepts a human duration for the window" do
      config = default_config.merge(window_seconds: "5m")
      evaluate(tg, config: config)
      @now += 200 # inside 5 minutes
      expect(evaluate(dc, config: config)).to be_remove
    end
  end
end
