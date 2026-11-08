# frozen_string_literal: true

require "spec_helper"

# Issue #1802. #identify_known looked its row up by endpoint_key alone, and
# endpoint keys are unique across the whole deployment rather than within one
# community, so the predicate would just as happily relabel another tenant's
# channel as the asking tenant's own.
RSpec.describe Rubotty::ControlPlane::ChannelDiscovery, "relabelling inside one community" do
  let(:plane) { colliding_control_plane }
  let(:models) { plane[1] }
  let(:seeded) { plane[2] }
  let(:alpha) { seeded[:alpha] }
  let(:beta) { seeded[:beta] }
  let(:now) { Time.new(2026, 8, 25, 12, 0, 0) }

  subject(:discovery) do
    described_class.new(models: models, logger: Rubotty::Log.null, clock: -> { now })
  end

  # Both communities own a room keyed "general", and each of their channels
  # carries its own globally unique endpoint key.
  def alpha_channel = models.channel.where(endpoint_key: alpha[:endpoint_keys].first).first

  def beta_channel = models.channel.where(endpoint_key: beta[:endpoint_keys].first).first

  it "relabels the asking community's own channel" do
    channel = discovery.identify_known(community_id: beta[:community_id], endpoint_key: beta_channel.endpoint_key,
                                       name: "Lisbon Meetup", operator: true)

    expect(channel.id).to eq(beta_channel.id)
    expect(beta_channel.reload.label).to eq("Lisbon Meetup")
  end

  it "finds nothing for a key belonging to the other community" do
    result = discovery.identify_known(community_id: beta[:community_id], endpoint_key: alpha_channel.endpoint_key,
                                      name: "Lisbon Meetup", operator: true)

    expect(result).to be_nil
  end

  it "leaves the other community's label and suggested flag exactly as they were" do
    before_label = alpha_channel.label
    discovery.identify_known(community_id: beta[:community_id], endpoint_key: alpha_channel.endpoint_key,
                             name: "Lisbon Meetup", operator: false)

    expect(alpha_channel.reload.label).to eq(before_label)
    expect(alpha_channel.reload.suggested).to be_falsey
  end

  # The signature is the defect the issue names: with no community on it, the
  # unscoped call was the only one that could be written.
  it "refuses a call with nothing to scope by" do
    expect do
      discovery.identify_known(community_id: nil, endpoint_key: beta_channel.endpoint_key,
                               name: "Lisbon Meetup", operator: true)
    end.to raise_error(ArgumentError)
  end

  it "keeps no overload taking a bare endpoint key" do
    expect do
      discovery.identify_known(endpoint_key: beta_channel.endpoint_key, name: "Lisbon Meetup", operator: true)
    end.to raise_error(ArgumentError)
  end
end
