# frozen_string_literal: true

require "spec_helper"

# Every member-controlled string on a script's payload is stripped of the styling sentinels.
# body.text and the reply excerpt were stripped; the author name, the attachment filename
# and the reply author were not, so a display name carrying a mention sentinel let any script
# that echoes the author ping a third party or apply formatting, attributed to the bot.
RSpec.describe "member-controlled strings reach a script without sentinels (#394)" do
  let(:open) { Rubotty::Scripting::Markup::OPEN }
  let(:close) { Rubotty::Scripting::Markup::CLOSE }

  # A display name that carries a real mention span: opener, the "@" style
  # code, the handle, closer.
  let(:forged_mention) { "Ada#{open}@@someone-else#{close}" }
  let(:forged_spoiler) { "secret#{open}!hidden#{close}.png" }

  let(:tg) { endpoint("tg") }

  let(:feature) do
    Rubotty::Features::Scripts.allocate
  end

  def event_for(message)
    context = Rubotty::Features::Context.new(message: message)
    feature.send(:event_for, context)
  end

  # The sentinels really do build spans, which is why an unstripped name is a
  # forgery rather than stray characters.
  it "confirms an unstripped name would render as a real mention span" do
    rich = Rubotty::Scripting::Markup.to_rich_text(forged_mention)

    expect(rich.spans.map(&:kind)).to include(:mention)
  end

  it "strips the sentinels from the author name" do
    message = message(tg, text: "hello", author: author(native_id: "1", first_name: forged_mention))

    expect(event_for(message).author_name).to eq("Ada@@someone-else")
  end

  it "strips the sentinels from an attachment filename" do
    attachment = Rubotty::Core::Attachment.new(kind: :photo, filename: forged_spoiler)
    message = message(tg, text: "look", attachments: [attachment])

    filenames = feature.send(:attachments_of, message).map { |a| a["filename"] }
    expect(filenames).to eq(["secret!hidden.png"])
  end

  it "strips the sentinels from the author of a replied-to message" do
    message = message(
      tg, text: "reply", reply_to: ref("tg", "900"),
      reply_preview: Rubotty::Core::ReplyPreview.new(
        author: author(native_id: "9", first_name: forged_mention),
        body: Rubotty::Core::RichText.plain("parent")
      )
    )

    expect(feature.send(:reply_to_of, message)["author"]).to eq("Ada@@someone-else")
  end

  # The text and the reply excerpt were already right; asserted here so a
  # later change cannot quietly drop them while the new ones stay.
  it "keeps stripping the message text and the reply excerpt" do
    message = message(
      tg, text: "hi#{open}bthere#{close}", reply_to: ref("tg", "900"),
      reply_preview: Rubotty::Core::ReplyPreview.new(
        author: author(native_id: "9"), body: Rubotty::Core::RichText.plain("par#{open}bent")
      )
    )

    expect(event_for(message).text).to eq("hibthere")
    expect(feature.send(:reply_to_of, message)["text"]).to eq("parbent")
  end
end
