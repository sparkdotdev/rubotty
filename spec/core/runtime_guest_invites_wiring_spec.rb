# frozen_string_literal: true

require "spec_helper"

# ONE real GuestInvites, shared by the /guest command and the guest adapter's
# own authenticate and live checks.
RSpec.describe Rubotty::Core::Runtime, "guest invites wiring", :control_plane do
  let(:config) { sample_model }

  def sequel_store
    db = Sequel.sqlite
    store = Rubotty::Storage::SequelStore.new(db: db, description: "test sqlite")
    store.migrate!
    store
  end

  def build_runtime(store:, env: ControlPlaneHelpers::CONFIG_ENV)
    described_class.new(config: config, logger: Rubotty::Log.null, storage: store, env: env).build
  end

  describe "construction, with a control plane" do
    let(:runtime) { build_runtime(store: sequel_store) }

    it "builds a real guest-invites service" do
      expect(runtime.guest_invites).to be_a(Rubotty::ControlPlane::GuestInvites)
    end

    it "wires Features::GuestCommand into the pipeline with the SAME guest_invites instance" do
      pipeline_features = runtime.router.instance_variable_get(:@pipeline).features
      feature = pipeline_features.find { |candidate| candidate.is_a?(Rubotty::Features::GuestCommand) }

      expect(feature).not_to be_nil
      expect(feature.instance_variable_get(:@guest_invites)).to be(runtime.guest_invites)
    end

    it "wires the guest adapter to the SAME guest_invites instance, not a separate one" do
      guest = runtime.adapters[[Rubotty::Adapters::Guest::NAME, Rubotty::Adapters::Guest::ACCOUNT]]
      expect(guest).not_to be_nil
      expect(guest.instance_variable_get(:@invites)).to be(runtime.guest_invites)
    end
  end

  describe "without a control plane" do
    it "leaves guest_invites nil" do
      runtime = build_runtime(store: Rubotty::Storage::Memory.new)
      expect(runtime.guest_invites).to be_nil
    end
  end
end
