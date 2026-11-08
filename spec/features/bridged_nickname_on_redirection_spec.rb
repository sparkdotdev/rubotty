# frozen_string_literal: true

require "spec_helper"

# A moved message should name its author the way a relayed copy does: by the
# nickname they chose for the platform the repost lands on, looked up among the
# people of the community doing the move.
RSpec.describe "a bridged nickname on a redirected message", :control_plane do
  include Builders

  # Keeps jobs in a list so a spec can drive the move a tick at a time.
  class NicknameRedirectionDurable
    Job = Struct.new(:kind, :run_at, :payload, keyword_init: true)

    def initialize
      @jobs = []
    end

    attr_reader :jobs

    def register(kind, max_age: nil, priority: nil) = self

    def schedule(kind:, run_at:, payload: {}, community: nil, recurrence: nil)
      @jobs << Job.new(kind: kind.to_s, run_at: run_at, payload: payload)
      @jobs.length
    end

    def cancel(kind:, community: nil, &predicate)
      @jobs.reject! { |job| job.kind == kind.to_s && predicate.call(job.payload) }
    end
  end

  # A different name chosen for each platform, so a spec can tell which one a
  # repost picked up.
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
  let(:moderator) { author(native_id: "op1", username: "moderator", first_name: nil) }

  let(:operator) do
    Rubotty::Core::Moderation::Operator.new(
      name: "moderator", identities: { telegram: ["op1"] }, actions: [:redirect], rooms: :all
    )
  end

  let(:db) { migrated_db }
  let(:models) { build_models(db) }

  def seed_community(slug)
    models.community.create(slug: slug, name: slug, status: "active", settings: "{}",
                            created_at: Time.now, updated_at: Time.now).id
  end

  # A Telegram room the run was said in, and the room it belongs in, bridged
  # across Telegram and Discord.
  def community_of(slug, people:)
    id = seed_community(slug)
    source = endpoint("#{slug}-src", adapter: :telegram, community_id: id)
    right_tg = endpoint("#{slug}-right-tg", adapter: :telegram, community_id: id)
    right_dc = endpoint("#{slug}-right-dc", adapter: :discord, community_id: id)
    rooms = [room("wrong", source, community_id: id), room("right", right_tg, right_dc, community_id: id)]
    Rubotty::ControlPlane::Snapshot::Community.new(
      id: id, slug: slug, name: slug, status: "active", settings: {},
      topology: Rubotty::Core::Topology.new(rooms),
      channels: rooms.flat_map(&:endpoints).map do |ep|
        Rubotty::ControlPlane::Snapshot::Channel.new(endpoint: ep, community_id: id, route_key: ep.id)
      end,
      operators: Rubotty::Core::Moderation::Directory.new([operator]),
      people: Rubotty::Core::Directory.new(people)
    )
  end

  let(:people_in_two) { [] }

  let(:snapshot) do
    Rubotty::ControlPlane::Snapshot.new(
      communities: [community_of("one", people: [owner, bob]), community_of("two", people: people_in_two)]
    )
  end

  let(:adapter) { Fakes::RecordingAdapter.new }
  let(:durable) { NicknameRedirectionDurable.new }
  let(:redirections) { Rubotty::ControlPlane::Redirections.new(models: models) }

  # Built by the router, so the people it hands the feature are the ones under test.
  let(:feature) do
    storage = Rubotty::Storage::Memory.new
    Rubotty::Core::Router.new(
      topology: snapshot.topology, adapters: Hash.new(adapter), storage: storage,
      loop_guard: Rubotty::Core::LoopGuard.new(storage: storage), logger: Rubotty::Log.null,
      registry: Struct.new(:current).new(snapshot), people: snapshot.people,
      redirections: redirections, durable_scheduler: durable
    ).redirection
  end

  def say_in(slug, text, native_id:, speaker:, reply_to: nil)
    source = snapshot.topology.endpoint("#{slug}-src")
    feature.call(
      Rubotty::Features::Context.new(
        message: message(source, text: text, native_id: native_id, author: speaker,
                                 reply_to: reply_to && ref(source.id, reply_to)),
        community: snapshot.community(slug), config: {}, logger: Rubotty::Log.null
      )
    )
  end

  # Says one message in the wrong room, moves it, and drains the move.
  def move_in(slug, speaker)
    say_in(slug, "hello", native_id: "10", speaker: speaker)
    say_in(slug, "/redirect right", native_id: "90", speaker: moderator, reply_to: "10")
    say_in(slug, "/end", native_id: "91", speaker: moderator, reply_to: "10")
    until durable.jobs.empty?
      job = durable.jobs.shift
      feature.step(id: job.payload[:redirection_id], community_id: job.payload[:community_id])
    end
  end

  def label_on(endpoint_id) = adapter.delivered_to(endpoint_id).find(&:chat?).sender_label.to_s

  it "leads with the nickname chosen for each platform the repost lands on" do
    move_in("one", sparky_on_telegram)

    expect(label_on("one-right-dc")).to eq("River [sample_owner@telegram]")
    expect(label_on("one-right-tg")).to eq("Sparks [sample_owner@telegram]")
  end

  it "keeps the ordinary label for an author the community does not know" do
    move_in("one", author(native_id: "404", username: "stranger", first_name: nil))

    expect(label_on("one-right-dc")).to eq("stranger@telegram")
  end

  it "keeps the ordinary label on a platform the author chose no nickname for" do
    move_in("one", author(native_id: "222", username: "bob", first_name: nil))

    expect(label_on("one-right-dc")).to eq("Bobby [bob@telegram]")
    expect(label_on("one-right-tg")).to eq("bob@telegram")
  end

  # A nickname belongs to one community's person, so the same account moved in
  # another community must not carry it there.
  describe "another community's nickname" do
    it "is not shown for the same account in a community that does not know them" do
      expect(snapshot.people.by_identity(:telegram, "111")).to eq(owner)

      move_in("two", sparky_on_telegram)

      expect(label_on("two-right-dc")).to eq("sample_owner@telegram")
      expect(label_on("two-right-tg")).to eq("sample_owner@telegram")
    end

    context "when that community holds its own row for the account" do
      let(:people_in_two) do
        [Rubotty::Core::Person.new(name: "sample_owner", identities: { telegram: ["111"] },
                                   nicknames: { discord: "Alex from two" })]
      end

      it "shows the nickname chosen there instead" do
        move_in("two", sparky_on_telegram)

        expect(label_on("two-right-dc")).to eq("Alex from two [sample_owner@telegram]")
        expect(label_on("two-right-tg")).to eq("sample_owner@telegram")
      end
    end
  end

  it "still reposts a move planned before the author's id was kept, under the label it carries" do
    community_id = snapshot.community("one").id
    row = redirections.open(
      community_id: community_id, source_endpoint_id: "one-src", target_room_id: "right", operator: "moderator",
      plan: [{ native_id: "10", endpoint_id: "one-src", handle: "sample_owner", name: nil,
               fallback: "sample_owner", platform: "telegram", text: "hello", spans: [], attachments: [] }]
    )
    feature.step(id: row.id, community_id: community_id)

    expect(label_on("one-right-dc")).to eq("sample_owner@telegram")
  end
end
