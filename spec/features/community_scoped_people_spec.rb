# frozen_string_literal: true

require "spec_helper"

# One platform account can have a row in two communities. The merged directory used to keep
# only the first person holding a platform id, so whichever community happened to sort
# first owned that identity everywhere: its row answered a mention, a moderation target and
# a script's ping in the other community's place.
RSpec.describe "resolving a person in the community the message arrived in" do
  let(:storage) { Rubotty::Storage::Memory.new }
  let(:adapter) { Fakes::ReactingAdapter.new(own_id: "bot-1") }

  # Alex has an account on both platforms in both communities, and the two
  # communities know different Discord accounts for the telegram id 55.
  let(:alex_in_one) do
    Rubotty::Core::Person.new(
      name: "Alex of one", identities: { telegram: ["55"], discord: ["111"] },
      handles: { telegram: ["alex"], discord: ["alex"] }
    )
  end
  let(:alex_in_two) do
    Rubotty::Core::Person.new(
      name: "Alex of two", identities: { telegram: ["55"], discord: ["222"] },
      handles: { telegram: ["alex"], discord: ["alex"] }
    )
  end
  # Known ONLY in community one. Nothing in community two should be able to
  # observe that this handle exists at all.
  let(:private_to_one) do
    Rubotty::Core::Person.new(
      name: "Private", identities: { telegram: ["77"], discord: ["333"] },
      handles: { telegram: ["private"], discord: ["private"] }
    )
  end
  let(:boss) do
    Rubotty::Core::Moderation::Operator.new(name: "Boss", identities: { telegram: ["1"] })
  end

  def community_of(slug, id:, people:, operators: [])
    rooms = [room("#{slug}-room",
                  endpoint("#{slug}-tg", adapter: :telegram),
                  endpoint("#{slug}-dc", adapter: :discord))]
    channels = rooms.flat_map(&:endpoints).map do |ep|
      Rubotty::ControlPlane::Snapshot::Channel.new(endpoint: ep, community_id: id, route_key: ep.id)
    end
    Rubotty::ControlPlane::Snapshot::Community.new(
      id: id, slug: slug, name: slug, status: "active", settings: {},
      topology: Rubotty::Core::Topology.new(rooms), channels: channels,
      operators: Rubotty::Core::Moderation::Directory.new(operators),
      people: Rubotty::Core::Directory.new(people)
    )
  end

  # Community one is built first and holds the LOWER id, so it is exactly the one
  # that used to win every contested lookup.
  let(:snapshot) do
    Rubotty::ControlPlane::Snapshot.new(
      communities: [
        community_of("one", id: 1, people: [alex_in_one, private_to_one], operators: [boss]),
        community_of("two", id: 2, people: [alex_in_two], operators: [boss])
      ]
    )
  end

  def delivered_to(endpoint_id)
    adapter.delivered.reverse.find { |id, _| id == endpoint_id }&.last
  end

  describe "the bridge's mention rewrite, which turns a handle into a native ping" do
    def bridge
      Rubotty::Features::Bridge.new(
        topology: snapshot.topology, adapters: Hash.new(adapter), storage: storage,
        loop_guard: Rubotty::Core::LoopGuard.new(storage: storage), logger: Rubotty::Log.null,
        # The deployment-wide view, exactly as Runtime#routing_people supplies it.
        people: snapshot.people
      )
    end

    def relay(slug, body)
      origin = snapshot.topology.endpoint("#{slug}-tg")
      bridge.call(
        Rubotty::Features::Context.new(
          community: snapshot.community(slug),
          message: message(origin, native_id: "m-1", body: body,
                           author: author(native_id: "55", username: "alex"))
        )
      )
    end

    it "pings the account its own community knows, not the other community's" do
      relay("two", rich("hi Alex", span(:mention, 3, 7, tg_user_id: "55")))

      expect(delivered_to("two-dc").body.spans.first.attributes[:discord_id_for_target]).to eq("222")
    end

    it "still pings the right account for the community that sorts first" do
      relay("one", rich("hi Alex", span(:mention, 3, 7, tg_user_id: "55")))

      expect(delivered_to("one-dc").body.spans.first.attributes[:discord_id_for_target]).to eq("111")
    end

    # Resolving here would both ping a stranger and confirm, to a room that
    # cannot see community one, that the handle is somebody somewhere.
    it "leaves a handle known only in another community as plain text" do
      relay("two", rich("hi @private", span(:mention, 3, 11, username: "private")))

      expect(delivered_to("two-dc").body.spans.first.attributes).not_to have_key(:discord_id_for_target)
    end
  end

  describe "a moderation verb crossing to the other platform" do
    def moderation
      Rubotty::Features::Moderation.new(
        topology: snapshot.topology, adapters: Hash.new(adapter), storage: storage,
        logger: Rubotty::Log.null, people: snapshot.people,
        commands: Rubotty::Core::Commands.new(actions: %i[ban], logger: Rubotty::Log.null)
      )
    end

    # A /ban issued as a reply to Alex, which is how a user action names its
    # target: the replied author's id, in the origin platform's id space.
    def ban_in(slug)
      origin = snapshot.topology.endpoint("#{slug}-tg")
      preview = Rubotty::Core::ReplyPreview.new(
        author: author(native_id: "55", username: "alex"),
        body: Rubotty::Core::RichText.plain("something rude")
      )
      moderation.call(
        Rubotty::Features::Context.new(
          community: snapshot.community(slug),
          message: message(origin, text: "/ban", native_id: "m-2",
                           author: author(native_id: "1"),
                           reply_to: ref("#{slug}-tg", "900"), reply_preview: preview)
        )
      )
      adapter.moderations.find { |m| m[:endpoint_id] == "#{slug}-dc" }
    end

    it "acts on the account its own community knows" do
      expect(ban_in("two")[:target_user_id]).to eq("222")
    end

    it "still acts on the right account for the community that sorts first" do
      expect(ban_in("one")[:target_user_id]).to eq("111")
    end
  end

  describe "the ping a script asks for" do
    def annotate(slug, body)
      annotator = Rubotty::Core::Router.allocate.send(
        :script_mention_annotator, people: snapshot.people, identity_directory: nil
      )
      annotator.call(body, snapshot.community(slug))
    end

    it "resolves the handle in the script's own community" do
      annotated = annotate("two", rich("hi @alex", span(:mention, 3, 8, username: "alex")))

      expect(annotated.spans.first.attributes[:discord_id_for_target]).to eq("222")
    end

    it "will not reach a handle that only exists in another community" do
      annotated = annotate("two", rich("hi @private", span(:mention, 3, 11, username: "private")))

      expect(annotated.spans.first.attributes).not_to have_key(:discord_id_for_target)
    end
  end

  describe "the deployment-wide view the snapshot still publishes" do
    it "answers for an account only one community claims" do
      expect(snapshot.people.by_identity(:telegram, "77")&.name).to eq("Private")
    end

    it "refuses an account two communities both claim, rather than picking one" do
      expect(snapshot.people.by_identity(:telegram, "55")).to be_nil
      expect(snapshot.people.by_handle(:telegram, "alex")).to be_nil
      expect(snapshot.people.resolve_mention(tg_user_id: "55")).to be_nil
    end

    it "still counts everybody, since the union is what a report wants" do
      expect(snapshot.people.size).to eq(3)
    end
  end

  describe Rubotty::Core::CommunityPeople do
    subject(:people) do
      described_class.new(
        1 => Rubotty::Core::Directory.new([alex_in_one]),
        2 => Rubotty::Core::Directory.new([alex_in_two])
      )
    end

    it "takes a community object or its bare id" do
      expect(people.for_community(snapshot.community("two")).by_identity(:telegram, "55")).to eq(alex_in_two)
      expect(people.for_community(2).by_identity(:telegram, "55")).to eq(alex_in_two)
    end

    # Issue #1784, and this assertion used to run the other way, asserting the
    # fallback to the merged view as intended. That is the fail-open half of
    # the bug this class exists to close, since a caller that lost its
    # community then resolved against every tenant instead of none.
    it "resolves nobody when no community was resolved, rather than everybody" do
      empty = people.for_community(nil)

      expect(empty.people).to be_empty
      expect(empty.by_identity(:telegram, "55")).to be_nil
      expect(empty.by_handle(:telegram, "alex")).to be_nil
    end

    it "resolves nobody for an id that names no community either" do
      expect(people.for_community(99).by_identity(:telegram, "55")).to be_nil
    end
  end

  describe Rubotty::Core::Directory do
    it "is its own community scope, since config describes one deployment" do
      directory = described_class.new([alex_in_one])

      expect(directory.for_community("anything")).to equal(directory)
    end
  end
end
