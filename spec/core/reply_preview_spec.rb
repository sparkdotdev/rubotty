# frozen_string_literal: true

require "spec_helper"

# The excerpt is captured at PARSE time from the payload the platform already
# gave us, never stored in the message map or refetched later.
RSpec.describe "reply quoting" do
  let(:tg) { endpoint("tg") }
  let(:dc) { endpoint("dc") }
  let(:storage) { Rubotty::Storage::Memory.new }
  let(:adapter) { Fakes::RecordingAdapter.new }

  def build_router(chars: 100, lines: 2, template: nil)
    Rubotty::Core::Router.new(
      topology: topology(room("r", tg, dc)),
      adapters: Hash.new(adapter),
      storage: storage,
      loop_guard: Rubotty::Core::LoopGuard.new(storage: storage),
      logger: Rubotty::Log.null,
      default_display_name: Rubotty::Core::DisplayName.new(template: template),
      reply_preview_chars: chars,
      reply_preview_lines: lines
    )
  end

  def reply_with(preview, chars: 100, lines: 2, template: nil)
    build_router(chars: chars, lines: lines, template: template).handle(
      message(tg, text: "my reply", reply_to: ref("tg", "900"), reply_preview: preview)
    )
    adapter.delivered.last.last
  end

  let(:parent_author) { author(first_name: "Grace", username: "grace") }

  it "carries the quoted parent through to the target" do
    preview = Rubotty::Core::ReplyPreview.new(
      author: parent_author, body: Rubotty::Core::RichText.plain("the original message")
    )
    delivered = reply_with(preview)
    expect(delivered.reply_preview.body.text).to eq("the original message")
  end

  # Only the router knows which display name template applies, so it renders the
  # label rather than the adapter.
  it "labels the quoted parent with a concise display name by default" do
    preview = Rubotty::Core::ReplyPreview.new(
      author: parent_author, body: Rubotty::Core::RichText.plain("hi")
    )
    expect(reply_with(preview).reply_preview.label).to eq("Grace")
  end

  it "renders the parent author with a configured template when one is set" do
    preview = Rubotty::Core::ReplyPreview.new(
      author: parent_author, body: Rubotty::Core::RichText.plain("hi")
    )
    label = reply_with(preview, template: "{first_name} ({username})").reply_preview.label
    expect(label).to eq("Grace (grace)")
  end

  it "labels a parent author who has no username with their name" do
    preview = Rubotty::Core::ReplyPreview.new(
      author: author(first_name: "Ada", username: nil),
      body: Rubotty::Core::RichText.plain("hi")
    )
    expect(reply_with(preview).reply_preview.label).to eq("Ada")
  end

  it "truncates a long parent to the configured budget" do
    preview = Rubotty::Core::ReplyPreview.new(
      author: parent_author, body: Rubotty::Core::RichText.plain("x" * 500)
    )
    expect(reply_with(preview, chars: 20).reply_preview.body.text.length).to be <= 20
  end

  it "keeps only the configured number of lines" do
    preview = Rubotty::Core::ReplyPreview.new(
      author: parent_author, body: Rubotty::Core::RichText.plain("one\ntwo\nthree\nfour")
    )
    expect(reply_with(preview, lines: 2).reply_preview.body.text).to eq("one\ntwo")
  end

  # An operator who would rather not repeat message text onto another platform
  # can turn quoting off entirely.
  it "omits the quote completely when the budget is zero" do
    preview = Rubotty::Core::ReplyPreview.new(
      author: parent_author, body: Rubotty::Core::RichText.plain("secret")
    )
    expect(reply_with(preview, chars: 0).reply_preview).to be_nil
  end

  it "leaves reply_preview nil when the message was not a reply" do
    build_router.handle(message(tg, text: "hello"))
    expect(adapter.delivered.last.last.reply_preview).to be_nil
  end

  it "preserves the parent's formatting inside the quote" do
    body = rich("bold word", span(:bold, 0, 4))
    preview = Rubotty::Core::ReplyPreview.new(author: parent_author, body: body)
    delivered = reply_with(preview)
    expect(delivered.reply_preview.body.spans.map(&:kind)).to eq([:bold])
  end
end

RSpec.describe Rubotty::Core::RichText, "#first_lines" do
  it "keeps the requested number of lines" do
    expect(described_class.plain("a\nb\nc").first_lines(2).text).to eq("a\nb")
  end

  it "returns the whole text when there are fewer lines than requested" do
    expect(described_class.plain("only one").first_lines(3).text).to eq("only one")
  end

  it "returns the whole text when the count is zero or nil" do
    expect(described_class.plain("a\nb").first_lines(0).text).to eq("a\nb")
    expect(described_class.plain("a\nb").first_lines(nil).text).to eq("a\nb")
  end

  it "trims spans to the retained region" do
    text = described_class.new("first\nsecond", [Rubotty::Core::Span.new(kind: :bold, begin_index: 0, end_index: 12)])
    expect(text.first_lines(1).spans.first.end_index).to eq(5)
  end
end
