# frozen_string_literal: true

require "spec_helper"

# The moderation feature records every executed command as a structured audit event.
RSpec.describe "moderation feature audit logging (#49)" do
  let(:tg) { endpoint("tg") }
  let(:storage) { Rubotty::Storage::Memory.new }
  let(:adapter) { Fakes::ReactingAdapter.new(own_id: "bot") }
  let(:operator) { Rubotty::Core::Moderation::Operator.new(name: "Alex", identities: { fake: ["55"] }) }
  let(:directory) { Rubotty::Core::Moderation::Directory.new([operator]) }
  let(:commands) do
    Rubotty::Core::Commands.new(actions: Rubotty::Core::Moderation::ACTIONS, logger: Rubotty::Log.null)
  end

  # A tiny recording sink standing in for the durable audit log.
  let(:recorder) do
    Class.new do
      attr_reader :events

      def initialize = @events = []

      def record(**kwargs)
        @events << kwargs
        kwargs
      end
    end.new
  end

  let(:feature) do
    Rubotty::Features::Moderation.new(
      topology: topology(room("r", tg)), adapters: Hash.new(adapter), storage: storage,
      logger: Rubotty::Log.null, commands: commands, audit: recorder
    )
  end

  def community
    instance_double(
      Rubotty::ControlPlane::Snapshot::Community,
      id: 1, slug: "acme", operators: directory
    )
  end

  def issue(text, author_id: "55", target_id: "777", with_community: true, said: "")
    msg = message(
      tg, text: text, native_id: "1000", author: author(native_id: author_id),
      reply_to: ref("tg", "900"),
      reply_preview: Rubotty::Core::ReplyPreview.new(
        author: author(native_id: target_id, username: "bad"), body: said
      )
    )
    # Without a control plane the single tenant's directory is what the
    # pipeline hands in; with one it comes off the community.
    feature.call(
      Rubotty::Features::Context.new(
        message: msg, community: with_community ? community : nil,
        operators: with_community ? nil : directory
      )
    )
  end

  it "records an executed ban as a structured event scoped to the community" do
    issue("/ban")
    event = recorder.events.last
    expect(event).to include(
      source: "moderation", action: "ban", community: "acme", channel: "tg",
      adapter: "fake", subject_native_id: "777"
    )
    expect(event[:actor]).to eq("Alex")
    expect(event[:outcome]).to eq("1/1")
  end

  it "records the operator-supplied reason" do
    issue("/ban being a nuisance")
    expect(recorder.events.last[:reason]).to eq("being a nuisance")
  end

  it "does not record anything when the sender is not authorised" do
    issue("/ban", author_id: "999")
    expect(recorder.events).to be_empty
  end

  it "records with a nil community when there is no control plane" do
    issue("/ban", with_community: false)
    expect(recorder.events.last[:community]).to be_nil
  end

  # The excerpt is what the alert quotes, not what the row keeps; the sink
  # takes it and drops it, so a deleted message is readable in the DM to the
  # operators and nowhere else.
  it "carries what the deleted message said, for the operators to be told" do
    issue("/delete", said: "the words that got removed")
    expect(recorder.events.last[:excerpt]).to eq("the words that got removed")
  end

  it "carries no excerpt for a verb that acts on a person rather than a message" do
    issue("/ban", said: "the words that got removed")
    expect(recorder.events.last[:excerpt]).to be_nil
  end

  # Somebody taking back their own words is not a colleague's call anyone has to
  # review, and quoting it would put it back where they took it from.
  it "carries no excerpt when a member deletes their own message" do
    issue("/delete", author_id: "777", said: "what they thought better of")
    expect(recorder.events.last[:excerpt]).to be_nil
  end
end
