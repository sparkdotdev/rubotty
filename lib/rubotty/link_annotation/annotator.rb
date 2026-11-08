# frozen_string_literal: true

module Rubotty
  module LinkAnnotation
    # The half of link annotation that touches the network: the feature only
    # does string work and enqueues, while the fetch runs on the durable
    # scheduler's worker, so the reply arrives a second or two behind the
    # link. Nothing here raises, so the scheduler never retries it; every
    # failure here is a reason to say nothing.
    class Annotator
      # The durable-scheduler job kind this registers and enqueues.
      KIND = "link_annotation"

      # Who the annotation is posted as.
      NOTICE_NAME = "rubotty"

      # Hosts whose markup (<html lang>, locale meta, even the visible chrome
      # text) is personalized by the requester's IP rather than by what the
      # page is actually about, so it carries no language signal at all. A
      # YouTube watch page for an English video came back declaring "pt" when
      # fetched from a Portuguese-geolocated address; trusting that would be
      # confidently wrong rather than silent, which {Language} exists to avoid.
      GEO_PERSONALIZED_HOSTS = %w[youtube.com youtu.be].freeze

      # @param scheduler [Core::DurableScheduler, nil] where the fetch runs. Nil,
      #   with no durable backend, makes {#enqueue} a no-op.
      # @param ephemeral [Core::EphemeralMessage] posts the annotation
      # @param topology [Core::Topology] resolves the endpoint id in a payload to
      #   a live endpoint at fire time
      # @param registry [ControlPlane::Registry, nil] nil on the config path
      # @param clock [#call] returns the current Time; injected in specs
      def initialize(scheduler:, ephemeral:, topology:, logger:, registry: nil,
                     fetcher: nil, cache: nil, clock: -> { Time.now })
        @scheduler = scheduler
        @ephemeral = ephemeral
        @topology = topology
        @registry = registry
        @logger = logger
        @fetcher = fetcher || Fetcher.new(logger: logger)
        @cache = cache || Cache.new
        @clock = clock
        @scheduler&.register(KIND) { |job| annotate(job) }
      end

      attr_reader :cache

      # Ask for one URL to be looked at. Returns the job id, or nil when there
      # is nowhere to run it.
      #
      # @param community [String, nil] slug, for the scheduler's own scoping
      # @param endpoint_id [String] where the answer is posted
      # @param url [String] already through {Link.clean}
      # @param known [Array<String>] the languages this room reads
      # @param services [Array<String>] service keys, in the order to show them
      def enqueue(community:, endpoint_id:, url:, known:, services:)
        return nil if @scheduler.nil?

        @scheduler.schedule(
          kind: KIND, run_at: @clock.call, community: community,
          payload: { "url" => url.to_s, "endpoint_id" => endpoint_id.to_s,
                     "known" => Array(known).map(&:to_s), "services" => Array(services).map(&:to_s) }
        )
      end

      # Run one enqueued look. Public so a spec can drive it without a
      # scheduler, and takes the JOB rather than its payload: the community
      # this work belongs to lives on the job, and the endpoint id below means
      # nothing without it.
      #
      # @param job [Core::DurableSchedulerStore::Row]
      # @return [Boolean] whether anything was posted
      def annotate(job)
        # Outside the rescue below, which exists to swallow a fetch going
        # wrong rather than a caller handing this the wrong thing.
        raise ArgumentError, "link_annotation needs the durable job, not a bare payload" unless job?(job)

        run(job)
      end

      # What language a URL is in, from the cache when it has been read before.
      # nil covers both "could not reach it" and "could not tell".
      def language_of(uri)
        @cache.fetch(uri.to_s) { detect(uri) }
      end

      private

      # A job carries both halves this needs: the payload naming an endpoint,
      # and the community that says which tenant's endpoint it meant.
      def job?(job) = job.respond_to?(:payload) && job.respond_to?(:community)

      def run(job)
        spec = Spec.parse(job.payload)
        return false if spec.nil?

        endpoint = endpoint_for(job, spec)
        return false if endpoint.nil?

        language = language_of(spec.uri)
        return false if language.nil?
        return false if spec.known.include?(language)

        post(endpoint, spec, language)
      rescue StandardError => e
        @logger&.warn { "link_annotation: could not annotate: #{e.class}: #{e.message}" }
        false
      end

      # The payload's endpoint id resolves against the merged topology, which
      # spans every tenant, so the answer is then held against the community
      # the job carries. Without a registry there is one community and nothing
      # to cross into, which is the config-file path.
      def endpoint_for(job, spec)
        endpoint = @topology.endpoint(spec.endpoint_id)
        return endpoint if endpoint.nil? || @registry.nil?

        community_id = @registry.current.community(job.community.to_s)&.id
        return refuse_whole_job(job) if community_id.nil?

        permitted = Core::CommunityScope.permit_or_log(endpoint, community_id, logger: @logger,
                                                                              doing: "link_annotation")
        permitted ? endpoint : nil
      end

      # A slug naming no live community says nothing at all rather than posting
      # unscoped: resolving no community used to read the same as having
      # nothing to check against.
      def refuse_whole_job(job)
        @logger&.error do
          "link_annotation: job names no live community (#{job.community.inspect}), posting nothing"
        end
        nil
      end

      def detect(uri)
        return nil if Link.under?(uri.host, GEO_PERSONALIZED_HOSTS)

        page = @fetcher.call(uri)
        if page.nil?
          @logger&.debug { "link_annotation: nothing readable at #{uri.host}" }
          return nil
        end

        unless page.article?
          @logger&.debug { "link_annotation: not trusting #{uri.host}, #{page.refusal}" }
          return nil
        end

        Language.detect(page.html, text: page.text)
      end

      def post(endpoint, spec, language)
        links = links_for(spec, language)
        return false if links.empty?

        @ephemeral.post(
          endpoints: [endpoint], body: Core::RichText.plain(body_text(spec, language, links)),
          name: NOTICE_NAME, delete_after: 0
        )
        @logger&.info { "link_annotation: offered #{links.length} translation(s) of a #{language} page" }
        true
      end

      def links_for(spec, language)
        target = spec.known.first || "en"
        Services.resolve(spec.services).filter_map do |service|
          url = Services.build(service, uri: spec.uri, source: language, target: target)
          url.nil? ? nil : [service.label, url]
        end
      end

      def body_text(spec, language, links)
        target = Language.name(spec.known.first || "en")
        lines = ["#{Link.display_host(spec.uri)} looks like it is in #{Language.name(language)}. " \
                 "Read it in #{target}:"]
        links.each { |label, url| lines << "#{label}: #{url}" }
        lines.join("\n")
      end

      # One job's arguments, parsed once. The store returns string keys and a
      # hand-built payload may use symbols, so both are read.
      Spec = Struct.new(:uri, :endpoint_id, :known, :services, keyword_init: true) do
        def self.parse(payload)
          return nil unless payload.is_a?(Hash)

          uri = Link.clean(value(payload, "url"))
          endpoint_id = value(payload, "endpoint_id").to_s
          return nil if uri.nil? || endpoint_id.empty?

          new(uri: uri, endpoint_id: endpoint_id,
              known: Array(value(payload, "known")).filter_map { |code| Language.normalise(code) },
              services: Array(value(payload, "services")).map(&:to_s))
        end

        def self.value(payload, key)
          payload.key?(key) ? payload[key] : payload[key.to_sym]
        end
      end
    end
  end
end
