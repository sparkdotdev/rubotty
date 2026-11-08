# frozen_string_literal: true

require "spec_helper"

# Issue #1790. #request_delete took a community and a room and never asked
# whether they went together, so a mispaired call went straight to a durable
# job that destroyed the room, its mappings and the real platform channels.
RSpec.describe Rubotty::ControlPlane::RoomProvisioning, "scoped to one community" do
  let(:plane) { colliding_control_plane }
  let(:db) { plane[0] }
  let(:models) { plane[1] }
  let(:seeded) { plane[2] }
  let(:alpha) { models.community[seeded[:alpha][:community_id]] }
  let(:beta) { models.community[seeded[:beta][:community_id]] }
  let(:beta_room) { models.room[seeded[:beta][:room_id]] }
  let(:beta_channel_ids) { models.room_channel.where(room_id: beta_room.id).select_map(:channel_id) }
  let(:now) { Time.new(2026, 8, 25, 12, 0, 0) }
  let(:logs) { StringIO.new }
  let(:logger) { Rubotty::Log.build(level: "error", io: logs) }
  let(:audit) { Rubotty::Core::AuditLog::Sequel.new(db: db) }

  # Records what it was asked to delete and always succeeds, so anything the
  # refusal fails to stop shows up as a real platform delete.
  let(:adapter) do
    Class.new do
      attr_reader :deleted

      def initialize = @deleted = []

      def supports_channel_management? = true

      def delete_channel(native_id, community_id:)
        raise ArgumentError, "no community" if community_id.nil?

        @deleted << native_id
        true
      end
    end.new
  end

  let(:scheduler) do
    Class.new do
      attr_reader :jobs

      def initialize = @jobs = []

      def schedule(kind:, run_at:, payload:, community: nil)
        @jobs << { kind: kind, run_at: run_at, payload: payload, community: community }
      end
    end.new
  end

  subject(:service) do
    described_class.new(
      models: models, scheduler: scheduler, audit: audit, logger: logger, clock: -> { now },
      adapters: { [:telegram, "shared"] => adapter, [:discord, "shared"] => adapter }
    )
  end

  def delete_job(community_id:, room_id:, force_channel_ids: [])
    Struct.new(:payload).new(
      { "community_id" => community_id, "room_id" => room_id,
        "delete_platform_channels" => true, "force_channel_ids" => force_channel_ids,
        "requested_by" => "sample_owner" }
    )
  end

  describe "#request_delete" do
    it "refuses a room belonging to the other community" do
      expect do
        service.request_delete(community: alpha, room: beta_room, confirmed_name: "general",
                               requested_by: "sample_owner")
      end.to raise_error(described_class::Invalid, /does not belong to this community/)
    end

    # The confirmation is typed against the room's own name, and both rooms are
    # keyed "general", so the misclick guard would have waved this through.
    it "enqueues nothing at all when it refuses" do
      begin
        service.request_delete(community: alpha, room: beta_room, confirmed_name: "general",
                               requested_by: "sample_owner")
      rescue described_class::Invalid
        nil
      end
      expect(scheduler.jobs).to be_empty
    end

    it "still enqueues the delete for the community that really owns the room" do
      service.request_delete(community: beta, room: beta_room, confirmed_name: "general",
                             requested_by: "sample_owner")
      expect(scheduler.jobs.map { |job| job[:kind] }).to eq([described_class::DELETE_KIND])
    end
  end

  # The handler reloads both ids out of the payload independently, so it checks
  # the pair itself rather than trusting whoever wrote the job.
  describe "#delete" do
    it "refuses a job pairing one community with the other's room" do
      result = service.delete(delete_job(community_id: alpha.id, room_id: beta_room.id))
      expect(result.status).to eq(:failed)
      expect(result.failures).to eq(["that room does not belong to this community"])
    end

    it "leaves the room row and its channel mappings standing" do
      service.delete(delete_job(community_id: alpha.id, room_id: beta_room.id))
      expect(models.room[beta_room.id]).not_to be_nil
      expect(models.room_channel.where(room_id: beta_room.id).count).to eq(2)
    end

    it "deletes nothing on the platform, even with the force list naming every channel" do
      service.delete(delete_job(community_id: alpha.id, room_id: beta_room.id,
                                force_channel_ids: beta_channel_ids))
      expect(adapter.deleted).to be_empty
    end

    it "refuses loudly rather than quietly" do
      service.delete(delete_job(community_id: alpha.id, room_id: beta_room.id))
      expect(logs.string).to match(/REFUSED a delete.*belongs to community #{beta.id}, not #{alpha.id}/)
    end

    it "audits the refusal against the community that asked" do
      service.delete(delete_job(community_id: alpha.id, room_id: beta_room.id))
      entry = audit.query(action: "room_delete_refused").first
      expect(entry.community).to eq(alpha.slug)
    end

    it "still deletes the room for the community that owns it" do
      result = service.delete(delete_job(community_id: beta.id, room_id: beta_room.id))
      expect(result.status).to eq(:deleted)
      expect(models.room[beta_room.id]).to be_nil
    end
  end
end
