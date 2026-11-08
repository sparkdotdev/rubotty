# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::LinkAnnotation::Cache do
  let(:now) { Time.at(1_700_000_000) }
  let(:clock) { -> { @time } }

  before { @time = now }

  def cache(**rest) = described_class.new(clock: clock, **rest)

  it "reads a URL once, however many times it is posted" do
    subject = cache
    reads = 0

    3.times do
      subject.fetch("https://example.com/a") do
        reads += 1
        "de"
      end
    end

    expect(reads).to eq(1)
  end

  # The more important half. A site that answers with a consent wall answers
  # with one every time, so without this a popular unfetchable link becomes an
  # outbound request every time anybody mentions it.
  it "remembers that it could not tell, and does not retry on the next mention" do
    subject = cache
    reads = 0

    2.times do
      subject.fetch("https://example.com/a") do
        reads += 1
        nil
      end
    end

    expect(reads).to eq(1)
    expect(subject.get("https://example.com/a").language).to be_nil
  end

  it "retries a refusal sooner than it re-reads a language it already knows" do
    subject = cache
    subject.put("https://example.com/miss", nil)
    subject.put("https://example.com/hit", "de")

    @time = now + described_class::MISS_TTL + 1

    expect(subject.get("https://example.com/miss")).to be_nil
    expect(subject.get("https://example.com/hit").language).to eq("de")
  end

  it "forgets a language once it is old enough to be worth checking again" do
    subject = cache
    subject.put("https://example.com/a", "de")

    @time = now + described_class::HIT_TTL + 1

    expect(subject.get("https://example.com/a")).to be_nil
  end

  it "stays bounded, dropping the entry nobody has asked about" do
    subject = cache(limit: 2)
    subject.put("a", "de")
    subject.put("b", "fr")
    subject.get("a")
    subject.put("c", "it")

    expect(subject.size).to eq(2)
    expect(subject.get("a").language).to eq("de")
    expect(subject.get("b")).to be_nil
  end
end
