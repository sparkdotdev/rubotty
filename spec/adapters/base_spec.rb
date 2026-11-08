# frozen_string_literal: true

require "spec_helper"

# Adapters::Base's own defaults, through Fakes::RecordingAdapter, which
# overrides none of them.
RSpec.describe Rubotty::Adapters::Base do
  subject(:adapter) { Fakes::RecordingAdapter.new }

  describe "native scheduled events" do
    it "reports no support by default" do
      expect(adapter.supports_native_events?).to be(false)
    end

    # The endpoint is required throughout the group (issue #1767): it is what
    # names the community whose space the call belongs in, so an implementation
    # can never be left scoping by a deployment-wide guess.
    it "is a no-op, not a raise, to attempt one anyway" do
      endpoint = endpoint("somewhere")

      expect(adapter.create_scheduled_event(double_event, endpoint)).to be_nil
      expect(adapter.update_scheduled_event("42", double_event, endpoint)).to be_nil
      expect(adapter.delete_scheduled_event("42", endpoint)).to be_nil
      expect(adapter.read_native_rsvps("42", endpoint)).to eq([])
    end

    it "refuses the shape of the call that has no community to scope by" do
      expect { adapter.create_scheduled_event(double_event) }.to raise_error(ArgumentError)
    end
  end

  describe "channel management (issue #227)" do
    it "reports no support by default" do
      expect(adapter.supports_channel_management?).to be(false)
    end

    it "is a no-op, not a raise, to attempt one anyway" do
      expect(adapter.create_channel(name: "gaming", community_id: 1)).to be_nil
      expect(adapter.delete_channel("42", community_id: 1)).to be(false)
      expect(adapter.copy_channel_permissions(from: "1", to: "2")).to be(false)
    end

    # Issue #1783: the contract had no parameter for a community at all, which
    # is what left both implementations guessing which space to act in.
    it "refuses the shape of either call that has nothing to scope by" do
      expect { adapter.create_channel(name: "gaming", community_id: nil) }.to raise_error(ArgumentError)
      expect { adapter.delete_channel("42", community_id: nil) }.to raise_error(ArgumentError)
    end

    it "keeps no overload of either call that takes a bare name or native id" do
      expect { adapter.create_channel(name: "gaming") }.to raise_error(ArgumentError)
      expect { adapter.delete_channel("42") }.to raise_error(ArgumentError)
    end
  end

  describe "#on_native_event_change" do
    it "accepts a listener with no error, even though nothing ever calls it" do
      expect { adapter.on_native_event_change { |change| change } }.not_to raise_error
    end

    it "returns self, so it can be chained at construction" do
      expect(adapter.on_native_event_change { nil }).to eq(adapter)
    end

    it "is a no-op when given no block" do
      expect(adapter.on_native_event_change).to eq(adapter)
    end
  end

  describe "live channel reconciliation (issue #700)" do
    it "has nothing to join by default, so it never has to be reconciled" do
      expect(adapter.joined_route_keys).to be_nil
    end

    it "is a no-op with no live resolver" do
      expect { adapter.reconcile_channels }.not_to raise_error
    end

    it "is a no-op with no cleanup scheduler" do
      expect { adapter.start_reconcile_loop }.not_to raise_error
    end
  end

  describe "#render_timestamp" do
    let(:time) { Time.utc(2026, 8, 1, 20, 0, 0) }

    it "renders a plain, non platform-specific string through the shared fallback" do
      expect(adapter.render_timestamp(time, tz: "UTC")).to eq(
        Rubotty::Util::EventTimestamps.format(time, style: :full, tz: "UTC")
      )
    end

    it "carries the style, tz and the caller's own instant through to the shared fallback" do
      expect(adapter.render_timestamp(time, style: :relative, tz: "UTC", now: time - (3 * 86_400)))
        .to eq("in 3 days")
    end
  end

  describe "#own_account_ids" do
    it "defaults to a single element array wrapping #own_account_id" do
      expect(adapter.own_account_ids).to eq([adapter.own_account_id])
    end
  end

  describe ".max_fetch_bytes_for" do
    it "reports no separate download ceiling by default" do
      expect(described_class.max_fetch_bytes_for({})).to be_nil
    end
  end

  def double_event
    Rubotty::Events::Event.new(
      { id: 1, community_id: 1, room_id: 1, title: "t", description: nil, timezone: "UTC",
        kind: "general", game_title: nil, server_address: nil, url: nil, rsvp_mode: "none",
        status: "scheduled", reminder_intervals: nil, native_refs: "{}", created_by: nil,
        starts_at: Time.now, ends_at: nil }
    )
  end
end
