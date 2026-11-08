# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::ControlPlane::ScriptRecurrenceWatch, :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }
  let(:sync_calls) { [] }
  let(:sync) { -> { sync_calls << true } }

  subject(:watch) { described_class.new(models: models, sync: sync) }

  # A SEPARATE Models instance, so nothing here shares object state with the
  # watch's own view of the plane.
  def scripts
    Rubotty::ControlPlane::Scripts.new(models: Rubotty::ControlPlane.models(models.db))
  end

  def write_script(name: "digest")
    scripts.save(community: community, name: name, kind: "processor",
                 source: 'return { action = "allow" }', trigger_type: "recurring",
                 trigger_config: { "every" => "day", "at" => "09:00" })
  end

  describe "#check" do
    # Build the baseline marker BEFORE the write, or a lazy subject would fold
    # the write into the baseline it reads afterwards.
    before { watch }

    it "does NOT resync when community_scripts has not moved" do
      expect(watch.check).to be(false)
      expect(sync_calls).to be_empty
    end

    it "resyncs exactly once when a script is added" do
      write_script
      expect(watch.check).to be(true)
      expect(sync_calls.length).to eq(1)
    end

    it "resyncs again when an existing script is edited" do
      row = write_script
      watch.check
      row.update(trigger_config: Rubotty::ControlPlane::Models.dump_json(
        { "every" => "day", "at" => "10:00" }
      ), updated_at: Time.now + 3600)

      expect(watch.check).to be(true)
      expect(sync_calls.length).to eq(2)
    end

    it "does not resync again on the next check when nothing further changed" do
      write_script
      watch.check
      expect(watch.check).to be(false)
      expect(sync_calls.length).to eq(1)
    end
  end
end
