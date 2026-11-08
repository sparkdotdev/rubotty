# frozen_string_literal: true

require "spec_helper"
require "sequel"

RSpec.describe Rubotty::Core::AuditLog do
  describe ".for" do
    it "returns a Sequel store for a db-backed storage and a Null store otherwise" do
      backed = Struct.new(:db).new(Sequel.sqlite)
      expect(described_class.for(backed)).to be_a(described_class::Sequel)
      expect(described_class.for(Object.new)).to be_a(described_class::Null)
    end
  end

  describe described_class::Null do
    subject(:store) { described_class.new }

    it "is not durable and no-ops every operation" do
      expect(store.durable?).to be(false)
      expect(store.record(community: "c", source: "moderation", action: "ban")).to be_nil
      expect(store.query(community: "c")).to eq([])
      expect(store.count(community: "c")).to eq(0)
    end
  end

  describe described_class::Sequel, :control_plane do
    let(:db) { Sequel.sqlite }
    let(:store) { described_class.new(db: db) }

    before { Rubotty::ControlPlane::Migrator.run(db) }

    def record(**overrides)
      store.record(**{ community: "acme", source: "moderation", action: "ban" }.merge(overrides))
    end

    it "records an event and reads it back with every field" do
      event = record(
        adapter: "telegram", channel: "tg-main", actor: "Alex", actor_native_id: "55",
        subject: "Bad Actor", subject_native_id: "777", target_ref: "tg:900",
        reason: "spam", outcome: "1/1", metadata: { results: %w[tg:done] }
      )
      expect(event.id).not_to be_nil

      read = store.query(community: "acme").first
      expect(read).to have_attributes(
        community: "acme", source: "moderation", action: "ban", adapter: "telegram",
        channel: "tg-main", actor: "Alex", actor_native_id: "55", subject: "Bad Actor",
        subject_native_id: "777", target_ref: "tg:900", reason: "spam", outcome: "1/1"
      )
      expect(read.metadata).to eq("results" => %w[tg:done])
    end

    it "takes an excerpt for the alert and writes no message text down" do
      event = record(action: "delete", target_ref: "tg:900", excerpt: "the words that got removed")
      expect(event.id).not_to be_nil

      read = store.query(community: "acme").first
      expect(read.target_ref).to eq("tg:900")
      expect(read.to_h.values.map(&:to_s).join(" ")).not_to include("the words that got removed")
      expect(db[:audit_events].columns).not_to include(:excerpt)
    end

    it "returns a community's events most recent first" do
      record(action: "kick", now: Time.now - 60)
      record(action: "ban", now: Time.now)
      expect(store.query(community: "acme").map(&:action)).to eq(%w[ban kick])
    end

    it "scopes strictly to the community asked for" do
      record(community: "acme", action: "ban")
      record(community: "other", action: "ban")
      expect(store.query(community: "acme").size).to eq(1)
    end

    it "reads an explicit set of communities without including the rest" do
      record(community: "acme", action: "ban")
      record(community: "other", action: "kick")
      record(community: "elsewhere", action: "delete")

      expect(store.query(communities: %w[acme other]).map(&:action)).to contain_exactly("ban", "kick")
      expect(store.count(communities: %w[acme other])).to eq(2)
    end

    it "filters by source, action and subject" do
      record(source: "moderation", action: "ban", subject_native_id: "777")
      record(source: "word_filter", action: "delete", subject_native_id: "888")
      expect(store.query(community: "acme", source: "word_filter").map(&:action)).to eq(%w[delete])
      expect(store.query(community: "acme", action: "ban").size).to eq(1)
      expect(store.query(community: "acme", subject_native_id: "888").map(&:source)).to eq(%w[word_filter])
    end

    it "filters by a since time and caps with a limit" do
      record(action: "old", now: Time.now - 3600)
      record(action: "fresh", now: Time.now)
      expect(store.query(community: "acme", since: Time.now - 60).map(&:action)).to eq(%w[fresh])
      expect(store.query(community: "acme", limit: 1).size).to eq(1)
    end

    it "counts the matching events" do
      record(action: "ban")
      record(action: "kick")
      expect(store.count(community: "acme")).to eq(2)
      expect(store.count(community: "acme", action: "ban")).to eq(1)
    end
  end
end
