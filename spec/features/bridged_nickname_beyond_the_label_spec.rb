# frozen_string_literal: true

require "spec_helper"

# Everywhere else a relayed copy names somebody: the quote over a reply, the
# starter of a thread, and the lines the bridge posts about a reaction, an edit
# or a delete. Each should call a person what their own messages call them.
RSpec.describe "a bridged nickname beyond the sender label" do
  let(:tg) { endpoint("tg", adapter: :telegram) }
  let(:dc) { endpoint("dc", adapter: :discord) }
  let(:storage) { Rubotty::Storage::Memory.new }
  let(:adapter) { Fakes::RecordingAdapter.new(own_id: "bot-1") }

  # A different name chosen for each platform, so a spec can tell which one a
  # target picked up.
  let(:owner) do
    Rubotty::Core::Person.new(
      name: "sample_owner",
      identities: { telegram: ["111"], discord: ["900"] },
      handles: { telegram: ["sample_owner"], discord: ["owner_handle"] },
      nicknames: { discord: "River", telegram: "Sparks" }
    )
  end

  let(:plain) do
    Rubotty::Core::Person.new(name: "bob", identities: { telegram: ["222"] }, handles: { telegram: ["bob"] })
  end

  # No separate profile name, so an ordinary label reads "handle@platform".
  let(:sparky_on_telegram) { author(native_id: "111", username: "sample_owner", first_name: nil) }
  let(:sparky_on_discord) { author(native_id: "900", username: "owner_handle", first_name: nil) }
  let(:bob) { author(native_id: "222", username: "bob", first_name: nil) }

  def build_bridge(people: Rubotty::Core::Directory.new([owner, plain]), the_topology: topology(room("r", tg, dc)),
                   the_adapter: adapter)
    Rubotty::Features::Bridge.new(
      topology: the_topology, adapters: Hash.new(the_adapter), storage: storage,
      loop_guard: Rubotty::Core::LoopGuard.new(storage: storage), logger: Rubotty::Log.null,
      people: people, ttl: 3600
    )
  end

  # A fresh native id per call, or the loop guard drops a second relay.
  def next_id = "m#{@sent = (@sent || 0) + 1}"

  def preview_by(parent_author)
    Rubotty::Core::ReplyPreview.new(author: parent_author, body: Rubotty::Core::RichText.plain("the original"))
  end

  describe "the quote over a reply" do
    def quote_on(target, parent_author, origin: tg, replier: bob)
      build_bridge.call(
        Rubotty::Features::Context.new(
          message: message(origin, text: "agreed", native_id: next_id, author: replier,
                                   reply_to: ref(origin.id, "500"), reply_preview: preview_by(parent_author))
        )
      )
      adapter.delivered_to(target.id).last.reply_preview.label
    end

    it "names the quoted author the way their own messages read on that platform" do
      build_bridge.call(Rubotty::Features::Context.new(message: message(tg, native_id: next_id,
                                                                            author: sparky_on_telegram)))
      own_label = adapter.delivered_to("dc").last.sender_label.to_s

      expect(quote_on(dc, sparky_on_telegram)).to eq(own_label)
      expect(own_label).to eq("River [sample_owner@fake]")
    end

    it "uses the nickname chosen for the platform the quote lands on" do
      expect(quote_on(tg, sparky_on_discord, origin: dc, replier: author(native_id: "404", username: "x")))
        .to eq("Sparks [owner_handle@fake]")
    end

    it "keeps the ordinary name for an author who chose no nickname" do
      expect(quote_on(dc, bob, replier: sparky_on_telegram)).to eq("bob")
    end

    it "keeps the ordinary name for an author the directory does not know" do
      stranger = author(native_id: "404", username: "stranger", first_name: nil)

      expect(quote_on(dc, stranger)).to eq("stranger")
    end
  end

  describe "the starter named in a thread notice" do
    def notice_for(thread)
      build_bridge.call(
        Rubotty::Features::Context.new(
          message: message(dc, text: "Thread test.", native_id: next_id, author: bob, thread: thread),
          config: { thread_reply_notices: true }
        )
      )
      adapter.delivered_to("tg").last.thread_notice
    end

    it "leads with the nickname the starter chose for the target, the handle following" do
      started = Rubotty::Core::ThreadRef.new(native_id: "77", name: "Test.", creator: "owner_handle",
                                             creator_native_id: "900")

      expect(notice_for(started)).to eq('(Reply inside thread "Test." created by Sparks [owner_handle@fake].)')
    end

    it "keeps the bare handle for a starter who chose no nickname" do
      started = Rubotty::Core::ThreadRef.new(native_id: "77", name: "Test.", creator: "someone",
                                             creator_native_id: "333")

      expect(notice_for(started)).to eq('(Reply inside thread "Test." created by someone@fake.)')
    end
  end

  describe "the line the bridge posts about a reaction" do
    let(:thumbs) { Rubotty::Core::Reaction.new(emoji: "👍") }
    let(:party) { Rubotty::Core::Reaction.new(emoji: "🎉") }

    before { storage.record(source: ref("tg", "5"), destination: ref("dc", "copy-5"), room_id: "r") }

    def react(bridge, kind, reaction)
      bridge.call(
        Rubotty::Features::Context.new(
          message: Rubotty::Core::Message.new(kind: kind, ref: ref("tg", "5"), origin: tg,
                                              author: sparky_on_telegram, reaction: reaction),
          config: { reaction_notices: :notice }
        )
      )
    end

    it "names the person who reacted by their nickname" do
      react(build_bridge, :reaction_add, thumbs)

      expect(adapter.delivered_to("dc").map { |msg| msg.body.text }).to eq(["River [sample_owner@fake] reacted 👍"])
    end

    it "keeps the nickname when the line is narrowed after one emoji comes off" do
      bridge = build_bridge
      react(bridge, :reaction_add, thumbs)
      react(bridge, :reaction_add, party)
      react(bridge, :reaction_remove, thumbs)

      expect(adapter.edited.map { |(_, _, msg)| msg.body.text }).to eq(["River [sample_owner@fake] reacted 🎉"])
    end
  end

  describe "the line the bridge posts about an edit or a delete it cannot carry" do
    let(:stuck_adapter) do
      Class.new(Fakes::RecordingAdapter) do
        def capabilities
          @capabilities ||= Rubotty::Adapters::Capabilities.new(edits: false, deletes: false, replies: true)
        end
      end.new(own_id: "bot-1")
    end

    before { storage.record(source: ref("tg", "5"), destination: ref("dc", "copy-5"), room_id: "r") }

    def change(kind, config)
      build_bridge(the_adapter: stuck_adapter).call(
        Rubotty::Features::Context.new(
          message: Rubotty::Core::Message.new(kind: kind, ref: ref("tg", "5"), origin: tg, author: sparky_on_telegram,
                                              body: Rubotty::Core::RichText.plain("fixed")),
          config: config
        )
      )
      stuck_adapter.delivered_to("dc").last.body.text
    end

    it "names who edited by their nickname" do
      expect(change(:edit, { edit_notices: true })).to eq("River [sample_owner@fake] edited their message")
    end

    it "names who deleted by their nickname" do
      expect(change(:delete, { delete_notices: true })).to eq("River [sample_owner@fake] deleted their message")
    end
  end

  # These already went through the sender label; held here so they stay that way.
  describe "copies that carry the sender label itself" do
    it "names the person in a membership line by their nickname" do
      build_bridge.call(
        Rubotty::Features::Context.new(message: message(tg, kind: :join, text: "", native_id: next_id,
                                                            author: sparky_on_telegram))
      )

      expect(adapter.delivered_to("dc").last.sender_label.to_s).to eq("River [sample_owner@fake]")
    end

    it "keeps the nickname on a copy an edit rewrites in place" do
      storage.record(source: ref("tg", "5"), destination: ref("dc", "copy-5"), room_id: "r")
      build_bridge.call(
        Rubotty::Features::Context.new(
          message: Rubotty::Core::Message.new(kind: :edit, ref: ref("tg", "5"), origin: tg, author: sparky_on_telegram,
                                              body: Rubotty::Core::RichText.plain("fixed"))
        )
      )

      expect(adapter.edited.last.last.sender_label.to_s).to eq("River [sample_owner@fake]")
    end
  end

  # A nickname belongs to one community's person. Asking the deployment-wide
  # union instead would show it in a community that has never heard of them.
  describe "another community's nickname" do
    def community_of(slug, id:, people:)
      rooms = [room("#{slug}-room", endpoint("#{slug}-tg", adapter: :telegram),
                    endpoint("#{slug}-dc", adapter: :discord))]
      channels = rooms.flat_map(&:endpoints).map do |ep|
        Rubotty::ControlPlane::Snapshot::Channel.new(endpoint: ep, community_id: id, route_key: ep.id)
      end
      Rubotty::ControlPlane::Snapshot::Community.new(
        id: id, slug: slug, name: slug, status: "active", settings: {},
        topology: Rubotty::Core::Topology.new(rooms), channels: channels,
        operators: Rubotty::Core::Moderation::Directory.new([]),
        people: Rubotty::Core::Directory.new(people)
      )
    end

    # Known only in community one, so the union answers for this account alone.
    let(:snapshot) do
      Rubotty::ControlPlane::Snapshot.new(
        communities: [community_of("one", id: 1, people: [owner]), community_of("two", id: 2, people: [])]
      )
    end

    let(:bridge) { build_bridge(people: snapshot.people, the_topology: snapshot.topology) }

    def in_two(message)
      bridge.call(Rubotty::Features::Context.new(community: snapshot.community("two"), message: message,
                                                 config: { reaction_notices: :notice }))
      adapter.delivered_to("two-dc").last
    end

    it "is not shown on a quote relayed in a community that does not know the author" do
      expect(snapshot.people.by_identity(:telegram, "111")).to eq(owner)

      origin = snapshot.topology.endpoint("two-tg")
      copy = in_two(message(origin, text: "agreed", native_id: next_id, author: bob,
                                    reply_to: ref("two-tg", "500"), reply_preview: preview_by(sparky_on_telegram)))

      expect(copy.reply_preview.label).to eq("sample_owner")
    end

    it "is not shown on a reaction line posted in a community that does not know the reactor" do
      origin = snapshot.topology.endpoint("two-tg")
      line = in_two(Rubotty::Core::Message.new(kind: :reaction_add, ref: ref("two-tg", "5"), origin: origin,
                                               author: sparky_on_telegram,
                                               reaction: Rubotty::Core::Reaction.new(emoji: "👍")))

      expect(line.body.text).to eq("sample_owner@fake reacted 👍")
    end
  end
end
