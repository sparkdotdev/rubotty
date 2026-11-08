# frozen_string_literal: true

require "spec_helper"

# A 200 is not the same as the article. Consent walls, bot checks and error
# pages all answer 200 with a body, and that body is routinely in a different
# language from the page behind it, so believing the status code produces
# exactly the wrong annotation and posts it into a room.
RSpec.describe Rubotty::LinkAnnotation::Page do
  let(:asked) { URI("https://www.spiegel.de/politik/x") }

  def page(html, url: asked, requested: asked)
    described_class.new(url: url, requested: requested, html: html)
  end

  def article_html(body_text, lang: "de")
    "<html lang=\"#{lang}\"><head><title>Ein Bericht</title></head><body><p>#{body_text}</p></body></html>"
  end

  let(:prose) { "Der Bericht liegt vor und die Sprecherin hat sich dazu geaeussert. " * 12 }

  it "believes a page that stayed on the site and carries prose" do
    expect(page(article_html(prose))).to be_article
  end

  it "reads the visible text and leaves the scripts and styles out of it" do
    html = article_html("<script>var noise = 'hello';</script><style>p{color:red}</style>Echter Text")

    expect(page(html).text).to eq("Ein Bericht Echter Text")
    expect(page(html).text).not_to include("noise")
    expect(page(html).text).not_to include("color")
  end

  it "unescapes the entities the text pass would otherwise count as words" do
    expect(page(article_html("caf&#233; &amp; bar")).text).to end_with("café & bar")
  end

  # The sharpest of the three checks, and the one that catches the case seen for
  # real: a request for a translate front end that lands on consent.google.com.
  it "refuses a page that redirected off the site it was asked for" do
    landed = page(article_html(prose), url: URI("https://consent.example.net/?continue=x"))

    expect(landed).not_to be_article
    expect(landed.refusal).to include("consent.example.net")
  end

  it "accepts a redirect that stayed within the same site" do
    expect(page(article_html(prose), url: URI("https://amp.spiegel.de/politik/x"))).to be_article
  end

  it "refuses a body too short to be a page rather than a holding screen" do
    short = page(article_html("Weiterlesen"))

    expect(short).not_to be_article
    expect(short.refusal).to include("characters of text")
  end

  it "refuses a challenge screen even when it is long enough" do
    challenge = page("<html><head><title>Just a moment...</title></head><body><p>" \
                     "#{"Enable JavaScript and cookies to continue. " * 20}</p></body></html>")

    expect(challenge).not_to be_article
    expect(challenge.refusal).to eq("looks like an interstitial")
  end

  # Nearly every European news page says this somewhere in its banner, so
  # matching on it would refuse to annotate half the web.
  it "does not mistake a cookie banner on a real article for a challenge screen" do
    banner = article_html("We use cookies to improve your experience. #{prose}")

    expect(page(banner)).to be_article
  end
end
