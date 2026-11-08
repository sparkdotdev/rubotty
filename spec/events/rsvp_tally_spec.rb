# frozen_string_literal: true

require "spec_helper"

# The unified RSVP tally: event_rsvps folded with Discord's native interested and
# going list, over a migrated in-memory database with a fake Discord adapter
# standing in for #read_native_rsvps.
RSpec.describe Rubotty::Events::RsvpTally, :control_plane do
  class FakeDiscordNative < Rubotty::Adapters::Base
    class << self
      def adapter_name = :discord
    end

    def initialize(rsvps: [])
      super(account: "discord", settings: {}, dispatcher: nil, logger: Rubotty::Log.null)
      @rsvps = rsvps
    end

    def capabilities = Rubotty::Adapters::Capabilities.new

    def own_account_id = "dc-bot"

    def start = self

    def stop = self

    def supports_native_events? = true

    attr_reader :last_endpoint

    def read_native_rsvps(_native_id, endpoint = nil)
      @last_endpoint = endpoint
      @rsvps
    end
  end

  let(:db) { migrated_db }
  let(:models) { build_models(db) }
  let(:now) { Time.now }

  let(:community) do
    models.community.create(slug: "c", name: "C", status: "active", settings: "{}",
                            created_at: now, updated_at: now)
  end

  let(:room) do
    models.room.create(community_id: community.id, room_key: "gaming", label: "Gaming",
                       display_name: "{}", created_at: now, updated_at: now)
  end

  def event(rsvp_mode:, native_refs: "{}")
    row = models.event.create(
      community_id: community.id, room_id: room.id, title: "Raid Night",
      starts_at: now + 3600, kind: "gaming", rsvp_mode: rsvp_mode, status: "scheduled",
      native_refs: native_refs, created_at: now, updated_at: now
    )
    Rubotty::Events::Event.new(row)
  end

  def rsvp(ev, identity:, response:, platform: "telegram")
    models.event_rsvp.create(event_id: ev.id, identity: identity, platform: platform,
                             response: response, responded_at: now)
  end

  # What the passive directory holds after somebody has been seen in the room.
  def observed(native_id:, username: nil, display_name: nil, adapter: "telegram")
    models.observed_identity.create(
      community_id: community.id, adapter: adapter, native_id: native_id,
      username: username, display_name: display_name, first_seen_at: now, last_seen_at: now
    )
  end

  let(:discord) { FakeDiscordNative.new }
  let(:adapters) { { [:discord, "discord"] => discord } }

  subject(:tally) { described_class.new(models: models, adapters: adapters, logger: Rubotty::Log.null) }

  # Wires +room_row+ into the live topology as a bridged Discord channel, the
  # minimum SnapshotBuilder needs to resolve it back into a Core::Endpoint.
  def bridge_discord_channel(room_row, channel_id:)
    connection = models.platform_connection.create(
      community_id: community.id, adapter: "discord", account: "discord",
      external_id: "guild-#{channel_id}", created_at: now, updated_at: now
    )
    channel_row = models.channel.create(
      community_id: community.id, platform_connection_id: connection.id,
      adapter: "discord", account: "discord", route_key: channel_id,
      endpoint_key: "dc-#{channel_id}",
      settings: Rubotty::ControlPlane::Models.dump_json(channel_id: channel_id),
      created_at: now, updated_at: now
    )
    models.room_channel.create(room_id: room_row.id, channel_id: channel_row.id, created_at: now)
  end

  # A tally that can actually resolve the event's own room, which is what
  # scopes the native read to this community's guild. Anything folding
  # Discord's native list in needs one: with no room there is no endpoint,
  # and with no endpoint the native list is deliberately not read at all.
  def bridged_tally(native)
    bridge_discord_channel(room, channel_id: "999999")
    described_class.new(models: models, adapters: { [:discord, "discord"] => native },
                        registry: Rubotty::ControlPlane::Registry.new(models: models),
                        logger: Rubotty::Log.null)
  end

  describe "#for" do
    it "is empty for a none-mode event" do
      expect(tally.for(event(rsvp_mode: "none"))).to eq({})
    end

    it "counts recorded rows for an affirm-mode event" do
      ev = event(rsvp_mode: "affirm")
      rsvp(ev, identity: "u1", response: "in")
      rsvp(ev, identity: "u2", response: "in")
      expect(tally.for(ev)).to eq(in: 2)
    end

    it "is zeroed, not empty, for a fresh full-mode event" do
      ev = event(rsvp_mode: "full")
      expect(tally.for(ev)).to eq(yes: 0, maybe: 0, no: 0)
    end

    it "counts each response bucket for a full-mode event" do
      ev = event(rsvp_mode: "full")
      rsvp(ev, identity: "u1", response: "yes")
      rsvp(ev, identity: "u2", response: "yes")
      rsvp(ev, identity: "u3", response: "maybe")
      rsvp(ev, identity: "u4", response: "no")
      expect(tally.for(ev)).to eq(yes: 2, maybe: 1, no: 1)
    end

    it "does not read the native list at all when the event has no Discord native ref" do
      ev = event(rsvp_mode: "full")
      discord_native = FakeDiscordNative.new(rsvps: [{ identity: "d1", response: "interested" }])
      merged = described_class.new(models: models, adapters: { [:discord, "discord"] => discord_native })
      expect(merged.for(ev)).to eq(yes: 0, maybe: 0, no: 0)
    end

    it "folds Discord's native interested/going list in as 'yes' for a full-mode event" do
      ev = event(rsvp_mode: "full", native_refs: Rubotty::ControlPlane::Models.dump_json("discord" => "999"))
      discord_native = FakeDiscordNative.new(rsvps: [{ identity: "d1", response: "interested" },
                                                     { identity: "d2", response: "interested" }])
      expect(bridged_tally(discord_native).for(ev)).to eq(yes: 2, maybe: 0, no: 0)
    end

    it "folds Discord's native list in as 'in' for an affirm-mode event" do
      ev = event(rsvp_mode: "affirm", native_refs: Rubotty::ControlPlane::Models.dump_json("discord" => "999"))
      discord_native = FakeDiscordNative.new(rsvps: [{ identity: "d1", response: "interested" }])
      expect(bridged_tally(discord_native).for(ev)).to eq(in: 1)
    end

    it "lets an explicit ledger row for the SAME identity win over the native entry" do
      ev = event(rsvp_mode: "full", native_refs: Rubotty::ControlPlane::Models.dump_json("discord" => "999"))
      rsvp(ev, identity: "d1", response: "no", platform: "discord")
      discord_native = FakeDiscordNative.new(rsvps: [{ identity: "d1", response: "interested" }])
      merged = described_class.new(models: models, adapters: { [:discord, "discord"] => discord_native })

      # d1 explicitly said "no" through the ledger; Discord's native list still
      # calls them "interested", but the ledger's own answer must win.
      expect(merged.for(ev)).to eq(yes: 0, maybe: 0, no: 1)
    end

    # Issue #1701: read_native_rsvps used to reach the adapter with no room
    # context at all. With a registry given, the room's own bridged Discord
    # endpoint (not just the platform) reaches the adapter, which needs it to
    # resolve the guild this event's room actually lives in.
    it "passes the event's own room's discord endpoint through to the adapter, given a registry" do
      bridge_discord_channel(room, channel_id: "999999")
      registry = Rubotty::ControlPlane::Registry.new(models: models)
      recording = FakeDiscordNative.new
      with_registry = described_class.new(models: models, adapters: { [:discord, "discord"] => recording },
                                          registry: registry, logger: Rubotty::Log.null)
      ev = event(rsvp_mode: "full", native_refs: Rubotty::ControlPlane::Models.dump_json("discord" => "999"))

      with_registry.for(ev)

      expect(recording.last_endpoint&.id).to eq("dc-999999")
    end

    # Issue #1767: it used to call the adapter with a nil endpoint, and the
    # adapter answered a nil by picking the first guild the ACCOUNT knew, which
    # on a shared bot is another community's server. Reading nothing is the
    # only safe answer when the room cannot be resolved.
    it "reads no native list at all without a registry to resolve the room through" do
      bridge_discord_channel(room, channel_id: "999999")
      ev = event(rsvp_mode: "full", native_refs: Rubotty::ControlPlane::Models.dump_json("discord" => "999"))

      expect(tally.for(ev)).to eq(yes: 0, maybe: 0, no: 0)
      expect(discord.last_endpoint).to be_nil
    end

    it "never writes anything back to event_rsvps" do
      ev = event(rsvp_mode: "full", native_refs: Rubotty::ControlPlane::Models.dump_json("discord" => "999"))
      discord_native = FakeDiscordNative.new(rsvps: [{ identity: "d1", response: "interested" }])
      merged = described_class.new(models: models, adapters: { [:discord, "discord"] => discord_native })
      merged.for(ev)
      expect(models.event_rsvp.count).to eq(0)
    end
  end

  describe "#roster" do
    def going(ev) = tally.roster(ev)["yes"]

    it "carries the handle for somebody who set one" do
      ev = event(rsvp_mode: "full")
      rsvp(ev, identity: "5502187744", response: "yes")
      observed(native_id: "5502187744", username: "pete", display_name: "Pinniped Pete")

      voter = going(ev).first
      expect(voter.handle).to eq("pete")
      expect(Rubotty::Core::VoteRoster.inline(going(ev), on_platform: "telegram")).to eq("@pete")
    end

    it "carries the directory's name for somebody who never set a handle" do
      ev = event(rsvp_mode: "full")
      rsvp(ev, identity: "5502187744", response: "yes")
      observed(native_id: "5502187744", display_name: "Pinniped Pete")

      voter = going(ev).first
      expect(voter.handle).to be_nil
      expect(voter.name).to eq("Pinniped Pete")
      expect(Rubotty::Core::VoteRoster.inline(going(ev), on_platform: "telegram")).to eq("Pinniped Pete")
    end

    it "says someone, never the platform id, for somebody the directory has never seen" do
      ev = event(rsvp_mode: "full")
      rsvp(ev, identity: "5502187744", response: "yes")

      voter = going(ev).first
      expect(voter.handle).to be_nil
      expect(voter.name).to be_nil
      expect(Rubotty::Core::VoteRoster.inline(going(ev), on_platform: "telegram")).to eq("someone")
    end

    it "names a Discord-native responder the directory has never seen, from the payload's own handle" do
      ev = event(rsvp_mode: "full", native_refs: Rubotty::ControlPlane::Models.dump_json("discord" => "999"))
      native = FakeDiscordNative.new(
        rsvps: [{ identity: "88", response: "interested", username: "quill", display: "Quill Marlowe" }]
      )

      voter = bridged_tally(native).roster(ev)["yes"].first
      expect(voter.handle).to eq("quill")
      expect(voter.name).to eq("Quill Marlowe")
      expect(Rubotty::Core::VoteRoster.inline([voter], on_platform: "discord")).to eq("@quill")
    end

    it "records that native responder as an ordinary sighting, so the directory can name them elsewhere" do
      ev = event(rsvp_mode: "full", native_refs: Rubotty::ControlPlane::Models.dump_json("discord" => "999"))
      native = FakeDiscordNative.new(
        rsvps: [{ identity: "88", response: "interested", username: "quill", display: "Quill Marlowe" }]
      )
      bridged_tally(native).roster(ev)

      row = models.observed_identity.where(community_id: community.id, adapter: "discord", native_id: "88").first
      expect(row).not_to be_nil
      expect(row[:username]).to eq("quill")
      expect(row[:display_name]).to eq("Quill Marlowe")
    end

    it "throttles the directory write across repeated redraws of the same card" do
      ev = event(rsvp_mode: "full", native_refs: Rubotty::ControlPlane::Models.dump_json("discord" => "999"))
      native = FakeDiscordNative.new(
        rsvps: [{ identity: "88", response: "interested", username: "quill", display: "Quill Marlowe" }]
      )
      merged = bridged_tally(native)

      merged.roster(ev)
      first_seen = models.observed_identity.where(community_id: community.id, adapter: "discord",
                                                   native_id: "88").first[:last_seen_at]

      # A second redraw moments later must not cost another directory write.
      merged.roster(ev)
      again = models.observed_identity.where(community_id: community.id, adapter: "discord",
                                              native_id: "88").first[:last_seen_at]
      expect(again).to eq(first_seen)
    end

    it "still falls back to someone for a native responder Discord sent no name for" do
      ev = event(rsvp_mode: "full", native_refs: Rubotty::ControlPlane::Models.dump_json("discord" => "999"))
      native = FakeDiscordNative.new(rsvps: [{ identity: "88", response: "interested" }])
      merged = bridged_tally(native)

      expect(Rubotty::Core::VoteRoster.inline(merged.roster(ev)["yes"], on_platform: "discord")).to eq("someone")
    end

    it "keeps a directory entry from another community out of it" do
      other = models.community.create(slug: "other", name: "Other", status: "active", settings: "{}",
                                      created_at: now, updated_at: now)
      models.observed_identity.create(
        community_id: other.id, adapter: "telegram", native_id: "5502187744",
        username: "pete", display_name: "Pinniped Pete", first_seen_at: now, last_seen_at: now
      )
      ev = event(rsvp_mode: "full")
      rsvp(ev, identity: "5502187744", response: "yes")

      expect(Rubotty::Core::VoteRoster.inline(going(ev), on_platform: "telegram")).to eq("someone")
    end
  end
end
