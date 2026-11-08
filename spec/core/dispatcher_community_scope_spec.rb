# frozen_string_literal: true

require "spec_helper"

# Worker queues are keyed per room across the WHOLE deployment, but a
# room_key is only unique within one community. Keying the queue and thread
# hashes on room.id let the second community's "general" overwrite the
# first one's entry, funnelling both communities' traffic through one queue.
RSpec.describe Rubotty::Core::Dispatcher, "queue identity across communities" do
  let(:alpha_tg) { endpoint("tg-alpha") }
  let(:beta_tg) { endpoint("tg-beta") }

  # What SnapshotBuilder produces: the same room_key in two communities, told
  # apart by unique_id.
  let(:alpha_general) { Rubotty::Core::Room.new(id: "general", unique_id: "1:general", endpoints: [alpha_tg]) }
  let(:beta_general) { Rubotty::Core::Room.new(id: "general", unique_id: "2:general", endpoints: [beta_tg]) }

  let(:router) { instance_spy(Rubotty::Core::Router) }

  subject(:dispatcher) do
    described_class.new(
      topology: topology(alpha_general, beta_general), router: router, logger: Rubotty::Log.null
    )
  end

  after { dispatcher.stop }

  def queues = dispatcher.instance_variable_get(:@queues)

  def threads = dispatcher.instance_variable_get(:@threads)

  it "gives each community's identically keyed room its own queue" do
    dispatcher.start

    expect(queues.keys).to contain_exactly("1:general", "2:general")
  end

  it "gives each of them its own worker thread" do
    dispatcher.start

    expect(threads.values.map(&:object_id).uniq.length).to eq(2)
  end

  it "closes every worker on stop, leaving none blocked on a lost queue" do
    dispatcher.start
    workers = threads.values
    dispatcher.stop

    expect(workers.map(&:alive?)).to all(be(false))
  end

  it "still routes both communities' traffic" do
    dispatcher.start
    dispatcher.call(message(alpha_tg, text: "from alpha", native_id: "1"))
    dispatcher.call(message(beta_tg, text: "from beta", native_id: "2"))
    dispatcher.drain

    expect(router).to have_received(:handle).twice
  end

  # A room_key is the right identity when there is only one community, which is
  # the config path, so nothing there needs to know about unique_id.
  it "falls back to the room key when no unique id was supplied" do
    plain = room("general", alpha_tg)

    expect(plain.unique_id).to eq("general")
  end
end
