# frozen_string_literal: true

require "spec_helper"
require "rubotty/scripting"

# The kept store's clash refusal must not describe another room's memo. A kept value is
# readable across the whole community, so the clash check has to ask community wide, or a
# keep from one room would leave another quietly reading a different value under the same
# name, and must not echo the bucket and key back, which would disclose guessed names.
RSpec.describe Rubotty::Scripting::Memory, "the kept clash refusal", :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:community) { models.community.first }
  let(:now) { Time.utc(2026, 7, 28, 12, 0) }

  subject(:memory) { described_class.new(models: models, logger: Rubotty::Log.null, clock: -> { now }) }

  let(:script) do
    models.community_script.create(
      community_id: community.id, name: "guard", kind: "processor", language: "lua",
      source: "return nil", compiled: "return nil", trigger_type: "always",
      enabled: false, consecutive_failures: 0, created_at: now, updated_at: now
    )
  end

  # A bucketed ttl memo in a room the caller below is not running in.
  before do
    memory.remember(script, "staff", bucket: "shared", key: "staff-secret", value: 1, ttl: 3600)
  end

  def keep_from_general
    memory.remember(script, "general", bucket: "shared", key: "staff-secret", value: 2, ttl: "never")
  end

  it "still refuses, because a kept value would be read everywhere" do
    ok, = keep_from_general

    expect(ok).to be(false)
  end

  it "does not name the bucket and key it clashed with" do
    _, why = keep_from_general

    expect(why).not_to include("staff-secret")
    expect(why).not_to include("shared")
  end

  it "does not say which room the memo is in" do
    _, why = keep_from_general

    expect(why).not_to include("staff")
  end

  it "still tells the caller what to do about it" do
    _, why = keep_from_general

    expect(why).to include("ttl")
    expect(why).to include("Forget it first")
  end

  # The name really is free when nothing holds it, so the refusal is about a
  # genuine clash rather than about bucketed keeps in general.
  it "keeps a name nothing else is using" do
    expect(memory.remember(script, "general", bucket: "shared", key: "unused", value: 2, ttl: "never"))
      .to be(true)
  end
end
