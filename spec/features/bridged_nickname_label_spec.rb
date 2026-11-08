# frozen_string_literal: true

require "spec_helper"

# The label half of a bridged nickname: what people on the target platform
# actually read. The nickname takes the identity position, the origin platform
# still follows it, and nothing changes for anyone who has not chosen one.
RSpec.describe "a bridged nickname on the sender label" do
  let(:tg) { endpoint("tg", adapter: :telegram) }
  let(:dc) { endpoint("dc", adapter: :discord) }
  let(:storage) { Rubotty::Storage::Memory.new }
  let(:adapter) { Fakes::RecordingAdapter.new(own_id: "bot-1") }

  let(:ada) do
    Rubotty::Core::Person.new(
      name: "ada",
      identities: { telegram: ["111"], discord: ["900"] },
      handles: { telegram: ["ada"] },
      nicknames: { discord: "owner" }
    )
  end

  let(:plain) do
    Rubotty::Core::Person.new(name: "bob", identities: { telegram: ["222"] }, handles: { telegram: ["bob"] })
  end

  let(:people) { Rubotty::Core::Directory.new([ada, plain]) }

  subject(:bridge) do
    Rubotty::Features::Bridge.new(
      topology: topology(room("r", tg, dc)),
      adapters: Hash.new(adapter),
      storage: storage,
      loop_guard: Rubotty::Core::LoopGuard.new(storage: storage),
      logger: Rubotty::Log.null,
      people: people
    )
  end

  # A fresh native id per call, or the loop guard drops the second relay in a
  # spec that sends two.
  def relay(author:, origin: tg)
    @sent = (@sent || 0) + 1
    context = Rubotty::Features::Context.new(
      message: message(origin, text: "hello", native_id: "m#{@sent}", author: author)
    )
    bridge.call(context)
    adapter.delivered
  end

  # The LAST delivery to that endpoint, so a spec that relays twice reads the
  # second one.
  def label_on(endpoint_id, delivered)
    delivered.reverse.find { |id, _| id == endpoint_id }&.last&.sender_label
  end

  it "shows the chosen name on the platform it was chosen for" do
    delivered = relay(author: author(native_id: "111", username: "ada"))

    # The chosen name leads, and the handle it belongs to still follows it.
    expect(label_on("dc", delivered).to_s).to include("owner")
    expect(label_on("dc", delivered).to_s).to include("ada")
  end

  it "still names the platform the sender is speaking from, the same way an ordinary label does" do
    ordinary = label_on("dc", relay(author: author(native_id: "222", username: "bob"))).to_s
    nicknamed = label_on("dc", relay(author: author(native_id: "111", username: "ada"))).to_s

    platform = ordinary[/@([\w.-]+)/, 1]
    expect(platform).not_to be_nil
    # The chosen name takes the position a profile name would, and the handle it
    # belongs to follows in brackets, so a reader can still tell who is speaking.
    expect(nicknamed).to eq("owner [ada@#{platform}]")
  end

  it "leaves a platform she chose nothing for alone" do
    delivered = relay(author: author(native_id: "900", username: "ada_dc"), origin: dc)

    expect(label_on("tg", delivered).to_s).to include("ada_dc")
    expect(label_on("tg", delivered).to_s).not_to include("owner")
  end

  it "leaves somebody with no nickname at all exactly as they were" do
    delivered = relay(author: author(native_id: "222", username: "bob"))

    expect(label_on("dc", delivered).to_s).to include("bob")
  end

  it "leaves an author the directory does not know alone" do
    delivered = relay(author: author(native_id: "404", username: "stranger"))

    expect(label_on("dc", delivered).to_s).to include("stranger")
  end

  it "does nothing at all without a people directory" do
    bare = Rubotty::Features::Bridge.new(
      topology: topology(room("r", tg, dc)), adapters: Hash.new(adapter), storage: storage,
      loop_guard: Rubotty::Core::LoopGuard.new(storage: storage), logger: Rubotty::Log.null
    )
    context = Rubotty::Features::Context.new(
      message: message(tg, text: "hello", author: author(native_id: "111", username: "ada"))
    )
    bare.call(context)

    expect(label_on("dc", adapter.delivered).to_s).to include("ada")
  end
end
