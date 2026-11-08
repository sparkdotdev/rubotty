# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Adapters::Irc::Outbound do
  subject(:outbound) { described_class.new }

  let(:place) { endpoint("irc-general", adapter: :irc, settings: { channel: "#general" }) }

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
  end
end
