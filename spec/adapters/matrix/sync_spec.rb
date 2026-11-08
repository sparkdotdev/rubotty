# frozen_string_literal: true

require "spec_helper"
require "stringio"

RSpec.describe Rubotty::Adapters::Matrix::Sync do
  let(:events) { [] }
  let(:invites) { [] }
  let(:responses) { [] }

  let(:client) do
    Class.new do
      attr_accessor :responses

      def initialize(responses) = @responses = responses

      def sync(since: nil, timeout_ms: 30_000, full_state: false)
        @responses.shift || { "next_batch" => "s-end" }
      end
    end.new(responses)
  end

  subject(:sync) do
    described_class.new(
      client: client,
      on_event: ->(room_id, event) { events << [room_id, event] },
      on_invite: ->(room_id, state_events) { invites << [room_id, state_events] },
      logger: Rubotty::Log.null, timeout_ms: 30_000
    )
  end

  it "delivers a rooms.join timeline event" do
    responses << {
      "next_batch" => "s1",
      "rooms" => { "join" => { "!a:x" => { "timeline" => { "events" => [{ "type" => "m.room.message" }] } } } }
    }
    sync.send(:poll_once)
    expect(events).to eq([["!a:x", { "type" => "m.room.message" }]])
  end

  # An invite sitting in rooms.invite was never read at all, only rooms.join.
  it "delivers a rooms.invite's stripped state, which rooms.join never carries" do
    responses << {
      "next_batch" => "s1",
      "rooms" => { "invite" => { "!b:x" => { "invite_state" => { "events" => [{ "type" => "m.room.member" }] } } } }
    }
    sync.send(:poll_once)
    expect(invites).to eq([["!b:x", [{ "type" => "m.room.member" }]]])
  end

  it "delivers both a join and an invite from the same response" do
    responses << {
      "next_batch" => "s1",
      "rooms" => {
        "join" => { "!a:x" => { "timeline" => { "events" => [{ "type" => "m.room.message" }] } } },
        "invite" => { "!b:x" => { "invite_state" => { "events" => [{ "type" => "m.room.member" }] } } }
      }
    }
    sync.send(:poll_once)
    expect(events.size).to eq(1)
    expect(invites.size).to eq(1)
  end

  it "does nothing for a response with neither key" do
    responses << { "next_batch" => "s1", "rooms" => {} }
    sync.send(:poll_once)
    expect(events).to be_empty
    expect(invites).to be_empty
  end

  it "skips invite handling with no on_invite given, instead of raising" do
    no_invite_sync = described_class.new(
      client: client, on_event: ->(room_id, event) { events << [room_id, event] },
      logger: Rubotty::Log.null, timeout_ms: 30_000
    )
    responses << {
      "next_batch" => "s1",
      "rooms" => { "invite" => { "!b:x" => { "invite_state" => { "events" => [] } } } }
    }
    expect { no_invite_sync.send(:poll_once) }.not_to raise_error
  end

  # A limited timeline means the server truncated the gap between two polls
  # (a busy room, or the first poll after a fast initial sync); there is
  # nowhere here to backfill it from, but it used to vanish with no trace at
  # all, not even a log line.
  it "logs a limited timeline rather than silently continuing as though nothing was missed" do
    logs = StringIO.new
    logging_sync = described_class.new(
      client: client, on_event: ->(room_id, event) { events << [room_id, event] },
      logger: Rubotty::Log.build(level: "debug", io: logs), timeout_ms: 30_000
    )
    responses << {
      "next_batch" => "s1",
      "rooms" => {
        "join" => {
          "!a:x" => { "timeline" => { "events" => [{ "type" => "m.room.message" }], "limited" => true } }
        }
      }
    }
    logging_sync.send(:poll_once)
    expect(events).to eq([["!a:x", { "type" => "m.room.message" }]])
    expect(logs.string).to include("!a:x").and include("limited")
  end

  it "keeps polling when on_invite raises, the same way on_event is protected" do
    raising_sync = described_class.new(
      client: client, on_event: ->(room_id, event) { events << [room_id, event] },
      on_invite: ->(*) { raise "boom" },
      logger: Rubotty::Log.null, timeout_ms: 30_000
    )
    responses << {
      "next_batch" => "s1",
      "rooms" => { "invite" => { "!b:x" => { "invite_state" => { "events" => [] } } } }
    }
    expect { raising_sync.send(:poll_once) }.not_to raise_error
  end
end
