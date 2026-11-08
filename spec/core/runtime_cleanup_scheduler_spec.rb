# frozen_string_literal: true

require "spec_helper"

# The shared cleanup scheduler used to be built only when the STATIC
# commands.cleanup_after or announce.delete_after was positive, which is 0
# on an all-defaults config, so the timer was nil on every real database-only
# boot even though IRC/XMPP re-sync and moderation's ack_ttl_seconds ride it.
RSpec.describe Rubotty::Core::Runtime, "cleanup scheduler" do
  def runtime_for(yaml)
    described_class.new(
      config: Rubotty::Config::Loader.load_string(yaml, env: { "TG_TOKEN" => "123:abc" }),
      logger: Rubotty::Log.null
    )
  end

  let(:bare) { runtime_for("") }

  it "builds on an all-defaults config, where the command grace period is zero" do
    expect(bare.config.command_cleanup_after).to eq(0)
    expect(bare.config.announce_delete_after).to eq(Rubotty::Config::Model::DEFAULT_ANNOUNCE_DELETE_AFTER)
    expect(bare.send(:build_scheduler)).to be_a(Rubotty::Core::Scheduler)
  end

  it "still builds when a knob is set, which is the only case it used to cover" do
    with_grace = runtime_for("commands:\n  cleanup_after: 15\n")
    expect(with_grace.send(:build_scheduler)).to be_a(Rubotty::Core::Scheduler)
  end

  # An adapter that has to join a space before it can hear it (IRC, XMPP)
  # re-arms its live-snapshot re-sync against #cleanup. A nil scheduler leaves
  # the boot join standing and never runs a second sweep, so a channel mapped
  # in the dashboard after boot waits for a restart.
  let(:joining_adapter_class) do
    Class.new(Rubotty::Adapters::Base) do
      def joined_route_keys = []
      def reconcile_channels = nil
    end
  end

  it "gives an adapter's live channel re-sync something to re-arm on" do
    scheduler = bare.send(:build_scheduler)
    adapter = joining_adapter_class.new(
      account: "irc", settings: {}, dispatcher: ->(_message) {}, logger: Rubotty::Log.null
    )

    adapter.cleanup = scheduler
    adapter.start_reconcile_loop

    expect(scheduler.pending).to eq(1)
  end
end
