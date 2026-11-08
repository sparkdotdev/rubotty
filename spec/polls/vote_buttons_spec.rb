# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Polls::VoteButtons do
  it "reads its own token back to the position that wrote it" do
    expect(described_class.position_for(described_class.token_for(3))).to eq(3)
  end

  # Any card may carry buttons of its own, and counting one of those as a vote
  # would put somebody on a poll they never answered.
  it "ignores a token nothing here wrote" do
    expect(described_class.position_for("rsvp:1")).to be_nil
    expect(described_class.position_for("poll-option")).to be_nil
    expect(described_class.position_for("poll-option:0")).to be_nil
    expect(described_class.position_for("poll-option:two")).to be_nil
    expect(described_class.position_for(nil)).to be_nil
  end

  # Telegram carries 64 bytes of callback data per button and refuses the whole
  # send over a longer one.
  it "writes a token every platform can carry" do
    expect(described_class.token_for(Rubotty::Polls::Poll::MAX_OPTIONS).bytesize)
      .to be <= Rubotty::Adapters::Telegram::Outbound::CALLBACK_DATA_LIMIT
  end
end
