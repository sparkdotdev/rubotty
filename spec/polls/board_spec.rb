# frozen_string_literal: true

require "spec_helper"

# The poll card, over the seeded SAMPLE "gaming" room with two fake adapters, one
# of which renders its own platform-native timestamp markup.
RSpec.describe Rubotty::Polls::Board, :control_plane do
  # Nothing overridden, so Adapters::Base's fallback renderer is what runs.
  class FakePollPlainAdapter < Rubotty::Adapters::Base
    class << self
      def adapter_name = :telegram
    end

    # Telegram's own shape: reactions exist, but no keycap is on the whitelist,
    # so an inline keyboard is the vote path here.
    CAPS = Rubotty::Adapters::Capabilities.new(
      edits: true, deletes: false, replies: false, reactions: true, buttons: true
    ).freeze

    def initialize
      super(account: "telegram", settings: {}, dispatcher: nil, logger: Rubotty::Log.null)
      @delivered = []
      @edited = []
      @synced = []
      @fail_next = false
    end

    attr_reader :delivered, :edited, :synced

    def fail_next! = (@fail_next = true)

    def capabilities = CAPS

    def own_account_id = "tg-bot"

    def start = self

    def stop = self

    def running? = true

    def deliver(message, endpoint)
      if @fail_next
        @fail_next = false
        raise Rubotty::AdapterError.new("nope", adapter: :telegram)
      end
      @delivered << [endpoint.id, message]
      Rubotty::Core::DeliveryReceipt.new(endpoint_id: endpoint.id, native_id: "tg#{@delivered.size}")
    end

    def edit(message, endpoint, native_id)
      @edited << [endpoint.id, native_id, message]
      Rubotty::Core::DeliveryReceipt.new(endpoint_id: endpoint.id, native_id: native_id)
    end

    def sync_reactions(endpoint, native_id, desired:, previous: [])
      @synced << { endpoint_id: endpoint.id, native_id: native_id, desired: desired }
      nil
    end
  end

  # The <t:UNIX:...> markup Adapters::Discord::Adapter renders, and a platform
  # where the keycaps really can be tapped.
  class FakePollNativeAdapter < FakePollPlainAdapter
    class << self
      def adapter_name = :discord
    end

    KEYCAP_CAPS = Rubotty::Adapters::Capabilities.new(
      edits: true, deletes: false, replies: false, reactions: true
    ).freeze

    def capabilities = KEYCAP_CAPS

    def own_account_id = "dc-bot"

    def deliver(message, endpoint)
      @delivered << [endpoint.id, message]
      Rubotty::Core::DeliveryReceipt.new(endpoint_id: endpoint.id, native_id: "dc#{@delivered.size}")
    end

    def render_timestamp(time, style: :full, tz: nil, now: nil)
      unix = time.to_i
      case style.to_sym
      when :relative then "<t:#{unix}:R>"
      when :both then "<t:#{unix}:F> <t:#{unix}:R>"
      else "<t:#{unix}:F>"
      end
    end
  end

  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:registry) { Rubotty::ControlPlane::Registry.new(models: models) }
  let(:community) { models.community.where(slug: "sample").first }
  let(:room) { models.room.where(community_id: community.id, room_key: "gaming").first }
  let(:now) { Time.utc(2026, 8, 12, 18, 0, 0) }

  let(:tg) { FakePollPlainAdapter.new }
  let(:dc) { FakePollNativeAdapter.new }
  let(:adapter_map) { { [:telegram, "telegram"] => tg, [:discord, "discord"] => dc } }

  let(:writer) { Rubotty::ControlPlane::Polls.new(models: models, logger: Rubotty::Log.null, clock: -> { now }) }
  let(:ballot) { Rubotty::Polls::Ballot.new(models: models, logger: Rubotty::Log.null, clock: -> { now }) }
  let(:activity) { Rubotty::Polls::RoomActivity.new }
  let(:storage) { Rubotty::Storage::Memory.new }

  subject(:board) do
    described_class.new(
      registry: registry, models: models, adapters: adapter_map,
      polls: writer, ballot: ballot, activity: activity, logger: Rubotty::Log.null,
      storage: storage
    )
  end

  def a_poll(**overrides)
    writer.open(
      **{
        community: community, room: room, kind: Rubotty::Polls::Poll::KIND_POLL,
        question: "Which map?", options: [{ label: "Dust II" }, { label: "Inferno" }]
      }.merge(overrides)
    )
  end

  def a_schedule(**overrides)
    writer.open(
      **{
        community: community, room: room, kind: Rubotty::Polls::Poll::KIND_SCHEDULE,
        question: "Raid night", detail: "Deep Rock Galactic", timezone: "Europe/Lisbon",
        multi_select: true, reply_options: true,
        options: [{ label: "Tue 7pm", starts_at: now + 86_400 },
                  { label: "Wed 7pm", starts_at: now + 172_800 }]
      }.merge(overrides)
    )
  end

  def vote(poll, position, handle, platform: "discord")
    ballot.record(poll: poll, option: writer.option_at(poll, position), identity: handle,
                  platform: platform, handle: handle)
  end

  def tg_text = tg.delivered.last.last.body.text
  def dc_text = dc.delivered.last.last.body.text

  # The room stores an empty zone list, which is how it says it wants the fixed
  # single-zone rendering rather than the shipped default expansion.
  def zones_off!
    Rubotty::ControlPlane::FeatureControls.new(models: models, registry: registry).set(
      community: registry.current.community("sample"), selector: "gaming", feature: "bridge",
      key: "timestamp_timezones", value: []
    )
  end

  describe "#announce_opened" do
    it "keeps a poll in its stored room when one channel also belongs to an older room" do
      old_room = models.room.where(community_id: community.id, room_key: "general").first
      shared = models.room_channel.where(room_id: old_room.id).get(:channel_id)
      models.room_channel.create(room_id: room.id, channel_id: shared, created_at: now)
      registry.reload
      poll = a_poll
      board.announce_opened(poll)
      expect(dc.delivered.map(&:first)).to eq(["dc-gaming"])
      expect(tg.delivered.map(&:first)).to contain_exactly("tg-gaming", "tg-general")
      tg.delivered.clear
      dc.delivered.clear
      board.announce_results(poll)
      expect(dc.delivered.map(&:first)).to eq(["dc-gaming"])
    end

    it "does not announce a poll for a suspended community" do
      community.update(status: "suspended", updated_at: now)
      registry.reload
      board.announce_opened(a_poll)
      expect(tg.delivered).to be_empty
      expect(dc.delivered).to be_empty
    end

    it "posts one card to every endpoint in the room" do
      board.announce_opened(a_poll)

      expect(tg.delivered.map(&:first)).to eq(["tg-gaming"])
      expect(dc.delivered.map(&:first)).to eq(["dc-gaming"])
    end

    it "lists each option behind its own keycap" do
      board.announce_opened(a_poll)

      expect(tg_text).to include("Poll: Which map?")
      expect(tg_text).to include("#{Rubotty::Polls::OptionEmoji::KEYCAPS[0]} Dust II")
      expect(tg_text).to include("#{Rubotty::Polls::OptionEmoji::KEYCAPS[1]} Inferno")
    end

    it "seeds one keycap reaction per option, leftmost first" do
      board.announce_opened(a_poll)

      expect(dc.synced.first[:desired]).to eq(Rubotty::Polls::OptionEmoji.for_count(2))
    end

    # Seeding them there put an emoji nobody could vote with on the card.
    it "seeds nothing where the card carries its own buttons instead" do
      board.announce_opened(a_poll)

      expect(tg.synced).to be_empty
    end

    it "records one tracked card copy per endpoint, so a reaction on it resolves back" do
      poll = a_poll
      board.announce_opened(poll)

      ref = Rubotty::Core::MessageRef.new("tg-gaming", "tg1")
      expect(board.poll_for_card(ref).id).to eq(poll.id)
      expect(board.holds_card?("tg-gaming", "tg1")).to be(true)
      expect(board.holds_card?("tg-gaming", "nothing")).to be(false)
    end

    it "remembers when the card was put in front of the room" do
      poll = a_poll
      board.announce_opened(poll)

      expect(writer.by_id(poll.id).last_posted_at).not_to be_nil
    end

    it "does not stop at one endpoint's delivery failure" do
      tg.fail_next!

      expect { board.announce_opened(a_poll) }.not_to raise_error
      expect(dc.delivered.size).to eq(1)
    end
  end

  describe "the copies in the shared message map" do
    # Without this a /delete on one copy reports not_found everywhere else.
    it "links every copy of one card as counterparts of each other" do
      board.announce_opened(a_poll)
      tg_ref = Rubotty::Core::MessageRef.new("tg-gaming", "tg1")
      dc_ref = Rubotty::Core::MessageRef.new("dc-gaming", "dc1")

      expect(storage.counterparts(tg_ref, endpoint_id: "dc-gaming").first).to eq(dc_ref)
      expect(storage.origins(dc_ref).find { |ref| ref.endpoint_id == "tg-gaming" }).to eq(tg_ref)
    end

    it "never raises without a storage service, the same posture every other injected dependency takes" do
      bare = described_class.new(
        registry: registry, models: models, adapters: adapter_map, polls: writer,
        ballot: ballot, activity: activity, logger: Rubotty::Log.null, storage: nil
      )

      expect { bare.announce_opened(a_poll) }.not_to raise_error
    end
  end

  describe "the card's timestamps" do
    it "renders a scheduling slot through EACH endpoint's own adapter" do
      zones_off!
      poll = a_schedule
      board.announce_opened(poll)
      slot = writer.option_at(poll, 1).starts_at

      expect(dc_text).to include("<t:#{slot.to_i}:F>")
      expect(tg_text).not_to include("<t:")
      expect(tg_text).to include(Rubotty::Util::EventTimestamps.full(slot, "Europe/Lisbon"))
    end

    it "uses the shipped default zones in a room that configured none" do
      poll = a_schedule
      board.announce_opened(poll)
      slot = writer.option_at(poll, 1).starts_at

      expect(tg_text).to include(
        Rubotty::Features::TimestampExpansion.render(
          slot, Rubotty::Features::TimestampExpansion.zones_for_config({}), Time.now
        )
      )
      expect(dc_text).to include("<t:#{slot.to_i}:F>")
    end

    it "renders the deadline the same way" do
      poll = a_poll
      board.announce_opened(poll)

      expect(dc_text).to include("Closes <t:#{poll.closes_at.to_i}:F>")
    end

    it "uses this room's configured zones on a platform with no markup of its own" do
      Rubotty::ControlPlane::FeatureControls.new(models: models, registry: registry).set(
        community: registry.current.community("sample"), selector: "gaming", feature: "bridge",
        key: "timestamp_timezones",
        value: [{ label: "Pacific", iana_timezone: "America/Los_Angeles" },
                { label: "Lisbon", iana_timezone: "Europe/Lisbon" }]
      )
      poll = a_schedule
      board.announce_opened(poll)
      slot = writer.option_at(poll, 1).starts_at

      expect(tg_text).to include(
        Rubotty::Features::TimestampExpansion.render(
          slot,
          [Rubotty::Features::TimestampExpansion::Zone.new(label: "Pacific", iana_timezone: "America/Los_Angeles"),
           Rubotty::Features::TimestampExpansion::Zone.new(label: "Lisbon", iana_timezone: "Europe/Lisbon")],
          Time.now
        )
      )
      expect(dc_text).to include("<t:#{slot.to_i}:F>")
    end
  end

  describe "the voter list on each option" do
    it "names up to three voters, in the cross-platform form for the reader's own platform" do
      poll = a_poll(multi_select: true)
      vote(poll, 1, "ada")
      vote(poll, 1, "bruno", platform: "telegram")
      board.announce_opened(poll)

      expect(dc_text).to include("Dust II @ada, @bruno@telegram")
      expect(tg_text).to include("Dust II @ada@discord, @bruno")
    end

    it "collapses to a count once a fourth voter arrives" do
      poll = a_poll(multi_select: true)
      %w[ada bruno cleo dita].each { |handle| vote(poll, 1, handle) }
      board.announce_opened(poll)

      expect(dc_text).to include("Dust II 4")
      expect(dc_text).not_to include("@ada")
    end

    it "leaves an option nobody backed with nothing after it" do
      board.announce_opened(a_poll)

      expect(tg_text).to include("#{Rubotty::Polls::OptionEmoji::KEYCAPS[1]} Inferno\n")
    end

    # A Telegram account has no handle until its owner sets one, and most never do.
    it "writes the name of a voter whose platform gave no handle, never their id" do
      poll = a_poll(multi_select: true)
      ballot.record(poll: poll, option: writer.option_at(poll, 1), identity: "5502187744",
                    platform: "telegram", handle: nil)
      models.observed_identity.create(
        community_id: community.id, adapter: "telegram", native_id: "5502187744",
        username: nil, display_name: "Pinniped Pete", first_seen_at: now, last_seen_at: now
      )
      board.announce_opened(poll)

      expect(tg_text).to include("Dust II Pinniped Pete")
      expect(tg_text).not_to include("5502187744")
    end
  end

  # The reason the whole button path exists: a keycap cannot be tapped on
  # Telegram, so the card carries its own ballot there.
  describe "the vote buttons" do
    def tg_buttons = tg.delivered.last.last.buttons

    it "offers one button per option where the platform has them" do
      board.announce_opened(a_poll)

      expect(tg_buttons.map(&:token)).to eq(%w[poll-option:1 poll-option:2])
      expect(tg_buttons.map(&:label)).to eq(
        ["#{Rubotty::Polls::OptionEmoji::KEYCAPS[0]} Dust II",
         "#{Rubotty::Polls::OptionEmoji::KEYCAPS[1]} Inferno"]
      )
    end

    it "offers none where the keycaps can be tapped instead" do
      board.announce_opened(a_poll)

      expect(dc.delivered.last.last.buttons).to be_empty
    end

    it "labels a scheduling slot the way that endpoint's own card does" do
      zones_off!
      poll = a_schedule
      board.announce_opened(poll)
      slot = writer.option_at(poll, 1).starts_at

      expect(tg_buttons.first.label).to include(Rubotty::Util::EventTimestamps.full(slot, "Europe/Lisbon"))
    end

    # An edit naming no keyboard takes the buttons off the message, so the
    # first vote would otherwise leave the room with nothing left to press.
    it "restates them on every refresh, since an edit would drop them" do
      poll = a_poll
      board.announce_opened(poll)
      vote(poll, 1, "ada")
      board.refresh(poll)

      expect(tg.edited.last.last.buttons.map(&:token)).to eq(%w[poll-option:1 poll-option:2])
      expect(dc.edited.last.last.buttons).to be_empty
    end

    it "keeps up with an option added after the card went out" do
      poll = a_schedule
      board.announce_opened(poll)
      writer.add_option(poll: poll, label: "Thu 7pm", starts_at: now + 259_200, suggested_by: "telegram:ada")
      board.refresh(poll)

      expect(tg.edited.last.last.buttons.map(&:token)).to eq(%w[poll-option:1 poll-option:2 poll-option:3])
    end
  end

  describe "the instructions" do
    it "tells a platform with buttons to tap, and one with keycaps to react" do
      board.announce_opened(a_poll)
      expect(tg_text).to include("Tap an option below to vote, or tap one again to take it back.")
      expect(dc_text).to include("React with a number to vote.")
    end

    it "says a scheduling session takes every option that works, whichever way it is answered" do
      board.announce_opened(a_schedule)

      expect(tg_text).to include("Tap every option that works for you, or tap one again to take it back.")
      expect(dc_text).to include("React with every option that works for you.")
    end

    it "mentions the reply fallback only where it is switched on" do
      board.announce_opened(a_poll(reply_votes: false, reply_options: false))
      expect(tg_text).not_to include("Reply")

      board.announce_opened(a_schedule)
      expect(tg_text).to include('Reply with a time of your own, like "tuesday 7pm", to add it.')
    end

    it "names the game a scheduling session is for" do
      board.announce_opened(a_schedule)

      expect(tg_text).to include("Game: Deep Rock Galactic")
    end

    it "says a reply can name the option's text, not only its number" do
      board.announce_opened(a_poll(reply_votes: true))

      expect(tg_text).to include("Or reply to this message with the number or its exact text.")
    end
  end

  describe "#refresh" do
    it "skips a tracked endpoint reassigned to another community" do
      poll = a_poll
      board.announce_opened(poll)
      other = models.community.create(slug: "other", name: "Other", created_at: now, updated_at: now)
      other_room = models.room.create(community_id: other.id, room_key: "gaming", created_at: now, updated_at: now)
      connection = models.platform_connection.create(
        community_id: other.id, adapter: "discord", account: "discord", external_id: "other-guild",
        created_at: now, updated_at: now
      )
      channel = models.channel.where(endpoint_key: "dc-gaming").first
      models.room_channel.where(channel_id: channel.id).delete
      channel.update(community_id: other.id, platform_connection_id: connection.id)
      models.room_channel.create(room_id: other_room.id, channel_id: channel.id, created_at: now)
      registry.reload

      board.refresh(poll)
      expect(tg.edited.map(&:first)).to eq(["tg-gaming"])
      expect(dc.edited).to be_empty
    end

    it "skips a tracked endpoint moved to another room in the same community" do
      poll = a_poll
      board.announce_opened(poll)
      other_room = models.room.where(community_id: community.id, room_key: "general").first
      channel = models.channel.where(endpoint_key: "dc-gaming").first
      models.room_channel.where(channel_id: channel.id).delete
      models.room_channel.create(room_id: other_room.id, channel_id: channel.id, created_at: now)
      registry.reload

      board.refresh(poll)
      expect(tg.edited.map(&:first)).to eq(["tg-gaming"])
      expect(dc.edited).to be_empty
    end

    it "leaves tracked cards untouched while the owning community is suspended" do
      poll = a_poll
      board.announce_opened(poll)
      community.update(status: "suspended")
      registry.reload

      board.refresh(poll)
      expect(tg.edited).to be_empty
      expect(dc.edited).to be_empty
    end

    it "edits every tracked copy in place rather than posting again" do
      poll = a_poll
      board.announce_opened(poll)
      vote(poll, 1, "ada")
      board.refresh(poll)

      expect(tg.delivered.size).to eq(1)
      expect(tg.edited.map { |row| row[1] }).to eq(["tg1"])
      expect(tg.edited.last.last.body.text).to include("Dust II @ada@discord")
    end
  end

  describe "#repost_if_buried" do
    def bury!(poll)
      key = Rubotty::Polls::RoomActivity.key(community.id, room.room_key)
      Rubotty::Polls::RoomActivity::VISIBLE_WINDOW.times { activity.record(key, at: now + 60) }
    end

    it "stays quiet while the card is still in the room's last ten messages" do
      poll = a_poll
      board.announce_opened(poll)

      expect(board.repost_if_buried(writer.by_id(poll.id))).to eq(0)
      expect(tg.delivered.size).to eq(1)
    end

    it "posts a fresh copy once the card has scrolled past them" do
      poll = a_poll
      board.announce_opened(poll)
      bury!(poll)

      expect(board.repost_if_buried(writer.by_id(poll.id))).to eq(2)
      expect(tg.delivered.size).to eq(2)
    end

    it "supersedes the copy it replaced, so a vote lands on the one people can see" do
      poll = a_poll
      board.announce_opened(poll)
      bury!(poll)
      board.repost_if_buried(writer.by_id(poll.id))

      expect(board.poll_for_card(Rubotty::Core::MessageRef.new("tg-gaming", "tg1"))).to be_nil
      expect(board.poll_for_card(Rubotty::Core::MessageRef.new("tg-gaming", "tg2")).id).to eq(poll.id)
    end

    it "leaves a closed poll alone" do
      poll = a_poll
      board.announce_opened(poll)
      bury!(poll)
      writer.close(poll: poll)

      expect(board.repost_if_buried(writer.by_id(poll.id))).to eq(0)
    end
  end

  describe "#announce_results" do
    it "posts a separate message naming everybody, however many there are" do
      poll = a_poll(multi_select: true)
      %w[ada bruno cleo dita].each { |handle| vote(poll, 1, handle) }
      board.announce_opened(poll)
      tg.delivered.clear
      board.announce_results(poll)

      text = tg.delivered.last.last.body.text
      expect(text).to start_with("Poll closed: Which map?")
      expect(text).to include("Dust II (4): @ada@discord, @bruno@discord, @cleo@discord, @dita@discord")
      expect(text).to include("Inferno (0)")
    end

    it "spells a scheduling slot out in the session's own zone" do
      poll = a_schedule
      board.announce_results(poll)

      slot = writer.option_at(poll, 1).starts_at
      expect(dc.delivered.last.last.body.text)
        .to include(Rubotty::Util::EventTimestamps.full(slot, "Europe/Lisbon"))
    end
  end
end
