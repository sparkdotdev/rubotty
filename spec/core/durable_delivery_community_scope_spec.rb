# frozen_string_literal: true

require "spec_helper"
require "sequel"

# Issue #1780, the shape of #1778 and #1779 across three more handlers: each
# registered a closure taking only the payload, putting the job's community
# out of reach of the code picking a target. Driven through the REAL durable
# scheduler, so the seam itself is what is under test.
RSpec.describe "durable handlers deliver only inside their job's community" do
  let(:snapshot) { colliding_snapshot }
  let(:registry) { colliding_registry(snapshot) }
  let(:topo) { snapshot.topology }

  let(:adapter) { Fakes::RecordingAdapter.new(own_id: "bot-1") }
  let(:adapters) { Hash.new(adapter) }

  let(:db) { Sequel.sqlite }
  let(:store) { Rubotty::Core::DurableSchedulerStore::Sequel.new(db: db) }
  let(:base) { Time.at(1_800_000_000) }
  let(:scheduler) do
    Rubotty::Core::DurableScheduler.new(store: store, session_id: "s", logger: Rubotty::Log.null,
                                        clock: -> { base })
  end

  let(:logs) { StringIO.new }
  let(:logger) { Rubotty::Log.build(level: "info", io: logs) }

  before { Rubotty::ControlPlane::Migrator.run(db) }

  def drain = scheduler.run_due(now: base + 1)

  def room_of(community_id)
    topo.rooms.find { |room| room.community_id == community_id }
  end

  describe Rubotty::LinkAnnotation::Annotator do
    let(:ephemeral) do
      Rubotty::Core::EphemeralMessage.new(adapters: adapters, topology: topo, session_id: "s",
                                          logger: Rubotty::Log.null)
    end

    # Enough German prose for Language.detect to be sure, so a permitted job
    # really does post and a refused one is refused for the right reason.
    def german_page
      "<html lang=\"de\"><head><title>Bericht</title></head><body><p>" \
        "#{"Der Bericht liegt vor und die Sprecherin hat sich dazu geaeussert. " * 12}</p></body></html>"
    end

    let(:fetcher) do
      Rubotty::LinkAnnotation::Fetcher.new(
        logger: Rubotty::Log.null,
        http: lambda { |uri|
          Rubotty::LinkAnnotation::Page.new(url: uri, requested: uri, html: german_page)
        }
      )
    end

    subject(:annotator) do
      described_class.new(scheduler: scheduler, ephemeral: ephemeral, topology: topo, registry: registry,
                          logger: logger, fetcher: fetcher, clock: -> { base })
    end

    def ask(community, endpoint_id)
      annotator.enqueue(community: community, endpoint_id: endpoint_id,
                        url: "https://www.spiegel.de/politik/x", known: %w[en], services: %w[google])
      drain
    end

    it "answers into the endpoint of the community that asked" do
      ask("beta", "beta-telegram")

      expect(adapter.delivered_to("beta-telegram").last.body.text).to include("spiegel.de")
    end

    it "refuses another community's endpoint, loudly, rather than answering into it" do
      ask("beta", "alpha-telegram")

      expect(adapter.delivered).to be_empty
      expect(logs.string).to match(/ERROR.*REFUSED.*alpha-telegram.*community 1.*not 2/)
    end

    it "answers nothing at all for a job whose slug names no live community" do
      ask("ghost", "alpha-telegram")

      expect(adapter.delivered).to be_empty
      expect(logs.string).to match(/names no live community/)
    end

    it "answers as before with no registry to scope by, which is the config path" do
      plain = described_class.new(scheduler: scheduler, ephemeral: ephemeral, topology: topo,
                                  logger: Rubotty::Log.null, fetcher: fetcher, clock: -> { base })
      plain.enqueue(community: "alpha", endpoint_id: "alpha-telegram",
                    url: "https://www.spiegel.de/politik/x", known: %w[en], services: %w[google])
      drain

      expect(adapter.delivered_to("alpha-telegram").last.body.text).to include("spiegel.de")
    end
  end

  describe Rubotty::Core::VideoRehostRelay do
    # The scope check gates everything downstream of picking a target, so
    # "the original bytes were asked for" is the exact line a refused job must
    # stop short of, and it needs none of the transcode machinery to see.
    class ProbeFetcher
      def initialize = @calls = 0

      attr_reader :calls

      def with(_url, filename: nil)
        @calls += 1
        nil
      end
    end

    let(:probe) { ProbeFetcher.new }
    let(:storage) { Rubotty::Storage::Memory.new }

    subject(:relay) do
      described_class.new(scheduler: scheduler, transcoder: Object.new, files: nil, storage: storage,
                          topology: topo, adapters: adapters, logger: logger,
                          fetcher_for: ->(_limit) { probe }, clock: -> { base },
                          env: { "RUBOTTY_FILE_STORAGE_URL" => "https://files.example" })
    end

    def shrink(community_id, target)
      relay.enqueue(
        attachment: Rubotty::Core::Attachment.new(kind: :video, url: "https://cdn.example/clip.mp4",
                                                  filename: "clip.mp4", size: 10),
        community_id: community_id, room_key: "general", ceiling: 720,
        source_ref: Rubotty::Core::MessageRef.new("#{target.split("-").first}-discord", "1"),
        target_endpoint_id: target, notice_native_id: "9", notice_line: "[clip.mp4]",
        body_text: "look\n[clip.mp4]"
      )
      drain
    end

    it "goes on to transcode for a target its own community owns" do
      shrink(2, "beta-telegram")

      expect(probe.calls).to eq(1)
    end

    it "refuses another community's endpoint, loudly, and never fetches the video at all" do
      shrink(2, "alpha-telegram")

      expect(probe.calls).to be_zero
      expect(adapter.delivered).to be_empty
      expect(logs.string).to match(/ERROR.*REFUSED.*alpha-telegram.*community 1.*not 2/)
    end

    # The job's own column and the payload say the same thing twice, and
    # nothing here can tell which of the two was written for another tenant.
    it "refuses a job whose community disagrees with its payload's" do
      store.enqueue(kind: described_class::KIND, run_at: base, community: "1",
                    payload: { "community_id" => 2, "target_endpoint_id" => "beta-telegram" })
      relay
      drain

      expect(probe.calls).to be_zero
      expect(logs.string).to match(/video_shrink REFUSED/)
    end
  end

  describe Rubotty::Translation::Relay do
    let(:storage) { Rubotty::Storage::Memory.new }

    # Never reached by a refused job, so a call here is itself evidence the
    # scope check let one through.
    class EchoClient
      def translate(text, source:, target:) = "[#{target}] #{text}"
    end

    subject(:relay) do
      described_class.new(scheduler: scheduler, storage: storage, topology: topo, adapters: adapters,
                          registry: registry, logger: logger, client: EchoClient.new, clock: -> { base })
    end

    def cross(community, target_community_id)
      relay.enqueue_new(source_ref: Rubotty::Core::MessageRef.new("beta-discord", "1"),
                        source_language: "en", target_room: room_of(target_community_id),
                        target_language: "de", body: Rubotty::Core::RichText.plain("hello"),
                        community: community)
      drain
    end

    it "relays into a room its own community owns" do
      cross("beta", 2)

      expect(adapter.delivered_to("beta-telegram").last.body.text).to include("hello")
    end

    # Both communities own a room keyed "general", which is the whole point of
    # the fixture: nothing about the payload alone says which one was meant.
    it "refuses another community's room, loudly, rather than relaying into it" do
      cross("beta", 1)

      expect(adapter.delivered).to be_empty
      expect(logs.string).to match(/ERROR.*REFUSED.*room 1:general.*community 1.*not 2/)
    end

    it "relays nothing at all for a job whose slug names no live community" do
      cross("ghost", 1)

      expect(adapter.delivered).to be_empty
      expect(logs.string).to match(/names no live community/)
    end

    it "refuses another community's endpoint when re-translating an edit into it" do
      storage.put_state("translation:links:beta-discord:1",
                        JSON.generate([{ "endpoint_id" => "alpha-telegram", "native_id" => "7",
                                         "room_unique_id" => "1:general", "language" => "de" }]))
      relay.enqueue_edit(source_ref: Rubotty::Core::MessageRef.new("beta-discord", "1"),
                         source_language: "en", text: "hello again", community: "beta")
      drain

      expect(adapter.edited).to be_empty
      expect(logs.string).to match(/ERROR.*REFUSED.*alpha-telegram.*community 1.*not 2/)
    end
  end
end
