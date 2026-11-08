# frozen_string_literal: true

require "spec_helper"
require "sequel"

RSpec.describe Rubotty::LinkAnnotation::Annotator do
  include Builders

  let(:tg) { endpoint("tg-general") }
  let(:room_map) { topology(room("r", tg)) }
  let(:adapter) { Fakes::ReactingAdapter.new(own_id: "bot") }
  let(:adapters) { Hash.new(adapter) }

  let(:db) do
    db = Sequel.sqlite
    Rubotty::ControlPlane::Migrator.run(db)
    db
  end

  let(:scheduler) do
    Rubotty::Core::DurableScheduler.new(
      store: Rubotty::Core::DurableSchedulerStore::Sequel.new(db: db),
      session_id: "s", logger: Rubotty::Log.null
    )
  end

  let(:ephemeral) do
    Rubotty::Core::EphemeralMessage.new(
      adapters: adapters, topology: room_map, session_id: "s", logger: Rubotty::Log.null
    )
  end

  # Stands in for the whole request. Every spec in this suite is forbidden from
  # opening a socket, and this is the seam the fetcher exposes for it.
  def serving(html, url: "https://www.spiegel.de/politik/x", requested: url)
    Rubotty::LinkAnnotation::Fetcher.new(
      logger: Rubotty::Log.null,
      http: lambda { |_uri|
        Rubotty::LinkAnnotation::Page.new(url: URI(url), requested: URI(requested), html: html)
      }
    )
  end

  def german_page(lang: "de")
    "<html lang=\"#{lang}\"><head><title>Bericht</title></head><body><p>" \
      "#{"Der Bericht liegt vor und die Sprecherin hat sich dazu geaeussert. " * 12}</p></body></html>"
  end

  def annotator(fetcher: serving(german_page), **rest)
    described_class.new(
      scheduler: scheduler, ephemeral: ephemeral, topology: room_map,
      logger: Rubotty::Log.null, fetcher: fetcher, **rest
    )
  end

  def payload(**overrides)
    { "url" => "https://www.spiegel.de/politik/x", "endpoint_id" => "tg-general",
      "known" => %w[en], "services" => %w[google yandex] }.merge(overrides)
  end

  # The handler's seam is the durable job, never a bare payload: the community
  # an endpoint id was meant for lives on the job and nowhere else. Named for
  # this file because a class opened in a describe block is top level.
  AnnotationJob = Struct.new(:payload, :community, keyword_init: true)

  def job(community: nil, **overrides)
    AnnotationJob.new(payload: payload(**overrides), community: community)
  end

  def posted = adapter.delivered_to("tg-general").map { |message| message.body.text }

  it "offers every configured front end for a page the room cannot read" do
    expect(annotator.annotate(job)).to be(true)

    text = posted.last
    expect(text).to include("spiegel.de looks like it is in German")
    expect(text).to include("Read it in English")
    expect(text).to include("https://translate.google.com/translate?sl=de&tl=en&u=")
    expect(text).to include("https://translate.yandex.com/translate?url=")
  end

  it "says nothing about a page in a language the room already reads" do
    expect(annotator.annotate(job("known" => %w[de en]))).to be(false)
    expect(posted).to be_empty
  end

  it "translates into the first language the room listed" do
    annotator.annotate(job("known" => %w[fr], "services" => %w[google]))

    expect(posted.last).to include("Read it in French")
    expect(posted.last).to include("tl=fr")
  end

  it "says nothing when the page could not be reached at all" do
    silent = Rubotty::LinkAnnotation::Fetcher.new(logger: Rubotty::Log.null, http: ->(_uri) { nil })

    expect(annotator(fetcher: silent).annotate(job)).to be(false)
    expect(posted).to be_empty
  end

  # The consent-wall case. The body is real HTML in a real language, and it is
  # the wrong one.
  it "says nothing when what came back was not the article" do
    wall = serving(german_page, url: "https://consent.example.net/?continue=x",
                                requested: "https://www.spiegel.de/politik/x")

    expect(annotator(fetcher: wall).annotate(job)).to be(false)
    expect(posted).to be_empty
  end

  it "says nothing when neither the declaration nor the text can tell" do
    unknown = serving("<html><body><p>#{"lorem ipsum dolor sit amet " * 40}</p></body></html>")

    expect(annotator(fetcher: unknown).annotate(job)).to be(false)
    expect(posted).to be_empty
  end

  it "says nothing about a YouTube link, whose lang attribute is geolocated rather than about the video" do
    # A real fetch from a Portuguese-geolocated address gets this exact markup
    # back for an English video; declared() would say "pt" if it looked.
    localized = serving(german_page(lang: "pt"), url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
                                                  requested: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")

    expect(annotator(fetcher: localized).annotate(
             job("url" => "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
           )).to be(false)
    expect(posted).to be_empty
  end

  it "reads a URL once however many rooms post it" do
    reads = 0
    counting = Rubotty::LinkAnnotation::Fetcher.new(
      logger: Rubotty::Log.null,
      http: lambda { |uri|
        reads += 1
        Rubotty::LinkAnnotation::Page.new(url: uri, requested: uri, html: german_page)
      }
    )
    subject = annotator(fetcher: counting)

    3.times { subject.annotate(job) }

    expect(reads).to eq(1)
    expect(posted.length).to eq(3)
  end

  it "ignores a payload with nothing usable in it" do
    subject = annotator

    expect(subject.annotate(job("url" => "not a url"))).to be(false)
    expect(subject.annotate(job("endpoint_id" => "gone"))).to be(false)
    expect(subject.annotate(AnnotationJob.new(payload: nil, community: nil))).to be(false)
  end

  # Inverted from "a nil payload is ignored": a caller with no job in hand has
  # thrown the community away, and that must raise rather than resolve an
  # endpoint id against every tenant's topology at once.
  it "refuses a bare payload where the durable job belongs" do
    expect { annotator.annotate(payload) }.to raise_error(ArgumentError, /durable job/)
    expect { annotator.annotate(nil) }.to raise_error(ArgumentError, /durable job/)
  end

  describe "the durable job" do
    it "registers its kind so a queued look survives a restart" do
      annotator

      expect(scheduler.handler?(described_class::KIND)).to be(true)
    end

    it "runs the look on the scheduler's worker rather than wherever it was asked for" do
      subject = annotator
      subject.enqueue(community: "c", endpoint_id: "tg-general", url: "https://www.spiegel.de/politik/x",
                      known: %w[en], services: %w[google])

      expect(posted).to be_empty

      scheduler.run_due(now: Time.now + 1)

      expect(posted.last).to include("translate.google.com")
    end
  end

  it "has nowhere to run without a durable scheduler, and says so by doing nothing" do
    subject = described_class.new(
      scheduler: nil, ephemeral: ephemeral, topology: room_map, logger: Rubotty::Log.null
    )

    expect(subject.enqueue(community: nil, endpoint_id: "tg-general", url: "https://x.example/",
                           known: %w[en], services: %w[google])).to be_nil
  end
end
