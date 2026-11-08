# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Adapters::Stoat::Outbound do
  subject(:outbound) { described_class.new }

  let(:place) { endpoint("st", adapter: :stoat, settings: { channel_id: "CHAN01" }) }

  # Stoat content is Discord flavoured Markdown, but Stoat is its own identity
  # space: a mention the router resolved for it carries `stoat_id_for_target`,
  # not Discord's own key, and must render off that key rather than silently
  # staying inert.
  describe "a resolved mention" do
    it "renders as a real ping" do
      body = rich("poke Alex", span(:mention, 5, 9, stoat_id_for_target: "900"))
      expect(outbound.compose(message(place, text: body), place)).to include("<@900>")
    end

    it "leaves a Discord id keyed on the wrong platform inert" do
      body = rich("poke Alex", span(:mention, 5, 9, discord_id_for_target: "900"))
      expect(outbound.compose(message(place, text: body), place)).to include("Alex")
    end
  end

  # Stoat parses `<@id>`, `<%id>`, `@everyone` and `@online` straight out of raw
  # content server side, with no `allowed_mentions` style field to fall back on
  # the way Discord and Fluxer have, so a token nobody resolved must never
  # survive in a shape Stoat's own parser would honour.
  describe "a raw mention typed by hand" do
    let(:untrusted_id) { "01BX5ZZKBKACTAV9WEVGEMMVRZ" }
    let(:trusted_id) { "01ARZ3NDEKTSV4RRFFQ69G5FAV" }

    it "does not let an injected user token ping, even though it is Stoat shaped" do
      spoofed = message(place, text: "hey <@#{untrusted_id}> check this out")
      rendered = outbound.compose(spoofed, place)
      expect(rendered).not_to include("<@#{untrusted_id}>")
      expect(rendered).to include(untrusted_id)
    end

    it "keeps pinging an id the router actually resolved alongside an injected one" do
      body = rich(
        "poke Alex, not <@#{untrusted_id}>",
        span(:mention, 5, 9, stoat_id_for_target: trusted_id)
      )
      rendered = outbound.compose(message(place, text: body), place)
      expect(rendered).to include("<@#{trusted_id}>")
      expect(rendered).not_to include("<@#{untrusted_id}>")
    end

    it "does not let an injected role token ping" do
      spoofed = message(place, text: "attention <%#{untrusted_id}> please")
      expect(outbound.compose(spoofed, place)).not_to include("<%#{untrusted_id}>")
    end

    it "does not let a typed @everyone read as a mass mention" do
      expect(outbound.compose(message(place, text: "@everyone read this"), place)).not_to include("@everyone")
    end

    it "does not let a typed @online read as a mass mention" do
      expect(outbound.compose(message(place, text: "@online read this"), place)).not_to include("@online")
    end

    it "defuses an injected token inside a quoted parent, not only the body" do
      preview = Rubotty::Core::ReplyPreview.new(
        body: Rubotty::Core::RichText.plain("ping <@#{untrusted_id}> please"), label: "Grace"
      )
      quoted = message(place, text: "yes").with(reply_preview: preview)
      rendered = outbound.compose(quoted, place)
      expect(rendered).not_to include("<@#{untrusted_id}>")
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

  describe "attachment links" do
    # SafeUrl.public("") used to hand the empty string back, so this posted a
    # blank line instead of falling back to the marker text.
    it "falls back to a marker for a blank url rather than posting an empty link" do
      blank = Rubotty::Core::Attachment.new(kind: :photo, url: "", filename: "pic.png")
      rendered = outbound.compose(message(place, text: "look", attachments: [blank]), place)
      expect(rendered).to include("[pic.png, could not be relayed]")
    end
  end

  # Shortened rather than left for Stoat to cut off mid handle.
  describe "#masquerade_name" do
    it "passes a short label through untouched" do
      label = Rubotty::Core::SenderLabel.new(username: "ada", platform: "discord", display_name: "Ada L")
      msg = message(place, text: "hi").with(sender_label: label)
      expect(outbound.masquerade_name(msg)).to eq("Ada L [ada@discord]")
    end

    it "shortens a label over the cap by eating the display name, keeping the bracketed handle whole" do
      label = Rubotty::Core::SenderLabel.new(
        username: "owner_handle", platform: "discord", display_name: "River (Alex)"
      )
      msg = message(place, text: "hi").with(sender_label: label)
      name = outbound.masquerade_name(msg)
      expect(name).to end_with(" [owner_handle@discord]")
      expect(name.length).to eq(Rubotty::Adapters::Stoat::Outbound::MASQUERADE_NAME_LIMIT)
    end

    it "answers nil for a message with no sender label" do
      expect(outbound.masquerade_name(message(place, text: "hi"))).to be_nil
    end
  end
end
