# frozen_string_literal: true

require "spec_helper"
require "json"

# Records every delivered message, standing in for a real adapter. Needs its
# own adapter_name per instance, unlike Fakes::RecordingAdapter, since
# UploadAnnouncer resolves a room's endpoints off the seeded fixture's real
# telegram/discord adapters.
class UploadAnnouncerFakeAdapter < Rubotty::Adapters::Base
  def initialize(name)
    @name_sym = name
    super(account: name.to_s, settings: {}, dispatcher: nil, logger: Rubotty::Log.null)
    @delivered = []
  end

  attr_reader :delivered

  define_method(:adapter_name) { @name_sym }

  def capabilities = Rubotty::Adapters::Capabilities.new

  def own_account_id = "#{@name_sym}-bot"

  def start = self
  def stop = self
  def running? = true

  def deliver(message, endpoint)
    @delivered << [endpoint.id, message]
    Rubotty::Core::DeliveryReceipt.new(endpoint_id: endpoint.id, native_id: "n#{@delivered.size}")
  end
end

# Posting a finished /upload back into the room it was asked for, over the real
# control-plane models with only the adapters faked. The batch's files travel
# as real attachments now, so the target's own album logic sees them the same
# way it would any other multi-attachment message.
RSpec.describe Rubotty::ControlPlane::UploadAnnouncer, :control_plane do
  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:registry) { Rubotty::ControlPlane::Registry.new(models: models) }
  let(:community) { models.community.where(slug: "sample").first }

  let(:tg) { UploadAnnouncerFakeAdapter.new(:telegram) }
  let(:dc) { UploadAnnouncerFakeAdapter.new(:discord) }
  let(:adapter_map) { { [:telegram, "telegram"] => tg, [:discord, "discord"] => dc } }

  let(:now) { Time.now }

  def make_file(filename: "clip.mp4", content_type: "video/mp4", byte_size: 5_242_880)
    models.rehosted_file.create(
      community_id: community.id, room_key: "general", token_hash: SecureRandom.hex(32),
      object_key: SecureRandom.hex(16), iv: "iv", auth_tag: "tag", filename: filename,
      content_type: content_type, byte_size: byte_size, sealed_bytes: byte_size + 20, source: "upload",
      created_at: now, expires_at: now + 86_400
    )
  end

  def stored_for(file, secret: SecureRandom.uuid)
    Rubotty::ControlPlane::RehostedFiles::Stored.new(file: file, secret: secret)
  end

  def make_ticket(pending: [], failed: [], requested_by_label: "Ada")
    models.rehosted_upload_ticket.create(
      community_id: community.id, room_key: "general", token_hash: SecureRandom.hex(32),
      endpoint_key: "tg-general", requested_by_label: requested_by_label,
      created_at: now, expires_at: now + 3600,
      pending_files: JSON.generate(pending.map { |stored| { "secret" => stored.secret, "file_id" => stored.file.id } }),
      pending_failed: JSON.generate(failed)
    )
  end

  subject(:announcer) do
    described_class.new(registry: registry, models: models, adapters: adapter_map, logger: Rubotty::Log.null,
                        env: { "RUBOTTY_FILE_STORAGE_URL" => "https://rubotty.test" })
  end

  describe "#deliver" do
    it "posts a message carrying a real attachment, with a download url ending in the file's own extension" do
      stored = stored_for(make_file, secret: "900931a2-d3a8-4b45-8b5f-173f4e79ca4c")
      ticket = make_ticket(pending: [stored])

      announcer.deliver(ticket)

      message = tg.delivered.first.last
      expect(message.body.text).to eq("Ada uploaded clip.mp4 (5.0 MB).")
      expect(message.attachments.size).to eq(1)
      expect(message.attachments.first.kind).to eq(:video)
      expect(message.attachments.first.url).to eq(
        "https://rubotty.test/filestorage/900931a2-d3a8-4b45-8b5f-173f4e79ca4c.mp4"
      )
    end

    it "picks the extension off the content type when the filename has none to reuse" do
      stored = stored_for(make_file(filename: "clip", content_type: "video/mp4"))
      ticket = make_ticket(pending: [stored])

      announcer.deliver(ticket)

      expect(tg.delivered.first.last.attachments.first.url).to end_with(".mp4")
    end

    it "carries every file in the batch as its own attachment, in selection order" do
      first = stored_for(make_file(filename: "one.jpg", content_type: "image/jpeg"))
      second = stored_for(make_file(filename: "two.jpg", content_type: "image/jpeg"))
      ticket = make_ticket(pending: [first, second])

      announcer.deliver(ticket)

      attachments = tg.delivered.first.last.attachments
      expect(attachments.map(&:filename)).to eq(%w[one.jpg two.jpg])
      expect(attachments).to all(have_attributes(kind: :photo))
    end

    it "names what could not be stored in the caption, alongside what was" do
      stored = stored_for(make_file)
      ticket = make_ticket(pending: [stored], failed: %w[bad.pdf huge.mp4])

      announcer.deliver(ticket)

      expect(tg.delivered.first.last.body.text).to eq(
        "Ada uploaded clip.mp4 (5.0 MB). 2 more could not be stored and were left out: bad.pdf, huge.mp4."
      )
    end

    it "posts to every endpoint in the room the ticket named" do
      ticket = make_ticket(pending: [stored_for(make_file)])

      announcer.deliver(ticket)

      expect(dc.delivered.map(&:first)).to eq(["dc-general"])
    end

    it "clears the pending files and failures once posted, so the keys do not linger" do
      ticket = make_ticket(pending: [stored_for(make_file)], failed: %w[bad.pdf])

      announcer.deliver(ticket)

      expect(ticket.reload.pending_files).to eq("[]")
      expect(ticket.pending_failed).to eq("[]")
    end

    it "clears the hand-off even when nothing could be posted" do
      ticket = make_ticket(pending: [stored_for(make_file)])
      models.room_channel.where(room_id: models.room.where(community_id: community.id, room_key: "general").first.id)
                         .delete
      models.room.where(community_id: community.id, room_key: "general").delete

      expect { announcer.deliver(ticket) }.not_to raise_error
      expect(ticket.reload.pending_files).to eq("[]")
    end

    it "is a no-op for a ticket with nothing pending" do
      ticket = make_ticket

      expect { announcer.deliver(ticket) }.not_to raise_error
      expect(tg.delivered).to be_empty
    end

    it "drops a pending file the daily sweep has already reclaimed rather than raising" do
      stored = stored_for(make_file)
      ticket = make_ticket(pending: [stored])
      stored.file.delete

      expect { announcer.deliver(ticket) }.not_to raise_error
      expect(tg.delivered).to be_empty
    end

    it "never raises when an adapter's delivery fails" do
      ticket = make_ticket(pending: [stored_for(make_file)])
      allow(tg).to receive(:deliver).and_raise(Rubotty::AdapterError.new("nope", adapter: :telegram))

      expect { announcer.deliver(ticket) }.not_to raise_error
      expect(dc.delivered).not_to be_empty
      expect(ticket.reload.pending_files).to eq("[]")
    end
  end

  describe "#announce" do
    it "delivers directly with no scheduler" do
      stored = stored_for(make_file, secret: "abc12345-0000-0000-0000-000000000000")
      ticket = make_ticket

      announcer.announce(ticket: ticket, files: [stored])

      expect(tg.delivered.first.last.attachments.first.url).to include(
        "filestorage/abc12345-0000-0000-0000-000000000000.mp4"
      )
    end

    it "does nothing for a nil ticket or an empty batch" do
      expect { announcer.announce(ticket: nil, files: [stored_for(make_file)]) }.not_to raise_error
      expect { announcer.announce(ticket: make_ticket, files: []) }.not_to raise_error
      expect(tg.delivered).to be_empty
    end
  end

  describe "routed through a durable job" do
    let(:scheduler) do
      Rubotty::Core::DurableScheduler.new(store: Rubotty::Core::DurableSchedulerStore::Sequel.new(db: db),
                                          session_id: "spec")
    end

    it "enqueues rather than posting immediately, then posts once the job runs" do
      stored = stored_for(make_file, secret: "abc12345-0000-0000-0000-000000000000")
      ticket = make_ticket
      writer = described_class.new(models: models, scheduler: scheduler)
      described_class.new(registry: registry, models: models, adapters: adapter_map, scheduler: scheduler,
                          env: { "RUBOTTY_FILE_STORAGE_URL" => "https://rubotty.test" })

      writer.announce(ticket: ticket, files: [stored])
      expect(tg.delivered).to be_empty

      scheduler.run_due
      expect(tg.delivered.first.last.attachments.first.url).to include(
        "filestorage/abc12345-0000-0000-0000-000000000000.mp4"
      )
    end

    it "persists the failed filenames until the job runs, then folds them into the caption" do
      stored = stored_for(make_file)
      ticket = make_ticket
      writer = described_class.new(models: models, scheduler: scheduler)
      described_class.new(registry: registry, models: models, adapters: adapter_map, scheduler: scheduler,
                          env: { "RUBOTTY_FILE_STORAGE_URL" => "https://rubotty.test" })

      writer.announce(ticket: ticket, files: [stored], failed: ["bad.pdf"])
      expect(JSON.parse(ticket.reload.pending_failed)).to eq(["bad.pdf"])

      scheduler.run_due
      expect(tg.delivered.first.last.body.text).to include("bad.pdf")
      expect(ticket.reload.pending_failed).to eq("[]")
    end
  end
end
