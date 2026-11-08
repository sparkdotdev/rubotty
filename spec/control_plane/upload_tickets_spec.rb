# frozen_string_literal: true

require "spec_helper"

# A ticket is a write capability into somebody else's community, bounded by three
# things: the raw token is never stored, a second use loses, and it dies on its own
# whether or not anybody uses it.
RSpec.describe Rubotty::ControlPlane::UploadTickets, :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }

  let(:now) { Time.new(2026, 7, 30, 12, 0, 0) }
  let(:tickets) { described_class.new(models: models, clock: -> { now }) }

  def issue(**rest)
    tickets.issue(community_id: community.id, room_key: "general", endpoint_key: "tg-general",
                  adapter: :telegram, native_id: "55", label: "Ada", **rest)
  end

  it "stores only a digest of the token, never the token" do
    issued = issue
    row = models.rehosted_upload_ticket[issued.ticket.id]

    expect(row.token_hash).to eq(Rubotty::Storage::ObjectStore.digest(issued.token))
    expect(row.values.values.map(&:to_s)).not_to include(issued.token)
  end

  it "authenticates the token it minted and nothing else" do
    issued = issue

    expect(tickets.authenticate(token: issued.token)&.id).to eq(issued.ticket.id)
    expect(tickets.authenticate(token: "not-a-real-token")).to be_nil
    expect(tickets.authenticate(token: nil)).to be_nil
  end

  # The room comes from the ticket, so the browser has no field it could change to
  # redirect the result into a room it was never granted.
  it "carries the room and the endpoint the command was typed in" do
    issued = issue

    expect(issued.ticket.room_key).to eq("general")
    expect(issued.ticket.endpoint_key).to eq("tg-general")
  end

  describe "single use" do
    it "spends on the first claim and refuses the second" do
      issued = issue

      expect(tickets.claim(token: issued.token)&.id).to eq(issued.ticket.id)
      expect(tickets.claim(token: issued.token)).to be_nil
    end

    it "stops authenticating once it has been spent" do
      issued = issue
      tickets.claim(token: issued.token)

      expect(tickets.authenticate(token: issued.token)).to be_nil
    end

    # used_at is written by an UPDATE whose WHERE still carries the liveness conditions,
    # so exactly one of two racing posts can win it.
    it "marks the row used rather than only remembering in this process" do
      issued = issue
      tickets.claim(token: issued.token)

      expect(models.rehosted_upload_ticket[issued.ticket.id].used_at).not_to be_nil
    end
  end

  describe "expiry" do
    it "stops working once it lapses, used or not" do
      issued = issue(ttl_seconds: 600)
      later = described_class.new(models: models, clock: -> { now + 601 })

      expect(later.authenticate(token: issued.token)).to be_nil
      expect(later.claim(token: issued.token)).to be_nil
    end

    it "will not mint a ticket shorter than a minute, however small a lifetime is asked for" do
      issued = issue(ttl_seconds: 1)

      expect(issued.ticket.expires_at.to_time).to be_within(1).of(now + 60)
    end

    it "sweeps lapsed rows away" do
      issue(ttl_seconds: 600)
      later = described_class.new(models: models, clock: -> { now + 601 })

      expect(later.expire).to eq(1)
      expect(models.rehosted_upload_ticket.count).to be_zero
    end

    it "leaves a live ticket where it is" do
      issue(ttl_seconds: 600)

      expect(tickets.expire).to be_zero
    end
  end
end
