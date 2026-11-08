# frozen_string_literal: true

require "spec_helper"

# The de-noising brain over the seeded SAMPLE control plane: a sighting becomes a
# prompt only for a new, unignored, unprompted channel in an authorized, opted-in
# community.
RSpec.describe Rubotty::ControlPlane::NewChannelWatch, :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:community) { models.community.first }
  let(:connection) { models.platform_connection.where(community_id: community.id, adapter: "telegram").first }
  let(:existing_channel) { models.channel.where(community_id: community.id, adapter: "telegram").first }

  # The get_state/put_state surface the message map exposes, with expiry on read.
  let(:store) do
    Class.new do
      def initialize = @h = {}
      def get_state(key)
        row = @h[key]
        return nil if row.nil?
        return nil if row[:expires_at] && row[:expires_at] <= Time.now

        row[:value]
      end
      def put_state(key, value, expires_at: nil) = @h[key] = { value: value, expires_at: expires_at }
    end.new
  end

  subject(:watch) { described_class.new(models: models, store: store, logger: Rubotty::Log.null) }

  # Alerts default to on, so this only matters for setting the ignore patterns.
  def enable_alerts(ignore: [])
    settings = community.json_value(:settings)
    settings["new_channel_alerts"] = { "enabled" => true, "ignore" => ignore }
    community.update(settings: JSON.generate(settings))
  end

  def disable_alerts
    settings = community.json_value(:settings)
    settings["new_channel_alerts"] = { "enabled" => false }
    community.update(settings: JSON.generate(settings))
  end

  # A sighting of a brand-new topic in the authorized supergroup.
  def new_topic(route_key: "#{connection.external_id}/9999", name: "new-topic")
    {
      adapter: "telegram", account: connection.account,
      external_id: connection.external_id, route_key: route_key, name: name
    }
  end

  describe "#observe" do
    it "prompts for a new, unmapped channel in an opted-in community" do
      enable_alerts
      decision = watch.observe(new_topic)
      expect(decision.prompt?).to be(true)
      expect(decision.community.id).to eq(community.id)
      expect(decision.descriptor[:name]).to eq("new-topic")
    end

    it "prompts by default: no writer ever existed for the old opt-in, so alerts are on unless a community explicitly opts out" do
      decision = watch.observe(new_topic)
      expect(decision.prompt?).to be(true)
    end

    it "stays dormant once a community explicitly opts out" do
      disable_alerts
      decision = watch.observe(new_topic)
      expect(decision.ignore?).to be(true)
      expect(decision.reason).to eq(:disabled)
    end

    # A known channel has to settle as :already_mapped even with alerts off, since
    # that is the outcome ChannelDiscovery#backfill_name acts on to replace an
    # adapter's placeholder name.
    it "still reports an already-known channel as already_mapped when alerts are off" do
      disable_alerts
      known = {
        adapter: "telegram", account: existing_channel.account,
        external_id: connection.external_id,
        route_key: existing_channel.route_key,
        name: "whatever"
      }

      decision = watch.observe(known)
      expect(decision.reason).to eq(:already_mapped)
    end

    it "prompts only once for the same channel, however chatty it is" do
      enable_alerts
      expect(watch.observe(new_topic).prompt?).to be(true)
      second = watch.observe(new_topic)
      expect(second.ignore?).to be(true)
      expect(second.reason).to eq(:already_prompted)
    end

    it "ignores a channel that is already a known row (mapped or seeded)" do
      enable_alerts
      known = new_topic(route_key: existing_channel.route_key)
      decision = watch.observe(known)
      expect(decision.ignore?).to be(true)
      expect(decision.reason).to eq(:already_mapped)
    end

    it "ignores a channel whose name matches an ignore pattern" do
      enable_alerts(ignore: ["temp-*", "spoilers"])
      expect(watch.observe(new_topic(name: "temp-standup")).reason).to eq(:ignored_name)
      expect(watch.observe(new_topic(name: "SPOILERS thread")).reason).to eq(:ignored_name)
      # A name that does not match still prompts.
      expect(watch.observe(new_topic(name: "general-chat")).prompt?).to be(true)
    end

    it "ignores a sighting in a space no community owns (auto-leave handles that)" do
      decision = watch.observe(new_topic.merge(external_id: "-100000000"))
      expect(decision.reason).to eq(:unauthorized)
    end

    it "does not prompt for a stopped community's new channels" do
      enable_alerts
      community.update(status: "suspended")
      expect(watch.observe(new_topic).reason).to eq(:unauthorized)
    end
  end
end
