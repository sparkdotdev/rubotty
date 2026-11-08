# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Core::Attachment do
  def attachment(url:)
    described_class.new(kind: :photo, url: url, filename: "a.png")
  end

  describe "#resolvable?" do
    it "is true for a real url" do
      expect(attachment(url: "https://cdn.example/a.png").resolvable?).to be(true)
    end

    it "is false for a nil url" do
      expect(attachment(url: nil).resolvable?).to be(false)
    end

    # Util::MediaFetcher#fetch already treats an empty string as unusable and
    # returns nil with no log line. Before this, resolvable? disagreed and let
    # such an attachment through the uploadable filter, where it died silently.
    it "is false for an empty string url" do
      expect(attachment(url: "").resolvable?).to be(false)
    end

    it "is false for a whitespace only url" do
      expect(attachment(url: "   ").resolvable?).to be(false)
    end
  end
end
