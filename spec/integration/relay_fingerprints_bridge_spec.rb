# frozen_string_literal: true

require "spec_helper"

# The content ledger, written from the real relay rather than exercised
# directly: an arrival fingerprint at the endpoint a message came in on, and
# a post fingerprint at every endpoint the bridge delivered a copy to, both
# built from the SOURCE message so a lookup on either answers the same way.
RSpec.describe "the relay writes the content ledger at fan-out", :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:config) { sample_model }
  let(:community) { models.community.where(slug: "sample").first }
  let(:registry) { Rubotty::ControlPlane::Registry.build(models: models, accounts: config.accounts) }
  let(:snapshot) { registry.current }

  let(:storage) { Rubotty::Storage::Memory.new }
  let(:loop_guard) { Rubotty::Core::LoopGuard.new }
  let(:ledger) { Rubotty::ControlPlane::RelayFingerprints.new(models: models) }

  # One RecordingAdapter per real (adapter, account) in the topology.
  let(:adapter_map) do
    snapshot.topology.endpoints
            .reject { |e| %i[guest api].include?(e.adapter_name) }
            .each_with_object({}) do |e, map|
      map[[e.adapter_name, e.account]] ||= Fakes::RecordingAdapter.new(account: e.account)
    end
  end

  let(:route) do
    Rubotty::Core::Router.new(
      topology: snapshot.topology, adapters: adapter_map, storage: storage,
      loop_guard: loop_guard, logger: Rubotty::Log.null, registry: registry,
      relay_fingerprints: ledger
    )
  end

  def endpoint_of(id) = snapshot.topology.endpoints.find { |e| e.id == id }

  def adapter_for(endpoint_id)
    e = endpoint_of(endpoint_id)
    adapter_map[[e.adapter_name, e.account]]
  end

  def present?(endpoint_id, text:, author:, timestamp:)
    ledger.present?(community_id: community.id, endpoint_id: endpoint_id,
                    text: text, author: author, timestamp: timestamp)
  end

  it "records the arrival on the origin and the post on every target, from the same source content" do
    now = Time.now
    sender = author(native_id: "u1", username: "ada")
    route.handle(message(endpoint_of("tg-general"), text: "deploy finished", native_id: "1",
                                                     author: sender, timestamp: now))

    expect(present?("tg-general", text: "deploy finished", author: "telegram:u1", timestamp: now)).to be(true)
    expect(present?("dc-general", text: "deploy finished", author: "telegram:u1", timestamp: now)).to be(true)
  end

  it "records nothing on an endpoint the message never reached" do
    now = Time.now
    sender = author(native_id: "u1", username: "ada")
    route.handle(message(endpoint_of("tg-general"), text: "hello", native_id: "1",
                                                     author: sender, timestamp: now))

    expect(present?("tg-gaming", text: "hello", author: "telegram:u1", timestamp: now)).to be(false)
  end

  it "answers false without ever having relayed anything (no assumption, only what was seen)" do
    expect(present?("tg-general", text: "never sent", author: "telegram:u1", timestamp: Time.now)).to be(false)
  end

  it "preserves a separate native message even when its author repeats the same text" do
    now = Time.now
    sender = author(native_id: "u1", username: "ada")
    route.handle(message(endpoint_of("tg-general"), text: "deploy finished", native_id: "1",
                                                     author: sender, timestamp: now))
    route.handle(message(endpoint_of("tg-general"), text: "deploy finished", native_id: "2",
                                                     author: sender, timestamp: now))

    expect(adapter_for("dc-general").delivered.size).to eq(2)
  end

  it "still relays content a target has not already seen" do
    now = Time.now
    sender = author(native_id: "u1", username: "ada")
    route.handle(message(endpoint_of("tg-general"), text: "deploy finished", native_id: "1",
                                                     author: sender, timestamp: now))
    route.handle(message(endpoint_of("tg-general"), text: "rollback started", native_id: "2",
                                                     author: sender, timestamp: now))

    expect(adapter_for("dc-general").delivered.size).to eq(2)
  end
end
