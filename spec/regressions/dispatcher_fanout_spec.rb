# frozen_string_literal: true

require "spec_helper"

RSpec.describe "dispatching one inbound message into several rooms" do
  it "runs inbound policy once while the real bridge delivers once to every destination" do
    source = endpoint("source")
    destinations = 3.times.map { |i| endpoint("target-#{i}") }
    layout = topology(*destinations.each_with_index.map { |dest, i| room("room-#{i}", source, dest) })
    storage = Rubotty::Storage::Memory.new
    adapter = Fakes::RecordingAdapter.new(own_id: "bot-1")
    guard = Rubotty::Core::LoopGuard.new(storage: storage)
    allow(Rubotty::Features::AntiSpam).to receive(:default_enabled?).and_return(true)
    router = Rubotty::Core::Router.new(topology: layout, adapters: Hash.new(adapter), storage: storage,
                                      loop_guard: guard, logger: Rubotty::Log.null)
    moderation = router.instance_variable_get(:@pipeline).features.find do |feature|
      feature.is_a?(Rubotty::Features::AntiSpam)
    end
    expect(moderation).to receive(:call).once.and_call_original
    dispatcher = Rubotty::Core::Dispatcher.new(topology: layout, router: router, logger: Rubotty::Log.null)
    begin
      dispatcher.start
      dispatcher.call(message(source, text: "hello", native_id: "one"))
      dispatcher.drain
      expect(adapter.delivered.map(&:first)).to match_array(destinations.map(&:id))
    ensure
      dispatcher.stop
    end
  end
end
