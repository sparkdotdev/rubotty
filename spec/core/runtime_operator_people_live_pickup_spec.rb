# frozen_string_literal: true

require "spec_helper"

# Runtime used to hand Commands and Router the operator and people directories
# by value at boot, so approving an operator wrote the row and rebuilt the
# Snapshot while the bridge went on authorising against the boot-time copy.
RSpec.describe Rubotty::Core::Runtime, "live operator and people pickup", :control_plane do
  let(:config) { sample_model }

  def sequel_store
    db = Sequel.sqlite
    store = Rubotty::Storage::SequelStore.new(db: db, description: "test sqlite")
    store.migrate!
    store
  end

  let(:store) { sequel_store }

  let(:runtime) do
    described_class.new(
      config: config, logger: Rubotty::Log.null, storage: store, env: ControlPlaneHelpers::CONFIG_ENV
    ).build
  end

  let(:models) { Rubotty::ControlPlane.models(store.db) }
  let(:bootstrap) { models.operator.first }

  describe "an operator approved through the running operator_flow" do
    it "authorises on the router with no restart" do
      expect(runtime.router.operators.resolve(:telegram, "999888")).to be_nil

      result = runtime.operator_flow.request(
        community_id: bootstrap.community_id, adapter: "telegram", native_id: "999888",
        username: "newbie", display: "New Bie"
      )
      runtime.operator_flow.approve(request: result.request, approver: bootstrap)

      operator = runtime.router.operators.resolve(:telegram, "999888")
      expect(operator).not_to be_nil
      expect(operator.may?(:delete, "gaming", community_id: bootstrap.community_id)).to be(true)
    end

    it "is also resolvable as a mentionable person on the router with no restart" do
      expect(runtime.router.people.by_identity(:telegram, "999888")).to be_nil

      result = runtime.operator_flow.request(
        community_id: bootstrap.community_id, adapter: "telegram", native_id: "999888",
        username: "newbie", display: "New Bie"
      )
      runtime.operator_flow.approve(request: result.request, approver: bootstrap)

      person = runtime.router.people.by_identity(:telegram, "999888")
      expect(person).not_to be_nil
      expect(person.name).to eq("New Bie")
    end

    # The parser holds no directory of its own now: it is handed the message's
    # own community's on every command, so the reload has to reach THAT one.
    it "is observed through the community directory the parser is handed, not one it holds" do
      result = runtime.operator_flow.request(
        community_id: bootstrap.community_id, adapter: "telegram", native_id: "999888",
        username: "newbie", display: "New Bie"
      )
      runtime.operator_flow.approve(request: result.request, approver: bootstrap)

      expect(runtime.instance_variable_get(:@commands)).not_to respond_to(:directory)
      scope = runtime.registry.current.community_by_id(bootstrap.community_id)
      expect(scope.operators.resolve(:telegram, "999888")).not_to be_nil
    end
  end

  describe "without a control plane" do
    it "falls back to the static config directories, unchanged" do
      plain = described_class.new(
        config: config, logger: Rubotty::Log.null,
        storage: Rubotty::Storage::Memory.new, env: ControlPlaneHelpers::CONFIG_ENV
      ).build

      expect(plain.router.operators).to eq(config.operators)
      expect(plain.router.people).to eq(config.people)
    end
  end
end
