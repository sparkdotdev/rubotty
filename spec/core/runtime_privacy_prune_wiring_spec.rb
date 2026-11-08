# frozen_string_literal: true

require "spec_helper"

# Scripting::Memory#sweep and IdentityDirectory#prune both existed with no
# scheduled caller anywhere in lib, bin or spec outside their own spec files.
# Only the wiring is asserted here; the deletion logic itself is
# spec/scripting/memory_spec.rb's and identity_directory_spec.rb's job.
RSpec.describe Rubotty::Core::Runtime, "expired-memo and stale-identity sweep wiring", :control_plane do
  let(:config) { sample_model }

  def sequel_store
    db = Sequel.sqlite
    store = Rubotty::Storage::SequelStore.new(db: db, description: "test sqlite")
    store.migrate!
    store
  end

  def runtime
    described_class.new(config: config, logger: Rubotty::Log.null, storage: sequel_store,
                        env: ControlPlaneHelpers::CONFIG_ENV).build
  end

  # bot_messages is the record /clean sweeps. Nothing else ever deletes a row,
  # so an unregistered prune means the table grows for the life of the
  # deployment rather than to its retention ceiling.
  describe "the daily bot-message record sweep" do
    it "is on the durable scheduler, exactly once, with a handler behind it" do
      built = runtime

      expect(built.durable_scheduler.pending(kind: Rubotty::ControlPlane::BotMessages::PRUNE_KIND)).to eq(1)
      expect(built.durable_scheduler.handler?(Rubotty::ControlPlane::BotMessages::PRUNE_KIND)).to be(true)
    end
  end

  describe "the daily script-memory sweep" do
    def sweep_job(built)
      Rubotty::ControlPlane::Boot.db_of(built.storage)[:scheduled_jobs]
        .where(kind: Rubotty::Scripting::Memory::PRUNE_KIND, status: "pending").first
    end

    it "is on the durable scheduler, exactly once, with a handler behind it" do
      built = runtime

      expect(built.durable_scheduler.pending(kind: Rubotty::Scripting::Memory::PRUNE_KIND)).to eq(1)
      expect(built.durable_scheduler.handler?(Rubotty::Scripting::Memory::PRUNE_KIND)).to be(true)
    end

    it "recurs once a day" do
      expect(sweep_job(runtime)[:recurrence].to_i).to eq(Rubotty::Scripting::Memory::PRUNE_INTERVAL)
    end

    it "actually deletes an expired memo when the handler fires" do
      built = runtime
      memory = built.instance_variable_get(:@script_memory)
      community = built.registry.current.communities.first
      script = built.instance_variable_get(:@scripts).save(
        community: community, name: "probe", kind: "processor", source: "return nil", trigger_type: "always"
      )
      memory.remember(script, "general", key: "gone", value: "x", ttl: 60)
      Rubotty::ControlPlane::Boot.db_of(built.storage)[:script_memos]
                                 .where(key: "gone").update(expires_at: Time.now - 1)

      handler = built.durable_scheduler.instance_variable_get(:@handlers)[Rubotty::Scripting::Memory::PRUNE_KIND]
      handler.call(nil)

      expect(memory.recall(script, "general", key: "gone")).to be_nil
      expect(Rubotty::ControlPlane::Boot.db_of(built.storage)[:script_memos].where(key: "gone").count).to eq(0)
    end
  end

  describe "the daily identity-directory prune" do
    def prune_job(built)
      Rubotty::ControlPlane::Boot.db_of(built.storage)[:scheduled_jobs]
        .where(kind: Rubotty::ControlPlane::IdentityDirectory::PRUNE_KIND, status: "pending").first
    end

    it "is on the durable scheduler, exactly once, with a handler behind it" do
      built = runtime

      expect(built.durable_scheduler.pending(kind: Rubotty::ControlPlane::IdentityDirectory::PRUNE_KIND)).to eq(1)
      expect(built.durable_scheduler.handler?(Rubotty::ControlPlane::IdentityDirectory::PRUNE_KIND)).to be(true)
    end

    it "recurs once a day" do
      expect(prune_job(runtime)[:recurrence].to_i).to eq(Rubotty::ControlPlane::IdentityDirectory::PRUNE_INTERVAL)
    end

    it "actually deletes a stale identity when the handler fires" do
      built = runtime
      directory = built.identity_directory
      community = built.registry.current.communities.first
      directory.record(community_id: community.id, adapter: "telegram", native_id: "999", username: "ghost")
      models = Rubotty::ControlPlane.models(Rubotty::ControlPlane::Boot.db_of(built.storage))
      models.observed_identity.where(native_id: "999")
            .update(last_seen_at: Time.now - Rubotty::ControlPlane::IdentityDirectory::RETENTION - 1)

      handler = built.durable_scheduler.instance_variable_get(:@handlers)[
        Rubotty::ControlPlane::IdentityDirectory::PRUNE_KIND
      ]
      handler.call(nil)

      expect(directory.entry(community_id: community.id, adapter: "telegram", native_id: "999")).to be_nil
    end
  end

  describe "the daily identity-history prune (#1477)" do
    def prune_job(built)
      Rubotty::ControlPlane::Boot.db_of(built.storage)[:scheduled_jobs]
        .where(kind: Rubotty::ControlPlane::IdentityDirectory::NAME_HISTORY_PRUNE_KIND, status: "pending").first
    end

    it "is on the durable scheduler, exactly once, with a handler behind it" do
      built = runtime

      expect(built.durable_scheduler.pending(kind: Rubotty::ControlPlane::IdentityDirectory::NAME_HISTORY_PRUNE_KIND))
        .to eq(1)
      expect(
        built.durable_scheduler.handler?(Rubotty::ControlPlane::IdentityDirectory::NAME_HISTORY_PRUNE_KIND)
      ).to be(true)
    end

    it "recurs once a day" do
      expect(prune_job(runtime)[:recurrence].to_i).to eq(Rubotty::ControlPlane::IdentityDirectory::PRUNE_INTERVAL)
    end

    it "actually deletes a closed history row past retention when the handler fires" do
      built = runtime
      directory = built.identity_directory
      community = built.registry.current.communities.first
      models = Rubotty::ControlPlane.models(Rubotty::ControlPlane::Boot.db_of(built.storage))
      models.feature_setting.create(
        community_id: community.id, room_id: nil, feature: "identity_history", enabled: true,
        config: "{}", created_at: Time.now, updated_at: Time.now
      )
      directory.record(community_id: community.id, adapter: "telegram", native_id: "999", username: "ghost")
      directory.record(community_id: community.id, adapter: "telegram", native_id: "999", username: "haunted")
      models.observed_identity_name.where(native_id: "999", ended_at: nil).update(ended_at: Time.now)
      models.observed_identity_name.where(native_id: "999")
            .update(ended_at: Time.now - Rubotty::ControlPlane::IdentityDirectory::NAME_HISTORY_RETENTION - 1)

      handler = built.durable_scheduler.instance_variable_get(:@handlers)[
        Rubotty::ControlPlane::IdentityDirectory::NAME_HISTORY_PRUNE_KIND
      ]
      handler.call(nil)

      expect(
        directory.name_history(community_id: community.id, adapter: "telegram", native_id: "999")
      ).to be_empty
    end
  end

  describe "the daily bridged-nickname-history prune (#1518)" do
    def prune_job(built)
      Rubotty::ControlPlane::Boot.db_of(built.storage)[:scheduled_jobs]
        .where(kind: Rubotty::ControlPlane::BridgedNicknames::NAME_HISTORY_PRUNE_KIND, status: "pending").first
    end

    it "is on the durable scheduler, exactly once, with a handler behind it" do
      built = runtime

      expect(
        built.durable_scheduler.pending(kind: Rubotty::ControlPlane::BridgedNicknames::NAME_HISTORY_PRUNE_KIND)
      ).to eq(1)
      expect(
        built.durable_scheduler.handler?(Rubotty::ControlPlane::BridgedNicknames::NAME_HISTORY_PRUNE_KIND)
      ).to be(true)
    end

    it "recurs once a day" do
      expect(prune_job(runtime)[:recurrence].to_i).to eq(Rubotty::ControlPlane::IdentityDirectory::PRUNE_INTERVAL)
    end

    it "actually deletes a closed nickname-history row past retention when the handler fires" do
      built = runtime
      nicknames = built.instance_variable_get(:@bridged_nicknames)
      community = built.registry.current.communities.first
      models = Rubotty::ControlPlane.models(Rubotty::ControlPlane::Boot.db_of(built.storage))
      models.feature_setting.create(
        community_id: community.id, room_id: nil, feature: "identity_history", enabled: true,
        config: "{}", created_at: Time.now, updated_at: Time.now
      )
      person = models.person.where(community_id: community.id).order(:id).first
      nicknames.set(community_id: community.id, person_id: person.id, adapter: "discord", nickname: "owner")
      nicknames.set(community_id: community.id, person_id: person.id, adapter: "discord", nickname: "owner_handle")
      models.bridged_nickname_history.where(person_id: person.id).exclude(ended_at: nil)
            .update(ended_at: Time.now - Rubotty::ControlPlane::BridgedNicknames::NAME_HISTORY_RETENTION - 1)

      handler = built.durable_scheduler.instance_variable_get(:@handlers)[
        Rubotty::ControlPlane::BridgedNicknames::NAME_HISTORY_PRUNE_KIND
      ]
      handler.call(nil)

      expect(
        nicknames.nickname_history(community_id: community.id, person_id: person.id, adapter: "discord")
      ).to contain_exactly(have_attributes(nickname: "owner_handle"))
    end
  end
end
