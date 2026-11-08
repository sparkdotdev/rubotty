# frozen_string_literal: true

require "spec_helper"

module DispatcherGenerationSpec
  MutableTopology = Struct.new(:rooms) do
    def rooms_for(id) = rooms.select { |room| room.include?(id) }
    def endpoints = rooms.flat_map(&:endpoints).uniq(&:id)
    def endpoint(id) = endpoints.find { |endpoint| endpoint.id == id }
  end
end

RSpec.describe "dispatcher topology generations" do
  let(:a) { endpoint("a") }
  let(:b) { endpoint("b") }
  let(:c) { endpoint("c") }
  let(:x) { endpoint("x") }
  let(:release) { Queue.new }
  let(:entered) { Queue.new }
  let(:received) { Queue.new }
  let(:live) { DispatcherGenerationSpec::MutableTopology.new(independent_rooms) }
  let(:adapter) { Fakes::RecordingAdapter.new }
  let(:dispatcher) do
    original = adapter.method(:deliver)
    # Capture queue locals explicitly: the adapter's instance is the receiver.
    entered_queue, release_queue, received_queue = entered, release, received
    adapter.define_singleton_method(:deliver) do |message, target|
      if target.id == "c"
        if message.body.text == "first"
          entered_queue << :blocked
          release_queue.pop(timeout: 5)
        end
        received_queue << message.body.text
      end
      original.call(message, target)
    end
    bridge = Rubotty::Features::Bridge.new(topology: live, adapters: Hash.new(adapter),
      storage: Rubotty::Storage::Memory.new, loop_guard: Rubotty::Core::LoopGuard.new,
      logger: Rubotty::Log.null)
    handler = Object.new
    handler.define_singleton_method(:handle) { |message| bridge.call(Rubotty::Features::Context.new(message: message)) }
    Rubotty::Core::Dispatcher.new(topology: live, router: handler, logger: Rubotty::Log.null).start
  end

  def independent_rooms = [room("r1", a, x), room("r2", b, c)]
  def merged_rooms = [room("r1", a, b, x), room("r2", b, c)]
  def send_message(text, id) = dispatcher.call(message(b, text: text, native_id: id))

  after do
    5.times { release << :go }
    dispatcher.stop(timeout: 1)
  end

  it "waits for both old groups before delivering from their merged successor" do
    send_message("first", "1")
    expect(entered.pop(timeout: 2)).to eq(:blocked)
    live.rooms = merged_rooms
    caller = Thread.new { send_message("second", "2") }
    expect(caller.join(1)).to eq(caller)
    expect(received.pop(timeout: 0.05)).to be_nil
    release << :go
    expect(dispatcher.drain(timeout: 3)).to be(true)
    expect([received.pop, received.pop]).to eq(%w[first second])
  end

  it "waits for the old shared worker when splitting a room group" do
    live.rooms = merged_rooms
    send_message("first", "1")
    expect(entered.pop(timeout: 2)).to eq(:blocked)
    live.rooms = independent_rooms
    send_message("second", "2")
    expect(received.pop(timeout: 0.05)).to be_nil
    release << :go
    expect(dispatcher.drain(timeout: 3)).to be(true)
    expect([received.pop, received.pop]).to eq(%w[first second])
  end

  it "preserves predecessor order across a merge followed immediately by a split" do
    send_message("first", "1")
    expect(entered.pop(timeout: 2)).to eq(:blocked)
    live.rooms = merged_rooms
    send_message("second", "2")
    live.rooms = independent_rooms
    send_message("third", "3")
    expect(received.pop(timeout: 0.05)).to be_nil
    release << :go
    expect(dispatcher.drain(timeout: 3)).to be(true)
    expect(3.times.map { received.pop }).to eq(%w[first second third])
  end

  it "drains old backlog and its dependent generation during shutdown" do
    send_message("first", "1")
    expect(entered.pop(timeout: 2)).to eq(:blocked)
    send_message("queued", "2")
    live.rooms = merged_rooms
    send_message("later", "3")
    stopper = Thread.new { dispatcher.stop(timeout: 3) }
    expect(received.pop(timeout: 0.05)).to be_nil
    release << :go
    expect(stopper.join(3)).to eq(stopper)
    expect(3.times.map { received.pop }).to eq(%w[first queued later])
    expect(dispatcher.drain(timeout: 0.1)).to be(true)
  end

  it "bounds shutdown when a predecessor never finishes" do
    send_message("first", "1")
    expect(entered.pop(timeout: 2)).to eq(:blocked)
    live.rooms = merged_rooms
    send_message("second", "2")
    workers = dispatcher.instance_variable_get(:@threads).values +
              dispatcher.instance_variable_get(:@retired_workers).map(&:thread)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    dispatcher.stop(timeout: 0.05)
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 0.5
    workers.each { |thread| thread.join(1) }
    expect(workers).to all(satisfy { |thread| !thread.alive? })
  end
end

RSpec.describe "IRC delivery registration guard" do
  it "refuses a connected but unregistered socket while allowing CAP registration writes" do
    target = endpoint("irc", adapter: :irc, settings: { channel: "#synthetic" })
    adapter = Rubotty::Adapters::Irc::Adapter.new(account: "synthetic",
      settings: { server: "irc.example.org", nick: "test" }, dispatcher: nil,
      logger: Rubotty::Log.null, endpoints: [target])
    writes = []
    socket = double("connected socket")
    allow(socket).to receive(:write) { |line| writes << line }
    adapter.client.instance_variable_set(:@socket, socket)
    expect { adapter.deliver(message(target), target) }
      .to raise_error(Rubotty::AdapterError, /registration is not complete/)
    expect(writes).to be_empty
    adapter.client.send(:send_line, "CAP LS 302")
    expect(writes).to eq(["CAP LS 302\r\n"])
    adapter.client.instance_variable_set(:@registered, true)
    expect(adapter.deliver(message(target), target)).to be_a(Rubotty::Core::DeliveryReceipt)
    expect(writes.last).to include("PRIVMSG #synthetic")
  end
end
