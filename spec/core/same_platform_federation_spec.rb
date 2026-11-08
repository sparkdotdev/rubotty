# frozen_string_literal: true

require "spec_helper"

# The parts most likely to be wrong here key on the ADAPTER rather than the
# channel: the loop guard, which must not treat a sibling instance's copy as our
# own echo, and the sender label, which has to say which instance somebody is on.
RSpec.describe "bridging two instances of one federated platform" do
  let(:storage) { Rubotty::Storage::Memory.new }

  # One adapter, two accounts, as Fluxer models a flagship and a self hosted one.
  let(:home) { endpoint("fx-home", adapter: :fluxer, account: "home.example", settings: { room_key: "general" }) }
  let(:away) { endpoint("fx-away", adapter: :fluxer, account: "away.example", settings: { room_key: "general" }) }

  # The shared recording fake, plus the origin labelling a real federated
  # adapter supplies.
  let(:adapter) do
    Class.new(Fakes::RecordingAdapter) do
      def origin_label(endpoint) = endpoint.account.to_s

      def origin_protocol(_endpoint) = "fluxer"
    end.new
  end

  def router
    Rubotty::Core::Router.new(
      topology: topology(room("general", home, away)),
      adapters: Hash.new(adapter), storage: storage,
      loop_guard: Rubotty::Core::LoopGuard.new(storage: storage),
      logger: Rubotty::Log.null
    )
  end

  it "relays a message from one instance to the other" do
    router.handle(message(home, text: "hello from home"))

    landed = adapter.delivered.map(&:first)
    expect(landed).to include("fx-away")
  end

  it "does not deliver it back to the instance it came from" do
    router.handle(message(home, text: "hello from home"))

    expect(adapter.delivered.map(&:first)).not_to include("fx-home")
  end

  # A guard keyed too loosely would drop a sibling instance's message as our own
  # echo, since both sit under the SAME adapter.
  it "relays in both directions, so neither instance is mistaken for an echo" do
    subject_router = router
    subject_router.handle(message(home, text: "from home", native_id: "1"))
    subject_router.handle(message(away, text: "from away", native_id: "2"))

    landed = adapter.delivered.map(&:first)
    expect(landed).to include("fx-away").and include("fx-home")
  end

  # Asserted against what the router really delivered, since building both labels
  # here would only prove that SenderLabel.for does what it is told.
  describe "the label on what was delivered" do
    def delivered_label(from:)
      subject_router = router
      subject_router.handle(message(from, text: "hello", author: author(username: "ada")))
      adapter.delivered.first.last.sender_label
    end

    it "names the instance the sender is on" do
      expect(delivered_label(from: home).to_s).to include("home.example")
    end

    it "names the other instance for somebody on that one" do
      expect(delivered_label(from: away).to_s).to include("away.example")
    end

    it "carries the platform, so the label can say where rather than guess" do
      expect(delivered_label(from: home).platform).to eq("home.example")
    end

    it "carries the protocol both instances share" do
      expect(delivered_label(from: home).protocol).to eq("fluxer")
    end

    it "reads differently for the same handle on the two instances" do
      from_home = delivered_label(from: home).to_s

      adapter.delivered.clear
      storage.clear if storage.respond_to?(:clear)

      expect(delivered_label(from: away).to_s).not_to eq(from_home)
    end
  end
end
