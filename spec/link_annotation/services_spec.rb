# frozen_string_literal: true

require "spec_helper"

# The one bug class this module exists to make impossible: a link that looks
# completely right and does not work. A URL in a query parameter must be
# percent encoded or it truncates at the target's own first ampersand; a URL
# in a path must not be encoded or the front end looks up an address nobody published.
RSpec.describe Rubotty::LinkAnnotation::Services do
  let(:article) { URI("https://www.spiegel.de/politik/x-a-1.html?page=2") }

  def build(key, source: "de", target: "en", uri: article)
    described_class.build(described_class.find(key), uri: uri, source: source, target: target)
  end

  describe "the shipped front ends" do
    it "hands Google the target as a percent-encoded query parameter" do
      expect(build("google")).to eq(
        "https://translate.google.com/translate?sl=de&tl=en&u=" \
        "https%3A%2F%2Fwww.spiegel.de%2Fpolitik%2Fx-a-1.html%3Fpage%3D2"
      )
    end

    # The target's own "?page=2" survives the crossing. Dropping it, or letting
    # it collide with the front end's parameters, lands the reader on page one.
    it "hands Google's proxy the path raw and keeps the article's own parameters" do
      expect(build("google_proxy")).to eq(
        "https://www-spiegel-de.translate.goog/politik/x-a-1.html?page=2" \
        "&_x_tr_sl=de&_x_tr_tl=en&_x_tr_hl=en"
      )
    end

    it "hands Yandex the target encoded and the pair as one parameter" do
      expect(build("yandex")).to eq(
        "https://translate.yandex.com/translate?url=" \
        "https%3A%2F%2Fwww.spiegel.de%2Fpolitik%2Fx-a-1.html%3Fpage%3D2&lang=de-en"
      )
    end

    it "offers Google alone until an operator asks for more" do
      expect(described_class::DEFAULT_KEYS).to eq(%w[google])
    end
  end

  describe "an unknown source language" do
    # Measured, not assumed: asked for "auto-en" Yandex answers with a proxy URL
    # of "en-ru" and serves the article in Russian.
    it "leaves Yandex out rather than letting it decide for itself" do
      expect(build("yandex", source: nil)).to be_nil
    end

    it "lets Google detect, which it does correctly" do
      expect(build("google", source: nil)).to include("sl=auto")
    end
  end

  describe ".proxy_host" do
    # Verified against the live proxy: www.n-tv.de is served at
    # www-n--tv-de.translate.goog, and the single-hyphen spelling answers 404.
    it "doubles a hyphen already in the host before turning dots into hyphens" do
      expect(described_class.proxy_host("www.n-tv.de")).to eq("www-n--tv-de")
      expect(described_class.proxy_host("www.spiegel.de")).to eq("www-spiegel-de")
    end

    it "refuses an internationalised host, where the escape is ambiguous" do
      expect(described_class.proxy_host("xn--80asehdb.xn--p1ai")).to be_nil
    end
  end

  it "skips the proxy for a host it cannot spell, and still builds the others" do
    idn = URI("https://xn--80asehdb.xn--p1ai/a")

    expect(build("google_proxy", source: "ru", uri: idn)).to be_nil
    expect(build("google", source: "ru", uri: idn)).to include("xn--80asehdb")
  end

  describe ".resolve" do
    it "keeps the operator's order and drops a name it does not know" do
      services = described_class.resolve(%w[yandex nope google])

      expect(services.map(&:key)).to eq(%w[yandex google])
    end
  end

  it "carries a kind, so the archive half of the issue can join this catalog" do
    expect(described_class::ALL.values).to all(be_translation)
  end
end
