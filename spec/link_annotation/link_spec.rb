# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::LinkAnnotation::Link do
  describe ".clean" do
    it "keeps an ordinary article URL as it was typed" do
      uri = described_class.clean("https://www.lemonde.fr/politique/article/2026/01/02/x_123.html")

      expect(uri.to_s).to eq("https://www.lemonde.fr/politique/article/2026/01/02/x_123.html")
    end

    it "strips campaign and click parameters, whole families included" do
      uri = described_class.clean(
        "https://example.com/a?utm_source=newsletter&utm_campaign=jan&fbclid=abc&gclid=def"
      )

      expect(uri.to_s).to eq("https://example.com/a")
    end

    it "keeps the parameters that name the page rather than the visitor" do
      uri = described_class.clean("https://example.com/a?page=3&id=77&utm_medium=email")

      expect(uri.to_s).to eq("https://example.com/a?page=3&id=77")
    end

    # "s", "ref" and "source" are real, load bearing parameters on somebody's
    # site, and a URL stripped down to the wrong page is worse than a tracker.
    it "leaves the short ambiguous parameter names alone" do
      uri = described_class.clean("https://example.com/a?s=query&ref=xyz&source=rss")

      expect(uri.to_s).to eq("https://example.com/a?s=query&ref=xyz&source=rss")
    end

    it "drops the fragment, which never reaches the server and often carries an id" do
      uri = described_class.clean("https://example.com/a#Echobox=1738")

      expect(uri.to_s).to eq("https://example.com/a")
    end

    it "accepts a bare www link, which is how half of them are typed" do
      expect(described_class.clean("www.spiegel.de/x").to_s).to eq("https://www.spiegel.de/x")
    end

    it "lowercases the host and gives a bare domain a path" do
      expect(described_class.clean("https://WWW.Spiegel.DE").to_s).to eq("https://www.spiegel.de/")
    end

    it "refuses anything that is not https" do
      expect(described_class.clean("http://example.com/a")).to be_nil
      expect(described_class.clean("ftp://example.com/a")).to be_nil
      expect(described_class.clean("mailto:someone@example.com")).to be_nil
    end

    it "refuses text that was never a URL" do
      expect(described_class.clean("see figure 2.3")).to be_nil
      expect(described_class.clean("")).to be_nil
      expect(described_class.clean(nil)).to be_nil
    end

    it "leaves a query that is not form encoded exactly as it arrived" do
      expect(described_class.clean("https://example.com/a?token").to_s).to eq("https://example.com/a?token")
    end
  end

  describe ".under?" do
    it "matches a host and its subdomains, the way the link filter matches its lists" do
      expect(described_class.under?("www.example.com", ["example.com"])).to be(true)
      expect(described_class.under?("example.com", ["example.com"])).to be(true)
      expect(described_class.under?("notexample.com", ["example.com"])).to be(false)
      expect(described_class.under?("example.com", [])).to be(false)
    end

    it "accepts an entry pasted with a www on the front" do
      expect(described_class.under?("news.example.com", ["www.example.com"])).to be(true)
    end
  end

  describe ".display_host" do
    it "drops the www, which nobody reads out loud" do
      expect(described_class.display_host(URI("https://www.spiegel.de/x"))).to eq("spiegel.de")
    end
  end
end
