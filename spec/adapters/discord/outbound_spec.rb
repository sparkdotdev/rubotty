# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Adapters::Discord::Outbound do
  subject(:outbound) { described_class.new }

  let(:place) { endpoint("dc", adapter: :discord, settings: { channel_id: "1" }) }
  let(:loud) do
    endpoint("dc-loud", adapter: :discord,
                        settings: { channel_id: "1", allow_mass_mentions: true })
  end

  describe "#allowed_mentions" do
    # A federated user can type mention tokens by hand; nothing the bridge did
    # not resolve itself may reach the whitelist.
    it "permits nothing when the body only contains injected raw tokens" do
      injected = message(place, text: "@everyone <@111222333> and <@&999>")
      mentions = outbound.allowed_mentions(injected, place)
      expect(mentions).to eq(parse: [], users: [], roles: [])
    end

    # A mention the router resolved carries :discord_id_for_target on its span,
    # the same annotation the renderer turns into <@id>.
    it "permits an id the router resolved, and nothing else" do
      body = rich(
        "poke <@111> Alex",
        span(:mention, 10, 14, discord_id_for_target: "900")
      )
      mentions = outbound.allowed_mentions(message(place, text: body), place)
      expect(mentions[:parse]).to eq([])
      expect(mentions[:users]).to eq(["900"])
      expect(mentions[:roles]).to eq([])
    end

    it "permits resolved users and roles together" do
      body = rich(
        "@everyone Alex Admins",
        span(:mention, 10, 14, discord_id_for_target: "900"),
        span(:mention, 15, 21, discord_role_id_for_target: "42")
      )
      mentions = outbound.allowed_mentions(message(place, text: body), place)
      expect(mentions).to eq(parse: [], users: ["900"], roles: ["42"])
    end

    # nil is Discord's "parse everything" default, the one deliberate escape hatch.
    it "returns nil only when the operator opts into mass mentions" do
      expect(outbound.allowed_mentions(message(place, text: "@everyone"), loud)).to be_nil
    end

    it "does not double count a mention resolved to the same id twice" do
      body = rich(
        "Alex Alex",
        span(:mention, 0, 4, discord_id_for_target: "900"),
        span(:mention, 5, 9, discord_id_for_target: "900")
      )
      expect(outbound.allowed_mentions(message(place, text: body), place)[:users]).to eq(["900"])
    end
  end

  # The origin adapter sets forwarded_from; the composer only renders it.
  describe "the forwarded-from note" do
    it "renders who a forwarded message came from as an italic line above the body" do
      msg = message(place, text: "yes", forwarded_from: author(display_name: "Grace"))
      rendered = outbound.compose(msg, place)
      expect(rendered).to include(%(*forwarded from Grace*\nyes))
    end

    it "renders nothing when the message was not forwarded, the default" do
      expect(outbound.compose(message(place, text: "yes"), place)).not_to include("forwarded from")
    end
  end

  # The bridge decides when the notice applies and builds the sentence; the
  # composer only renders it.
  describe "the thread notice" do
    it "renders the bridge-built notice as an italic line under the body" do
      msg = message(place, text: "yes", thread_notice: 'replied inside the thread "bar"')
      rendered = outbound.compose(msg, place)
      expect(rendered).to include(%(yes\n*replied inside the thread "bar"*))
    end

    it "renders nothing when the bridge set no notice, the default" do
      expect(outbound.compose(message(place, text: "yes"), place)).not_to include("replied inside")
    end
  end
end
