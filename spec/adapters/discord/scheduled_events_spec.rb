# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Adapters::Discord::ScheduledEvents do
  # A plain Hash stands in for a control-plane events row; Event only ever reads
  # columns by symbol key.
  def row(overrides = {})
    {
      id: 1, community_id: 10, room_id: 20, title: "Raid night",
      description: "Bring your A game", timezone: "Europe/Lisbon", kind: "gaming",
      game_title: "Baldur's Gate 3", server_address: "raid.example.com:27015", url: nil,
      rsvp_mode: "full", status: "scheduled",
      reminder_intervals: nil, native_refs: "{}", created_by: "sample_owner",
      starts_at: Time.utc(2026, 8, 1, 20, 0, 0), ends_at: nil
    }.merge(overrides)
  end

  def event_for(overrides = {}) = Rubotty::Events::Event.new(row(overrides))

  describe ".payload_for" do
    it "maps title, description and start time to Discord's create/modify body" do
      payload = described_class.payload_for(event_for)

      expect(payload[:name]).to eq("Raid night")
      expect(payload[:description]).to eq("Bring your A game")
      expect(payload[:scheduled_start_time]).to eq("2026-08-01T20:00:00Z")
    end

    it "is always an EXTERNAL event at GUILD_ONLY privacy, never a voice/stage entity" do
      payload = described_class.payload_for(event_for)

      expect(payload[:entity_type]).to eq(described_class::ENTITY_TYPE_EXTERNAL)
      expect(payload[:privacy_level]).to eq(described_class::PRIVACY_LEVEL_GUILD_ONLY)
    end

    it "uses the server address as the location for a gaming event" do
      payload = described_class.payload_for(event_for(server_address: "play.example.com", url: nil))
      expect(payload[:entity_metadata][:location]).to eq("play.example.com")
    end

    it "falls back to the url when there is no server address" do
      payload = described_class.payload_for(
        event_for(kind: "general", server_address: nil, url: "https://meet.example.com/abc")
      )
      expect(payload[:entity_metadata][:location]).to eq("https://meet.example.com/abc")
    end

    it "names the gap plainly when the event carries neither" do
      payload = described_class.payload_for(event_for(server_address: nil, url: nil))
      expect(payload[:entity_metadata][:location]).to eq("Location TBD")
    end

    it "passes ends_at through in UTC when the event announces one" do
      payload = described_class.payload_for(event_for(ends_at: Time.utc(2026, 8, 1, 23, 0, 0)))
      expect(payload[:scheduled_end_time]).to eq("2026-08-01T23:00:00Z")
    end

    # Discord rejects an EXTERNAL event with no scheduled_end_time, and Rubotty
    # treats an event's end as optional.
    it "manufactures an end time when the event announces none" do
      payload = described_class.payload_for(event_for(ends_at: nil))
      expected = Time.utc(2026, 8, 1, 20, 0, 0) + described_class::DEFAULT_DURATION_SECONDS
      expect(payload[:scheduled_end_time]).to eq(expected.iso8601)
    end

    it "clamps a description over Discord's 1000 character limit" do
      long = "x" * 1_100
      payload = described_class.payload_for(event_for(description: long))
      expect(payload[:description].length).to eq(described_class::DESCRIPTION_LIMIT)
      expect(payload[:description]).to end_with("…")
    end

    it "clamps a location over Discord's 100 character limit" do
      long_url = "https://example.com/#{"a" * 200}"
      payload = described_class.payload_for(event_for(kind: "general", server_address: nil, url: long_url))
      expect(payload[:entity_metadata][:location].length).to eq(described_class::LOCATION_LIMIT)
    end

    it "never raises on a nil description, rendering an empty string instead" do
      payload = described_class.payload_for(event_for(description: nil))
      expect(payload[:description]).to eq("")
    end
  end

  describe ".rsvps_from" do
    it "shapes Discord's interested list into neutral identity/response pairs" do
      users = [
        { "guild_scheduled_event_id" => "1", "user" => { "id" => "111", "username" => "ada" } },
        { "guild_scheduled_event_id" => "1", "user" => { "id" => "222", "username" => "grace" } }
      ]

      expect(described_class.rsvps_from(users)).to eq(
        [{ identity: "111", response: "interested", username: "ada", display: nil },
         { identity: "222", response: "interested", username: "grace", display: nil }]
      )
    end

    it "keeps the global name Discord sends as the display, since it is the nicer thing to show" do
      users = [{ "user" => { "id" => "111", "username" => "ada", "global_name" => "Ada L" } }]

      expect(described_class.rsvps_from(users)).to eq(
        [{ identity: "111", response: "interested", username: "ada", display: "Ada L" }]
      )
    end

    it "leaves a blank handle or global name nil rather than carrying empty text" do
      users = [{ "user" => { "id" => "111", "username" => "", "global_name" => "  " } }]

      expect(described_class.rsvps_from(users)).to eq(
        [{ identity: "111", response: "interested", username: nil, display: nil }]
      )
    end

    it "is an empty array for no responses" do
      expect(described_class.rsvps_from([])).to eq([])
      expect(described_class.rsvps_from(nil)).to eq([])
    end

    it "skips a malformed entry rather than raising" do
      users = [{ "user" => { "id" => "111" } }, { "not" => "a user entry" }, "garbage"]
      expect(described_class.rsvps_from(users)).to eq(
        [{ identity: "111", response: "interested", username: nil, display: nil }]
      )
    end
  end

  describe "instance methods, against a fake client" do
    let(:client) { DiscordFakes::Client.new }
    subject(:scheduled_events) { described_class.new(client: client, logger: Rubotty::Log.null) }

    describe "#create" do
      it "sends the mapped payload to the resolved guild and returns the native id" do
        native_id = scheduled_events.create(event_for, guild_id: "g1")

        expect(native_id).to eq("1")
        expect(client.created_scheduled_events.first[:guild_id]).to eq("g1")
        expect(client.created_scheduled_events.first[:payload][:name]).to eq("Raid night")
      end

      it "is a no-op, not a raise, when no guild is known" do
        expect(scheduled_events.create(event_for, guild_id: nil)).to be_nil
        expect(client.created_scheduled_events).to be_empty
      end
    end

    describe "#update" do
      it "sends the mapped payload for the given native id" do
        scheduled_events.update("42", event_for(title: "Raid night (rescheduled)"), guild_id: "g1")

        recorded = client.updated_scheduled_events.first
        expect(recorded[:guild_id]).to eq("g1")
        expect(recorded[:event_id]).to eq("42")
        expect(recorded[:payload][:name]).to eq("Raid night (rescheduled)")
      end

      it "is a no-op when no guild is known" do
        scheduled_events.update("42", event_for, guild_id: nil)
        expect(client.updated_scheduled_events).to be_empty
      end

      it "is a no-op when there is no native id to target" do
        scheduled_events.update(nil, event_for, guild_id: "g1")
        expect(client.updated_scheduled_events).to be_empty
      end
    end

    describe "#delete" do
      it "deletes the native event in the resolved guild" do
        scheduled_events.delete("42", guild_id: "g1")
        expect(client.deleted_scheduled_events).to eq([{ guild_id: "g1", event_id: "42" }])
      end

      it "is a no-op when no guild is known" do
        scheduled_events.delete("42", guild_id: nil)
        expect(client.deleted_scheduled_events).to be_empty
      end
    end

    describe "#rsvps" do
      it "shapes the client's response through .rsvps_from" do
        allow(client).to receive(:scheduled_event_users).and_return(
          [{ "user" => { "id" => "111" } }]
        )
        expect(scheduled_events.rsvps("42", guild_id: "g1")).to eq(
          [{ identity: "111", response: "interested", username: nil, display: nil }]
        )
      end

      it "is an empty array, not a raise, when no guild is known" do
        expect(scheduled_events.rsvps("42", guild_id: nil)).to eq([])
      end

      it "is an empty array when there is no native id" do
        expect(scheduled_events.rsvps(nil, guild_id: "g1")).to eq([])
      end
    end
  end
end
