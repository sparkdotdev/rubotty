# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Adapters::Fluxer::Outbound do
  subject(:outbound) { described_class.new }

  let(:place) { endpoint("fx", adapter: :fluxer, settings: { channel_id: "1" }) }

  # Fluxer content is Discord flavoured Markdown, but Fluxer is its own
  # identity space: a mention the router resolved for it carries
  # `fluxer_id_for_target`, not Discord's own key, and must render and
  # whitelist off that key rather than silently staying inert.
  describe "a resolved mention" do
    it "renders as a real ping" do
      body = rich("poke Alex", span(:mention, 5, 9, fluxer_id_for_target: "900"))
      expect(outbound.compose(message(place, text: body), place)).to include("<@900>")
    end

    it "permits the resolved id, and nothing else" do
      body = rich(
        "poke <@111> Alex",
        span(:mention, 10, 14, fluxer_id_for_target: "900")
      )
      mentions = outbound.allowed_mentions(message(place, text: body), place)
      expect(mentions[:parse]).to eq([])
      expect(mentions[:users]).to eq(["900"])
      expect(mentions[:roles]).to eq([])
    end

    it "leaves a Discord id keyed on the wrong platform inert" do
      body = rich("poke Alex", span(:mention, 5, 9, discord_id_for_target: "900"))
      expect(outbound.compose(message(place, text: body), place)).to include("Alex")
      expect(outbound.allowed_mentions(message(place, text: body), place)[:users]).to eq([])
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

  describe "the attachment note" do
    # An attachment with no url never reaches the adapter's upload path, so
    # the text carries a bare label rather than an empty or broken link.
    it "marks an attachment with no resolvable url, rather than posting an empty link" do
      blank = Rubotty::Core::Attachment.new(kind: :photo, url: "", filename: "pic.png")
      rendered = outbound.compose(message(place, text: "look", attachments: [blank]), place)
      expect(rendered).to include("[pic.png]")
    end

    # A resolvable attachment is uploaded as a real file by the adapter, so
    # the composed text says nothing about it at all.
    it "says nothing about an attachment with a resolvable url" do
      photo = Rubotty::Core::Attachment.new(kind: :photo, url: "https://cdn.example/a.png", filename: "a.png")
      rendered = outbound.compose(message(place, text: "look", attachments: [photo]), place)
      expect(rendered).not_to include("a.png")
      expect(rendered).not_to include("https://cdn.example/a.png")
    end
  end
end
