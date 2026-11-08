# frozen_string_literal: true

require "spec_helper"

# Command authorisation resolves the issuer in the community the message belongs
# to, never in the deployment-wide merged directory. A room_key is only unique
# within one community, so a grant read out of the merged directory carries an
# operator of one community into another community's identically named room.
RSpec.describe "moderation command authorisation is community scoped (#389)" do
  let(:tg_alpha) { endpoint("tg-alpha") }
  let(:tg_beta) { endpoint("tg-beta") }
  let(:adapter) { Fakes::ReactingAdapter.new(own_id: "bot") }

  # One person, one platform account, an operator of Alpha only.
  let(:alpha_operator) do
    Rubotty::Core::Moderation::Operator.new(
      name: "Alex", identities: { fake: ["55"] }, rooms: ["general"]
    )
  end

  let(:alpha_directory) { Rubotty::Core::Moderation::Directory.new([alpha_operator]) }
  let(:beta_directory) { Rubotty::Core::Moderation::Directory.new([]) }

  # What the Snapshot hands the runtime: every community's operators in one
  # Directory, which is what the parser used to resolve against.
  let(:merged_directory) { Rubotty::Core::Moderation::Directory.new([alpha_operator]) }

  let(:commands) do
    Rubotty::Core::Commands.new(actions: Rubotty::Core::Moderation::ACTIONS, logger: Rubotty::Log.null)
  end

  # Both communities own a room keyed "general", which is the shipped config's
  # own naming, so the collision is ordinary rather than contrived.
  let(:feature) do
    Rubotty::Features::Moderation.new(
      topology: topology(room("general", tg_alpha), room("general", tg_beta)),
      adapters: Hash.new(adapter), storage: Rubotty::Storage::Memory.new,
      logger: Rubotty::Log.null, commands: commands
    )
  end

  def community(slug, directory)
    instance_double(
      Rubotty::ControlPlane::Snapshot::Community, id: slug == "alpha" ? 1 : 2, slug: slug,
      operators: directory
    )
  end

  def issue(origin, scope)
    msg = message(
      origin, text: "/ban", native_id: "1000", author: author(native_id: "55"),
      reply_to: ref(origin.id, "900"),
      reply_preview: Rubotty::Core::ReplyPreview.new(author: author(native_id: "777", username: "bad"))
    )
    feature.call(Rubotty::Features::Context.new(message: msg, community: scope))
  end

  it "carries out a command from an operator of the community it was issued in" do
    outcome = issue(tg_alpha, community("alpha", alpha_directory))
    expect(outcome.value.map(&:status)).to eq([:done])
  end

  it "refuses the same person in another community's identically named room" do
    outcome = issue(tg_beta, community("beta", beta_directory))
    expect(outcome.value).to be_empty
    expect(adapter.moderations).to be_empty
  end

  # Inverted from asserting that the parser falls back to its own directory:
  # that directory was the merged deployment-wide one under a control plane, so
  # a message whose community did not resolve was authorised against every
  # tenant's operators at once (#1786). It now resolves nobody.
  it "refuses when the message resolved no community, rather than reading a directory of its own" do
    outcome = issue(tg_alpha, nil)
    expect(outcome.value).to be_empty
    expect(adapter.moderations).to be_empty
  end

  # The config-file path keeps working, because there the single tenant's own
  # directory is what Features::Pipeline hands every Context.
  it "still authorises without a control plane, from the directory the pipeline hands in" do
    pipeline = Rubotty::Features::Pipeline.new(features: [feature], operators: alpha_directory)
    results = pipeline.handle(
      message(
        tg_alpha, text: "/ban", native_id: "1000", author: author(native_id: "55"),
                  reply_to: ref(tg_alpha.id, "900"),
                  reply_preview: Rubotty::Core::ReplyPreview.new(author: author(native_id: "777", username: "bad"))
      )
    )
    expect(results.map(&:status)).to eq([:done])
  end

  # And it cannot be handed one where a control plane is present, since there a
  # directory belongs to a community rather than to the deployment.
  it "refuses to carry a directory alongside a registry at all" do
    expect do
      Rubotty::Features::Pipeline.new(
        features: [feature], registry: colliding_registry, operators: merged_directory
      )
    end.to raise_error(ArgumentError, /community/)
  end

  # Having nobody to authorise against is a reason to refuse the verb, never a reason to
  # hand it on to the bridge as chat.
  it "still consumes a command word in a community that has no operators at all" do
    msg = message(tg_beta, text: "/ban", native_id: "1001", author: author(native_id: "55"))
    outcome = feature.call(
      Rubotty::Features::Context.new(message: msg, community: community("beta", beta_directory))
    )
    expect(outcome).to be_halt
    expect(adapter.moderations).to be_empty
  end
end
