# frozen_string_literal: true

require "spec_helper"

# The normalized native-event-change value object: Discord's
# GUILD_SCHEDULED_EVENT_CREATE/UPDATE/DELETE translated so a later consumer never
# has to know discordrb's event shape. Built from a gateway dispatch in
# Adapters::Discord::Adapter#handle_native_scheduled_event.
RSpec.describe Rubotty::Events::NativeEventChange do
  subject(:change) do
    described_class.new(
      adapter: :discord, account: "dc", action: :created, native_id: 123, guild_id: 456,
      title: "Raid night", starts_at: Time.utc(2026, 8, 1, 20, 0, 0), status: :scheduled,
      raw: { "id" => "123" }
    )
  end

  it "reads back what it was built with, coercing ids to strings" do
    expect(change.adapter).to eq(:discord)
    expect(change.account).to eq("dc")
    expect(change.native_id).to eq("123")
    expect(change.guild_id).to eq("456")
    expect(change.title).to eq("Raid night")
    expect(change.raw).to eq({ "id" => "123" })
  end

  it "answers only its own action predicate true" do
    expect(change.created?).to be(true)
    expect(change.updated?).to be(false)
    expect(change.deleted?).to be(false)
  end

  it "is frozen, since it is only ever a fact reported once" do
    expect(change).to be_frozen
  end

  it "is nil safe for the optional identifying fields" do
    bare = described_class.new(adapter: :discord, account: "dc", action: :deleted)
    expect(bare.native_id).to be_nil
    expect(bare.guild_id).to be_nil
  end
end
