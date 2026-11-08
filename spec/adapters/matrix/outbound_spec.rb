# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Adapters::Matrix::Outbound do
  subject(:outbound) { described_class.new }

  let(:place) { endpoint("mx", adapter: :matrix, settings: { room_id: "!room:example.org" }) }

  # The bridge decides when the notice applies and builds the sentence; the
  # composer only renders it, in both the plain and the formatted body.
  describe "the thread notice" do
    it "renders the bridge-built notice as an italic line under the body" do
      msg = message(place, text: "yes", thread_notice: 'replied inside the thread "bar"')
      plain, html = outbound.compose(msg, place)
      expect(plain).to include(%(yes\n*replied inside the thread "bar"*))
      expect(html).to include(%(<i>replied inside the thread "bar"</i>))
    end

    it "renders nothing when the bridge set no notice, the default" do
      plain, html = outbound.compose(message(place, text: "yes"), place)
      expect(plain).not_to include("replied inside")
      expect(html).not_to include("replied inside")
    end
  end

  # The origin adapter sets forwarded_from; the composer only renders it, in
  # both the plain and the formatted body.
  describe "the forwarded-from note" do
    it "renders who a forwarded message came from as an italic line above the body" do
      msg = message(place, text: "yes", forwarded_from: author(display_name: "Grace"))
      plain, html = outbound.compose(msg, place)
      expect(plain).to include(%(*forwarded from Grace*\nyes))
      expect(html).to include(%(<i>forwarded from Grace</i>))
    end

    it "renders nothing when the message was not forwarded, the default" do
      plain, html = outbound.compose(message(place, text: "yes"), place)
      expect(plain).not_to include("forwarded from")
      expect(html).not_to include("forwarded from")
    end
  end

  describe "attachment links" do
    # SafeUrl.public("") used to hand the empty string back, so this rendered
    # as a link to nowhere instead of falling back to the marker text.
    it "falls back to a marker for a blank url rather than linking to an empty href" do
      blank = Rubotty::Core::Attachment.new(kind: :photo, url: "", filename: "pic.png")
      plain, html = outbound.compose(message(place, text: "look", attachments: [blank]), place)
      expect(plain).to include("[pic.png, could not be relayed]")
      expect(html).not_to include('href=""')
    end
  end

  # A resolved mention needs both a real pill in formatted_body and an
  # `m.mentions` entry: the pill is what a reader sees, `m.mentions` is what a
  # Matrix push rule actually keys a notification off.
  describe "m.mentions" do
    def body_with_mention
      rich("hi Ada", span(:mention, 3, 6, matrix_id_for_target: "@ada:example.org"))
    end

    it "names the target's Matrix id for a resolved mention span" do
      content = outbound.send_content(message(place, text: body_with_mention), place)
      expect(content["m.mentions"]).to eq({ "user_ids" => ["@ada:example.org"] })
    end

    it "carries the same pill and formatted_body anchor" do
      content = outbound.send_content(message(place, text: body_with_mention), place)
      expect(content["formatted_body"]).to include(%(<a href="https://matrix.to/#/@ada:example.org">Ada</a>))
    end

    it "omits m.mentions entirely when nothing resolved" do
      content = outbound.send_content(message(place, text: "hi Ada"), place)
      expect(content).not_to have_key("m.mentions")
    end

    it "de-duplicates the same person mentioned twice" do
      body = rich(
        "hi Ada, Ada",
        span(:mention, 3, 6, matrix_id_for_target: "@ada:example.org"),
        span(:mention, 8, 11, matrix_id_for_target: "@ada:example.org")
      )
      content = outbound.send_content(message(place, text: body), place)
      expect(content["m.mentions"]).to eq({ "user_ids" => ["@ada:example.org"] })
    end

    it "carries into an edit's outer content, alongside m.new_content" do
      content = outbound.edit_content(message(place, text: body_with_mention), place, "$target")
      expect(content["m.mentions"]).to eq({ "user_ids" => ["@ada:example.org"] })
      expect(content["m.new_content"]["m.mentions"]).to eq({ "user_ids" => ["@ada:example.org"] })
    end
  end
end
