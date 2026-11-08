# frozen_string_literal: true

require "spec_helper"
require "stringio"

# Places Matrix used to drop something with a clean log.
RSpec.describe "Matrix logging" do
  let(:client) { MatrixFakes::Client.new }
  let(:sync) { MatrixFakes::Sync.new }
  let(:dispatcher) { Fakes::RecordingDispatcher.new }
  let(:logs) { StringIO.new }
  let(:logger) { Rubotty::Log.build(level: "debug", io: logs) }

  let(:general) do
    endpoint("mx-general", adapter: :matrix, settings: { room_id: "!room:example.org" })
  end

  subject(:adapter) do
    Rubotty::Adapters::Matrix::Adapter.new(
      account: "mx",
      settings: { token: "t", token_env: "MATRIX_ACCESS_TOKEN", homeserver: "https://example.org" },
      dispatcher: dispatcher, logger: logger, endpoints: [general]
    ).replace_client(client).replace_sync(sync)
  end

  it "warns instead of quietly no-opping when a removal finds nothing tracked" do
    thumbs = Rubotty::Core::Reaction.new(emoji: "👍")
    adapter.sync_reactions(general, "$target", desired: [], previous: [thumbs])
    expect(client.redactions).to be_empty
    expect(logs.string).to include("no tracked event id")
  end

  def deliver(event) = adapter.handle_event("!room:example.org", event)

  it "says an encrypted room cannot be bridged instead of going quiet" do
    event = { "type" => "m.room.encrypted", "event_id" => "$e1", "sender" => "@ada:example.org", "content" => {} }
    expect(deliver(event)).to be_nil
    expect(logs.string).to include("encrypted")
  end

  it "posts the encrypted notice once per room, not on every event" do
    event = { "type" => "m.room.encrypted", "event_id" => "$e1", "sender" => "@ada:example.org", "content" => {} }
    deliver(event)
    deliver(event.merge("event_id" => "$e2"))
    expect(logs.string.scan("encrypted").size).to eq(1)
  end

  it "logs an event type the dispatch switch does not recognise, instead of vanishing it" do
    event = { "type" => "m.some.future.event", "event_id" => "$f1", "sender" => "@ada:example.org", "content" => {} }
    expect(deliver(event)).to be_nil
    expect(logs.string).to include("m.some.future.event")
  end

  it "says a custom reaction was dropped rather than silently doing nothing" do
    custom = Rubotty::Core::Reaction.new(custom_id: "999", custom_name: "parrot")
    adapter.sync_reactions(general, "$target", desired: [custom], previous: [])
    expect(logs.string).to include("parrot")
  end
end
