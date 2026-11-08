# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::ControlPlane::ChangeDetector, :control_plane do
  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:registry) { Rubotty::ControlPlane::Registry.build(models: models, accounts: {}) }

  subject(:detector) { described_class.new(models: models, registry: registry) }

  # A SEPARATE Models instance, so nothing here shares object state with the
  # detector's own view of the plane.
  def controls(clock: -> { Time.now })
    Rubotty::ControlPlane::FeatureControls.new(models: Rubotty::ControlPlane.models(db), clock: clock)
  end

  def external_write(feature: "faq", selector: "all", clock: -> { Time.now + 3600 })
    service = controls(clock: clock)
    service.enable(community: service.community!("sample"), selector: selector, feature: feature)
  end

  describe "#check" do
    # Build the baseline marker BEFORE the write, or a lazy subject would fold
    # the write into the baseline it reads afterwards.
    before { detector }

    it "does NOT reload when the marker has not advanced" do
      expect(registry).not_to receive(:reload)
      expect(detector.check).to be(false)
    end

    it "reloads exactly once when an external write advances the marker" do
      expect(registry).to receive(:reload).once.and_call_original
      external_write
      expect(detector.check).to be(true)
    end

    it "does not reload again on the next tick when nothing further changed" do
      external_write
      detector.check # consumes the change and re-baselines
      expect(registry).not_to receive(:reload)
      expect(detector.check).to be(false)
    end

    it "detects a same-second in-place insert, which a timestamp alone cannot" do
      # Colliding stamps still move the marker, because MAX(id) and the row
      # count ride alongside the timestamp. MariaDB's whole-second DATETIME
      # makes that collision ordinary, so nothing may lean on SQLite's
      # sub-second resolution.
      frozen = Time.now
      external_write(feature: "faq", clock: -> { frozen })
      detector.check
      external_write(feature: "word_filter", clock: -> { frozen })
      expect(detector.check).to be(true)
    end

    it "surfaces the reloaded feature state, so the pipeline would now run it" do
      service = controls(clock: -> { Time.now + 3600 })
      service.enable(community: service.community!("sample"), selector: "tg-general", feature: "word_filter")

      detector.check

      snap = registry.current
      channel = snap.channel_by_endpoint_key("tg-general")
      expect(snap.community("sample").feature_enabled?(channel, "word_filter")).to be(true)
    end

    # Naming the moved table and the resulting shape is what lets an operator
    # match a reload to the edit they just made.
    it "logs the reload, naming what moved and the shape of the new snapshot" do
      lines = []
      logger = instance_double(Logger)
      allow(logger).to receive(:info) { |&block| lines << block.call }
      allow(logger).to receive(:warn)
      logged = described_class.new(models: models, registry: registry, logger: logger)

      external_write
      logged.check

      expect(lines.join("\n")).to include("feature_settings").and include("room(s)").and include("endpoint(s)")
    end
  end

  # A marker watching feature_settings alone leaves a mapped channel, a started
  # community and an approved operator all invisible until the next restart.
  describe "the watched tables" do
    it "covers every control-plane table the SnapshotBuilder projects" do
      expect(detector.watched_tables).to include(
        :communities, :rooms, :channels, :room_channels, :feature_settings, :operators, :bridged_nicknames
      )
    end

    # A nickname is exactly the kind of write the dashboard's people page makes,
    # from a process with no registry of its own to reload: the only way it
    # ever reaches a running bot live is this detector noticing the
    # bridged_nicknames row moved.
    it "reloads when a nickname is set from another process" do
      detector
      community = models.community.where(slug: "sample").first
      person = models.person.where(community_id: community.id).order(:id).first
      nicknames = Rubotty::ControlPlane::BridgedNicknames.new(
        models: Rubotty::ControlPlane.models(db), clock: -> { Time.now + 3600 }
      )

      nicknames.set(community_id: community.id, person_id: person.id, adapter: "discord", nickname: "owner")

      expect(detector.check).to be(true)
    end

    it "reloads when a channel is mapped into a room, not only on a feature write" do
      baseline = detector.marker
      community = models.community.where(slug: "sample").first
      room = models.room.where(community_id: community.id).order(:id).last
      channel = models.channel.where(community_id: community.id).order(:id).first
      models.room_channel.create(room_id: room.id, channel_id: channel.id, created_at: Time.now + 3600)

      expect(detector.read_marker).not_to eq(baseline)
      expect(detector.check).to be(true)
    end

    it "reloads when a community's status changes from another process" do
      detector
      community = Rubotty::ControlPlane.models(db).community.where(slug: "sample").first
      community.update(status: "suspended", updated_at: Time.now + 3600)

      expect(detector.check).to be(true)
    end

    # Querying a table an unapplied migration has not created would raise on
    # every tick for the life of the process. The next boot picks it up.
    it "skips a table this database does not have, rather than failing forever" do
      allow(db).to receive(:table_exists?).and_call_original
      allow(db).to receive(:table_exists?).with(:operators).and_return(false)

      fresh = described_class.new(models: models, registry: registry)

      expect(fresh.watched_tables).not_to include(:operators)
      expect { fresh.check }.not_to raise_error
    end
  end

  describe "#read_marker" do
    it "moves after an external feature write" do
      baseline = detector.read_marker
      external_write
      expect(detector.read_marker).not_to eq(baseline)
    end

    # MAX(updated_at) comes back a TEXT string on SQLite and a Time elsewhere,
    # and a Time's #to_s carries a zone offset that moves with TZ while the
    # instant behind it does not. Normalising in Ruby keeps the comparison off
    # whichever backend the process happens to be talking to.
    it "normalises every stamp to a number, never a formatted timestamp" do
      detector.read_marker.each_value do |(count, max_id, stamp)|
        expect(count).to be_a(Integer)
        expect(max_id).to be_a(Integer)
        expect(stamp).to be_a(Float)
      end
    end

    it "is stable across repeated reads with no writes between them" do
      expect(detector.read_marker).to eq(detector.read_marker)
    end
  end

  describe ".for" do
    it "builds a detector on a Sequel-backed storage with a registry" do
      storage = Struct.new(:db).new(db)
      expect(described_class.for(storage: storage, registry: registry)).to be_a(described_class)
    end

    it "is a no-op (nil) on a backend with no database" do
      storage = Rubotty::Storage::Memory.new
      expect(described_class.for(storage: storage, registry: registry)).to be_nil
    end

    it "is a no-op (nil) when there is no registry to reload" do
      storage = Struct.new(:db).new(db)
      expect(described_class.for(storage: storage, registry: nil)).to be_nil
    end
  end

  # A subscriber of the one supervised ControlPlane::Watcher, so the process
  # runs a single control-plane loop rather than one per concern.
  describe "thread ownership" do
    it "owns no poll thread" do
      expect(detector).not_to respond_to(:start)
      expect(detector).not_to respond_to(:stop)
    end
  end
end
