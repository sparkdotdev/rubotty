# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Adapters::Matrix::Html do
  subject(:renderer) { described_class.new }

  it "renders plain text unchanged, escaped, with newlines as <br/>" do
    expect(renderer.render(rich("a < b\nc"))).to eq("a &lt; b<br/>c")
  end

  it "renders a mention as a matrix.to pill only once the target's Matrix id is known" do
    known = renderer.render(rich("Ada", span(:mention, 0, 3, matrix_id_for_target: "@ada:example.org")))
    unknown = renderer.render(rich("ada@matrix", span(:mention, 0, 10, username: "ada")))
    expect(known).to eq(%(<a href="https://matrix.to/#/@ada:example.org">Ada</a>))
    expect(unknown).to eq("ada@matrix")
  end

  it "keeps other formatting intact around a rendered mention" do
    body = rich("hi Ada now", span(:mention, 3, 6, matrix_id_for_target: "@ada:example.org"),
                span(:bold, 7, 10))
    expect(renderer.render(body)).to eq(%(hi <a href="https://matrix.to/#/@ada:example.org">Ada</a> <b>now</b>))
  end

  it "renders Matrix's own overrides: spoiler and strikethrough" do
    expect(renderer.render(rich("shh", span(:spoiler, 0, 3)))).to eq(%(<span data-mx-spoiler>shh</span>))
    expect(renderer.render(rich("old", span(:strikethrough, 0, 3)))).to eq("<del>old</del>")
  end

  # Link handling is inherited straight from TelegramHtml, brackets and all.
  it "renders a self labelled link as a bare URL, with no anchor" do
    url = "https://flighty.app/f/abc123"
    result = renderer.render(rich(url, span(:link, 0, url.length, url: url)))
    expect(result).to eq(url)
  end
end
