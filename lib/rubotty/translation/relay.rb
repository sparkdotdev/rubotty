# frozen_string_literal: true

require "json"
require "securerandom"

module Rubotty
  module Translation
    # The half of translation that touches the network and the room: the
    # feature only resolves a group's peers and enqueues, this runs on the
    # durable scheduler's own worker, so a slow or unreachable LibreTranslate
    # holds up nothing but its own job, and raising here asks the scheduler
    # to retry with backoff. Loop safety: every copy this posts is recorded
    # as a destination in the same durable message map {Features::Bridge}
    # writes its own relayed copies into, so {Core::LoopGuard} drops an echo
    # of it before any feature sees it again.
    class Relay
      KIND = "translation"

      # How long a translated copy stays findable for an edit. Generous
      # because an edit can arrive long after the original was posted, and
      # losing the link only costs THAT edit's propagation, never the
      # message itself.
      DEFAULT_LINK_TTL = 24 * 60 * 60

      # @param scheduler [Core::DurableScheduler, nil] where a translation
      #   runs. nil makes {#enqueue_new}/{#enqueue_edit} no-ops.
      # @param topology [Core::Topology] resolves a room and an endpoint at
      #   fire time, which may be long after the message that queued this
      # @param registry [ControlPlane::Registry, nil] nil on the config path
      # @param people [Core::LivePeople, Core::Directory, nil] where bridged nicknames are looked up
      # @param ttl [Integer] seconds a link between an original and a
      #   translated copy is kept for
      def initialize(scheduler:, storage:, topology:, adapters:, loop_guard: nil, logger: nil, registry: nil,
                     people: nil, client: nil, settings: nil, segmenter: nil, ttl: DEFAULT_LINK_TTL,
                     clock: -> { Time.now })
        @scheduler = scheduler
        @storage = storage
        @topology = topology
        @registry = registry
        @people = people
        @adapters = adapters
        @loop_guard = loop_guard
        @logger = logger
        @settings = settings || Settings.new
        @client = client || Client.new(settings: @settings, logger: logger)
        @segmenter = segmenter || Segmenter.new
        @ttl = ttl
        @clock = clock
        @scheduler&.register(KIND) { |job| run(job) }
      end

      # Ask for one message to be translated and relayed into one peer room.
      # One call per peer: a three room group queues two of these for a
      # message posted in any one of them.
      #
      # @param author_id [String, nil] the author's id on +origin_adapter+, kept so
      #   each copy can be labelled with the nickname they chose for its platform
      # @return [Object, nil] the scheduled job's id, or nil with no scheduler
      def enqueue_new(source_ref:, source_language:, target_room:, target_language:, body:,
                      attachments: [], sender_label: nil, author_id: nil, origin_adapter: nil, community: nil)
        return nil if @scheduler.nil?

        @scheduler.schedule(
          kind: KIND, run_at: @clock.call, community: community,
          discard_payload: true,
          payload: {
            "action" => "new",
            "source_endpoint_id" => source_ref.endpoint_id,
            "source_native_id" => source_ref.native_id,
            "source_language" => source_language.to_s,
            "target_room_unique_id" => target_room.unique_id,
            "target_language" => target_language.to_s,
            "text" => body.text,
            "spans" => dump_spans(body),
            "attachments" => Array(attachments).map(&:to_h),
            "sender_label" => dump_sender_label(sender_label),
            "author_id" => author_id&.to_s,
            "origin_adapter" => origin_adapter&.to_s
          }
        )
      end

      # Ask for an edit to be re-translated and propagated to every copy this
      # source ref has already produced, whichever peer room they are in.
      #
      # @return [Object, nil] the scheduled job's id, or nil with no scheduler
      def enqueue_edit(source_ref:, source_language:, text:, spans: [], community: nil)
        return nil if @scheduler.nil?

        @scheduler.schedule(
          kind: KIND, run_at: @clock.call, community: community,
          discard_payload: true,
          payload: {
            "action" => "edit",
            "source_endpoint_id" => source_ref.endpoint_id,
            "source_native_id" => source_ref.native_id,
            "source_language" => source_language.to_s,
            "text" => text.to_s,
            "spans" => spans
          }
        )
      end

      # The durable scheduler's own handler. Public so a spec can drive one
      # job without a scheduler behind it, the same seam {LinkAnnotation::
      # Annotator#annotate} uses. Takes the JOB rather than its payload: a
      # room unique_id and an endpoint id both resolve against a topology
      # spanning every tenant, and the job is what says which one meant them.
      def run(job)
        raise ArgumentError, "translation needs the durable job, not a bare payload" unless job?(job)

        payload = job.payload || {}
        case payload["action"].to_s
        when "new" then run_new(job, payload)
        when "edit" then run_edit(job, payload)
        else
          @logger&.warn { "translation: unknown job action #{payload["action"].inspect}" }
        end
      end

      private

      def job?(job) = job.respond_to?(:payload) && job.respond_to?(:community)

      # The community id a job belongs to: nil with no registry, which is the
      # config-file path where there is one community and nothing to cross
      # into, and :none when the slug names no live community, which relays
      # nothing rather than relaying unscoped.
      def scope_for(job)
        return nil if @registry.nil?

        id = @registry.current.community(job.community.to_s)&.id
        return id unless id.nil?

        @logger&.error { "translation: job names no live community (#{job.community.inspect}), relaying nothing" }
        :none
      end

      # A room that no longer exists (deleted, unmapped, since the message
      # was posted) is not something worth retrying: there is nowhere sane to
      # deliver to and no future retry makes the room reappear.
      def run_new(job, payload)
        community_id = scope_for(job)
        return if community_id == :none

        room = room_for(payload["target_room_unique_id"])
        if room.nil?
          @logger&.debug { "translation: target room #{payload["target_room_unique_id"]} is gone, dropped" }
          return
        end
        return unless permitted_room?(room, community_id)

        targets = permitted_targets(room, community_id)
        return if targets.empty?

        body = translated_body(payload)
        people = people_for(community_id)
        links = targets.filter_map { |target| deliver_and_record(payload, body, target, room, people) }
        save_links(payload, links) unless links.empty?
      end

      # A room unique_id spans the whole deployment, but a payload is text and
      # text can name any room at all, so what it resolved to is still held
      # against the community the job carries.
      def permitted_room?(room, community_id)
        return true if Core::CommunityScope.permits?(room, community_id)

        @logger&.error do
          "translation REFUSED: room #{room.unique_id} belongs to community " \
            "#{room.community_id.inspect}, not #{community_id.inspect}"
        end
        false
      end

      # Per endpoint rather than per room, so a room that somehow holds one
      # foreign endpoint still relays into the ones it is entitled to.
      def permitted_targets(room, community_id)
        room.endpoints.select(&:sends?).select do |target|
          Core::CommunityScope.permit_or_log(target, community_id, logger: @logger, doing: "translation")
        end
      end

      def run_edit(job, payload)
        community_id = scope_for(job)
        return if community_id == :none

        links = load_links(link_key(payload))
        return if links.empty?

        body = Core::RichText.new(payload["text"].to_s, load_spans(payload["spans"]))
        protected_body = @segmenter.protect(body)
        links.each { |link| edit_one(link, payload, body, protected_body, community_id) }
      end

      # Translate once, then post to every sending endpoint of the target
      # room: exactly the fan out {Features::Bridge} does within a room,
      # except this one crosses rooms and languages instead of platforms.
      def translated_body(payload)
        body = Core::RichText.new(payload["text"].to_s, load_spans(payload["spans"]))
        protected_body = @segmenter.protect(body)
        return body unless protected_body.translatable?

        translated = @client.translate(protected_body.text, source: payload["source_language"],
                                       target: payload["target_language"])
        # A reconstruction LibreTranslate's own answer broke (a placeholder
        # missing or doubled) is relayed verbatim rather than posted
        # corrupted or dropped: the original still says something true.
        @segmenter.restore(translated, protected_body.placeholders) || body
      end

      def deliver_and_record(payload, body, target, room, people)
        adapter = @adapters[[target.adapter_name, target.account]]
        return nil if adapter.nil?

        message = message_for(payload, body, target, people)
        receipt = adapter.deliver(message, target)
        return nil if receipt.nil?

        @storage.record(source: source_ref(payload), destination: receipt.ref, room_id: room.id,
                        expires_at: @ttl ? @clock.call + @ttl : nil)
        @loop_guard&.note_delivery(target.id, receipt.native_id)
        { "endpoint_id" => receipt.endpoint_id, "native_id" => receipt.native_id,
          "room_unique_id" => room.unique_id, "language" => payload["target_language"] }
      rescue StandardError => e
        @logger&.warn { "translation: could not deliver to #{target.id}: #{e.class}: #{e.message}" }
        nil
      end

      def message_for(payload, body, target, people)
        Core::Message.new(
          kind: :chat,
          ref: Core::MessageRef.new(target.id, "translation-#{SecureRandom.hex(4)}"),
          origin: target,
          body: translated_note(payload["source_language"]).concat(body),
          attachments: attachments_of(payload),
          trace: [target.id],
          sender_label: sender_label_for(payload, target, people)
        )
      end

      # The stored label, led by the bridged nickname the author chose for
      # +target+'s platform when they chose one. A job queued before the author
      # was stored alongside the label keeps the stored label.
      def sender_label_for(payload, target, people)
        stored = load_sender_label(payload["sender_label"])
        return stored if stored.nil? || people.nil?

        author_id = payload["author_id"].to_s
        origin_adapter = payload["origin_adapter"].to_s
        return stored if author_id.empty? || origin_adapter.empty?

        nickname = people.by_identity(origin_adapter, author_id)&.nickname_on(target.adapter_name)
        return stored if nickname.nil?

        Core::SenderLabel.nickname(nickname: nickname, username: stored.username, platform: stored.platform,
                                   protocol: stored.protocol)
      end

      # The job's own community's people, never the deployment-wide union, so a
      # nickname chosen in one community never names the same account in another.
      def people_for(community_id)
        return @people unless @people.respond_to?(:for_community)

        @people.for_community(community_id)
      end

      def edit_one(link, payload, body, protected_body, community_id)
        restored = restored_body(payload, body, protected_body, link["language"])
        deliver_edit(link, payload, restored, community_id)
      end

      # Not rescued: a translation failure here has to fail the whole job so
      # the scheduler retries it. Re-editing a link that already succeeded on
      # a later attempt is a harmless no-op, not a duplicate.
      def restored_body(payload, body, protected_body, target_language)
        return body unless protected_body.translatable?

        translated = @client.translate(protected_body.text, source: payload["source_language"], target: target_language)
        @segmenter.restore(translated, protected_body.placeholders) || body
      end

      # One endpoint's delivery failing must not stop the rest of the links
      # in this same edit from being tried.
      def deliver_edit(link, payload, restored, community_id)
        endpoint = @topology.endpoint(link["endpoint_id"])
        return if endpoint.nil?
        return unless Core::CommunityScope.permit_or_log(endpoint, community_id, logger: @logger,
                                                                                 doing: "translation edit")

        adapter = @adapters[[endpoint.adapter_name, endpoint.account]]
        return if adapter.nil? || !adapter.capabilities_for(endpoint).edits?

        message = Core::Message.new(
          kind: :chat, ref: Core::MessageRef.new(endpoint.id, link["native_id"]), origin: endpoint,
          body: translated_note(payload["source_language"]).concat(restored)
        )
        adapter.edit(message, endpoint, link["native_id"])
      rescue StandardError => e
        @logger&.warn { "translation: could not edit #{link["endpoint_id"]}/#{link["native_id"]}: #{e.class}: #{e.message}" }
      end

      # A short attribution line ahead of the translated text. Who said it is
      # carried by the sender label itself (see {Features::Translation
      # #attribution_for}); this line only says why the room is seeing it at
      # all, which the label has no room to.
      def translated_note(source_language)
        name = source_language.to_s.empty? ? nil : LinkAnnotation::Language.name(source_language)
        text = "(translated from #{name || source_language})\n"
        Core::RichText.new(text, [Core::Span.new(kind: :italic, begin_index: 0, end_index: text.length - 1)])
      end

      def save_links(payload, new_links)
        key = link_key(payload)
        existing = load_links(key)
        @storage.put_state(key, JSON.generate(existing + new_links), expires_at: @clock.call + @ttl)
      rescue StandardError => e
        @logger&.warn { "translation: could not remember where #{key} went: #{e.class}: #{e.message}" }
      end

      # Tracks a translated copy's language so an edit can be re-translated
      # rather than copied verbatim. A delete needs no such tracking, since
      # Bridge's ordinary propagation already reaches a translated copy
      # through the shared message map.
      def link_key(payload) = "translation:links:#{payload["source_endpoint_id"]}:#{payload["source_native_id"]}"

      def load_links(key)
        raw = @storage.get_state(key)
        return [] if raw.nil?

        parsed = JSON.parse(raw)
        parsed.is_a?(Array) ? parsed : []
      rescue StandardError
        []
      end

      def room_for(unique_id) = @topology.rooms.find { |room| room.unique_id == unique_id.to_s }

      def source_ref(payload) = Core::MessageRef.new(payload["source_endpoint_id"], payload["source_native_id"])

      def dump_spans(body)
        body.spans.map do |span|
          { "kind" => span.kind.to_s, "from" => span.begin_index, "to" => span.end_index,
            "attributes" => span.attributes }
        end
      end

      def load_spans(raw)
        Array(raw).filter_map do |entry|
          entry = symbolize(entry)
          Core::Span.new(kind: entry[:kind].to_s.to_sym, begin_index: entry[:from].to_i,
                         end_index: entry[:to].to_i, attributes: symbolize(entry[:attributes]))
        rescue StandardError
          nil
        end
      end

      def attachments_of(payload)
        Array(payload["attachments"]).filter_map do |entry|
          Core::Attachment.new(**symbolize(entry))
        rescue StandardError
          nil
        end
      end

      def dump_sender_label(label)
        return nil if label.nil?

        { "username" => label.username, "platform" => label.platform, "display_name" => label.display_name,
          "name" => label.name, "protocol" => label.protocol }
      end

      def load_sender_label(raw)
        return nil unless raw.is_a?(Hash)

        raw = symbolize(raw)
        Core::SenderLabel.new(username: raw[:username], platform: raw[:platform],
                              display_name: raw[:display_name], name: raw[:name], protocol: raw[:protocol])
      end

      def symbolize(hash)
        return {} unless hash.is_a?(Hash)

        hash.each_with_object({}) { |(key, value), out| out[key.to_s.to_sym] = value }
      end
    end
  end
end
