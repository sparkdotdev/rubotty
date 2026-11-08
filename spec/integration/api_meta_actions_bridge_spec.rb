# frozen_string_literal: true

require "spec_helper"

# A room-level react/edit/delete, drained by {Adapters::Api::Adapter} the same
# way {ControlPlane::ApiMessages} already is, so {Features::Bridge} needs no
# code of its own to fan it out. Bridge's own per-target isolation applies
# unchanged: one bad channel never costs the other its copy.
RSpec.describe "a room-level message action fanning out through Bridge", :control_plane do

  # The ref the API route resolves before queueing: a meta-level action names
  # a message by the room it was minted in, never by a bare id.
  def message_ref(room, native_id)
    Rubotty::Core::MessageRef.new(Rubotty::Adapters::Api.endpoint_key_for(room.id), native_id)
  end
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }
  let(:room_row) { models.room.where(community_id: community.id, room_key: "general").first }

  let(:api_endpoint_id) { Rubotty::Adapters::Api.endpoint_key_for(room_row.id) }
  let(:api_endpoint) { endpoint(api_endpoint_id, adapter: :api, account: "api") }
  let(:good) { endpoint("good", adapter: :fake, account: "good-account") }
  let(:bad) { endpoint("bad", adapter: :fake, account: "bad-account") }

  let(:message_map) { Rubotty::Storage::Memory.new }
  let(:good_adapter) { Fakes::ReactingAdapter.new(own_id: "bot-1") }
  let(:bad_adapter) { Fakes::ReactingAdapter.new(own_id: "bot-1") }

  let(:adapters) do
    { [:fake, "good-account"] => good_adapter, [:fake, "bad-account"] => bad_adapter }
  end

  let(:loop_guard) { Rubotty::Core::LoopGuard.new(storage: message_map) }

  let(:bridge) do
    Rubotty::Features::Bridge.new(
      topology: topology(room("r", api_endpoint, good, bad)), adapters: adapters,
      storage: message_map, loop_guard: loop_guard, logger: Rubotty::Log.null, ttl: 3600
    )
  end

  let(:registry) do
    topo = topology(room("r", api_endpoint, good, bad))
    snapshot = instance_double(Rubotty::ControlPlane::Snapshot, topology: topo)
    instance_double(Rubotty::ControlPlane::Registry, current: snapshot)
  end

  let(:actions) { Rubotty::ControlPlane::ApiMessageActions.new(models: models) }

  # Routes a drained message straight into Bridge, standing in for the ordinary
  # dispatcher/router/pipeline the bot process would otherwise put it through;
  # this test's own concern is the queue-to-Bridge handoff, not the rest of it.
  let(:dispatcher) do
    lambda do |message|
      bridge.call(Rubotty::Features::Context.new(message: message))
    end
  end

  let(:key) do
    Rubotty::ControlPlane::ApiKeys.new(models: models)
                                 .issue(scope: "developer", community: community, label: "ops console").key_row
  end

  subject(:adapter) do
    Rubotty::Adapters::Api::Adapter.new(
      dispatcher: dispatcher, messages: Rubotty::ControlPlane::ApiMessages.new(models: models),
      actions: actions, models: models, registry: registry, logger: Rubotty::Log.null
    )
  end

  # Standing in for what Bridge itself would have recorded had the original
  # post actually gone out through the full pipeline.
  def seed_map!(message_id: "42")
    source = Rubotty::Core::MessageRef.new(api_endpoint_id, message_id)
    message_map.record(source: source, destination: Rubotty::Core::MessageRef.new("good", "g1"), room_id: "r")
    message_map.record(source: source, destination: Rubotty::Core::MessageRef.new("bad", "b1"), room_id: "r")
  end

  describe "a delete" do
    it "removes the copy on the channel that succeeds and does not raise over the one that fails" do
      seed_map!
      bad_adapter.fail_next(Rubotty::AdapterError.new("boom", adapter: :fake, retryable: false))
      actions.enqueue_delete(community: community, room: room_row, message: message_ref(room_row, "42"), key: key)

      expect { adapter.receive_pending }.not_to raise_error

      expect(good_adapter.deleted).to eq([%w[good g1]])
      expect(bad_adapter.deleted).to be_empty
    end
  end

  describe "an edit" do
    it "edits the copy that succeeds and does not raise over the one that fails" do
      seed_map!
      bad_adapter.fail_next(Rubotty::AdapterError.new("boom", adapter: :fake, retryable: false))
      actions.enqueue_edit(community: community, room: room_row, message: message_ref(room_row, "42"), body: "fixed", key: key)

      expect { adapter.receive_pending }.not_to raise_error

      expect(good_adapter.edited.map { |(id, native, _)| [id, native] }).to eq([%w[good g1]])
      expect(bad_adapter.edited).to be_empty
    end
  end

  describe "a reaction add" do
    it "syncs the copy that succeeds and swallows the one that raises" do
      seed_map!
      allow(bad_adapter).to receive(:sync_reactions)
        .and_raise(Rubotty::PermissionError.new("Forbidden", adapter: :fake))
      actions.enqueue_reaction_add(
        community: community, room: room_row, message: message_ref(room_row, "42"), reaction: { emoji: "\u{1F44D}" }, key: key
      )

      expect { adapter.receive_pending }.not_to raise_error

      expect(good_adapter.syncs.map { |s| s[:endpoint_id] }).to eq(["good"])
      expect(bad_adapter.syncs).to be_empty
    end
  end
end
