# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Adapters::Xmpp::Outbound do
  subject(:outbound) { described_class.new }

  let(:place) { endpoint("xmpp-general", adapter: :xmpp, settings: { room_jid: "room@conference.example.org" }) }

  # The bridge decides when the notice applies and builds the sentence; the
  # composer only renders it.
  describe "the thread notice" do
    it "renders the bridge-built notice as a line under the body" do
      msg = message(place, text: "yes", thread_notice: 'replied inside the thread "bar"')
      rendered = outbound.compose(msg, place)
      expect(rendered).to include(%(yes\nreplied inside the thread "bar"))
    end

    it "renders nothing when the bridge set no notice, the default" do
      expect(outbound.compose(message(place, text: "yes"), place)).not_to include("replied inside")
    end
  end

  # The origin adapter sets forwarded_from; the composer only renders it.
  describe "the forwarded-from note" do
    it "renders who a forwarded message came from as a line above the body" do
      msg = message(place, text: "yes", forwarded_from: author(display_name: "Grace"))
      rendered = outbound.compose(msg, place)
      expect(rendered).to include(%(forwarded from Grace\nyes))
    end

    it "renders nothing when the message was not forwarded, the default" do
      expect(outbound.compose(message(place, text: "yes"), place)).not_to include("forwarded from")
    end
  end

  describe "attachment links" do
    # SafeUrl.public("") used to hand the empty string back, so this posted a
    # blank line instead of falling back to the marker text.
    it "falls back to a marker for a blank url rather than posting an empty link" do
      blank = Rubotty::Core::Attachment.new(kind: :photo, url: "", filename: "pic.png")
      rendered = outbound.compose(message(place, text: "look", attachments: [blank]), place)
      expect(rendered).to include("[pic.png, could not be relayed]")
    end

    # The adapter is the one that runs XEP-0363 and hands back +uploaded+;
    # composing with it is all Outbound itself does.
    it "prints the uploaded url in place of the marker for an attachment that is in uploaded" do
      leaky = Rubotty::Core::Attachment.new(
        kind: :photo, url: "https://api.telegram.org/file/bot123:AAsecret/a.jpg", filename: "a.jpg"
      )
      rendered = outbound.compose(
        message(place, text: "look", attachments: [leaky]), place,
        uploaded: { leaky => "https://upload.example.org/abc/a.jpg" }
      )
      expect(rendered).to include("https://upload.example.org/abc/a.jpg")
      expect(rendered).not_to include("AAsecret")
      expect(rendered).not_to include("could not be relayed")
    end

    it "prefers a public source url over an uploaded one, so nothing is fetched needlessly" do
      cdn = Rubotty::Core::Attachment.new(kind: :photo, url: "https://cdn.example/a.png", filename: "a.png")
      rendered = outbound.compose(
        message(place, text: "look", attachments: [cdn]), place,
        uploaded: { cdn => "https://upload.example.org/should-not-appear.png" }
      )
      expect(rendered).to include("https://cdn.example/a.png")
      expect(rendered).not_to include("should-not-appear")
    end
  end

  describe "unrelayed attachments" do
    it "drops an attachment from the unrelayed list once uploaded holds a url for it" do
      leaky = Rubotty::Core::Attachment.new(
        kind: :photo, url: "https://api.telegram.org/file/bot123:AAsecret/a.jpg", filename: "a.jpg"
      )
      msg = message(place, text: "look", attachments: [leaky])
      expect(outbound.unrelayed_attachments(msg)).to eq([leaky])
      expect(outbound.unrelayed_attachments(msg, uploaded: { leaky => "https://upload.example.org/a.jpg" }))
        .to eq([])
    end
  end
end
