# frozen_string_literal: true

require "spec_helper"

# A translated copy should name its author the way a relayed copy does: by the
# nickname they chose for the platform the copy lands on, looked up among the
# people of the community the message was said in.
RSpec.describe "a bridged nickname on a translated copy" do
  include Builders

  # Keeps jobs in a list so a spec can drain them with nothing sleeping.
  class NicknameTranslationDurable
    Job = Struct.new(:kind, :run_at, :payload, :community, keyword_init: true)

    def initialize
      @jobs = []
      @handlers = {}
    end

    def register(kind, max_age: nil, priority: nil, &block)
      @handlers[kind.to_s] = block
      self
    end

    def schedule(kind:, run_at:, payload: {}, community: nil, recurrence: nil, discard_payload: false)
      @jobs << Job.new(kind: kind.to_s, run_at: run_at, payload: payload, community: community)
      @jobs.length
    end

    def drain
      @handlers[@jobs.first.kind].call(@jobs.shift) until @jobs.empty?
    end
  end

  class NicknameTranslationClient
    def translate(text, source:, target:) = "[#{target}] #{text}"
  end

  # A different name chosen for each platform, so a spec can tell which one a
  # copy picked up.
  let(:owner) do
    Rubotty::Core::Person.new(
      name: "sample_owner",
      identities: { telegram: ["111"], discord: ["900"] },
      handles: { telegram: ["sample_owner"], discord: ["owner_handle"] },
      nicknames: { discord: "River", telegram: "Sparks" }
    )
  end

  let(:bob) do
    Rubotty::Core::Person.new(name: "bob", identities: { telegram: ["222"] }, nicknames: { discord: "Bobby" })
  end

  # No separate profile name, so an ordinary label reads "handle@platform".
  let(:sparky_on_telegram) { author(native_id: "111", username: "sample_owner", first_name: nil) }

  # An English room on Telegram, grouped with a Portuguese room bridged across
  # Telegram and Discord.
  def community_of(slug, id:, people:)
    source = endpoint("#{slug}-en", adapter: :telegram, community_id: id)
    peer_tg = endpoint("#{slug}-pt-tg", adapter: :telegram, community_id: id)
    peer_dc = endpoint("#{slug}-pt-dc", adapter: :discord, community_id: id)
    rooms = [room("en", source, community_id: id), room("pt", peer_tg, peer_dc, community_id: id)]
    Rubotty::ControlPlane::Snapshot::Community.new(
      id: id, slug: slug, name: slug, status: "active", settings: {},
      topology: Rubotty::Core::Topology.new(rooms),
      channels: rooms.flat_map(&:endpoints).map do |ep|
        Rubotty::ControlPlane::Snapshot::Channel.new(endpoint: ep, community_id: id, route_key: ep.id)
      end,
      operators: Rubotty::Core::Moderation::Directory.new, people: Rubotty::Core::Directory.new(people),
      feature_settings: { "en" => "en", "pt" => "pt" }.map do |room_key, language|
        Rubotty::ControlPlane::Snapshot::FeatureSetting.new(
          room_key: room_key, feature: "translation", enabled: true,
          config: { "language" => language, "group" => "welcome" }
        )
      end
    )
  end

  let(:snapshot) do
    Rubotty::ControlPlane::Snapshot.new(
      communities: [community_of("one", id: 1, people: [owner, bob]),
                    community_of("two", id: 2, people: people_in_two)]
    )
  end

  let(:people_in_two) { [] }
  let(:registry) { Struct.new(:current).new(snapshot) }
  let(:adapter) { Fakes::RecordingAdapter.new(own_id: "bot-1") }
  let(:adapters) { Hash.new(adapter) }
  let(:storage) { Rubotty::Storage::Memory.new }
  let(:loop_guard) { Rubotty::Core::LoopGuard.new(storage: storage) }
  let(:durable) { NicknameTranslationDurable.new }

  let(:relay) do
    Rubotty::Translation::Relay.new(
      scheduler: durable, storage: storage, topology: snapshot.topology, adapters: adapters,
      loop_guard: loop_guard, registry: registry, people: snapshot.people,
      logger: Rubotty::Log.null, client: NicknameTranslationClient.new
    )
  end

  let(:route) do
    Rubotty::Core::Router.new(
      topology: snapshot.topology, adapters: adapters, storage: storage, loop_guard: loop_guard,
      logger: Rubotty::Log.null, registry: registry, translation_relay: relay, people: snapshot.people
    )
  end

  def say_in(slug, speaker, native_id: "m1")
    route.handle(message(snapshot.topology.endpoint("#{slug}-en"), text: "hello", native_id: native_id,
                                                                    author: speaker))
    durable.drain
  end

  def label_on(endpoint_id) = adapter.delivered_to(endpoint_id).last.sender_label.to_s

  it "leads with the nickname chosen for each platform the copy lands on" do
    say_in("one", sparky_on_telegram)

    expect(label_on("one-pt-dc")).to eq("River [sample_owner@fake]")
    expect(label_on("one-pt-tg")).to eq("Sparks [sample_owner@fake]")
  end

  it "keeps the ordinary label for an author the community does not know" do
    say_in("one", author(native_id: "404", username: "stranger", first_name: nil))

    expect(label_on("one-pt-dc")).to eq("stranger@fake")
  end

  it "keeps the ordinary label on a platform the author chose no nickname for" do
    say_in("one", author(native_id: "222", username: "bob", first_name: nil))

    expect(label_on("one-pt-dc")).to eq("Bobby [bob@fake]")
    expect(label_on("one-pt-tg")).to eq("bob@fake")
  end

  # A nickname belongs to one community's person, so the same account speaking
  # in another community must not carry it there.
  describe "another community's nickname" do
    it "is not shown for the same account in a community that does not know them" do
      expect(snapshot.people.by_identity(:telegram, "111")).to eq(owner)

      say_in("two", sparky_on_telegram)

      expect(label_on("two-pt-dc")).to eq("sample_owner@fake")
      expect(label_on("two-pt-tg")).to eq("sample_owner@fake")
    end

    context "when that community holds its own row for the account" do
      let(:people_in_two) do
        [Rubotty::Core::Person.new(name: "sample_owner", identities: { telegram: ["111"] },
                                   nicknames: { discord: "Alex from two" })]
      end

      it "shows the nickname chosen there instead" do
        say_in("two", sparky_on_telegram)

        expect(label_on("two-pt-dc")).to eq("Alex from two [sample_owner@fake]")
        expect(label_on("two-pt-tg")).to eq("sample_owner@fake")
      end
    end
  end

  it "still delivers a job queued before the author was stored, under the label it carries" do
    peer_room = snapshot.topology.rooms.find { |candidate| candidate.include?("one-pt-dc") }
    old_shape = {
      "action" => "new", "source_endpoint_id" => "one-en", "source_native_id" => "m9",
      "source_language" => "en", "target_room_unique_id" => peer_room.unique_id,
      "target_language" => "pt", "text" => "hello", "spans" => [], "attachments" => [],
      "sender_label" => { "username" => "sample_owner", "platform" => "fake" }
    }
    relay
    durable.schedule(kind: "translation", run_at: Time.now, payload: old_shape, community: "one")
    durable.drain

    expect(label_on("one-pt-dc")).to eq("sample_owner@fake")
    expect(adapter.delivered_to("one-pt-dc").last.body.text).to include("[pt] hello")
  end
end
