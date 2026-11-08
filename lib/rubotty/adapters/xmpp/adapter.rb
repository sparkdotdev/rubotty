# frozen_string_literal: true

module Rubotty
  module Adapters
    module Xmpp
      # The XMPP platform adapter: MUC (multi user chat) rooms map to channels, one
      # bot joins each under one nick so per-sender identity is a text prefix, and
      # edits degrade to a text notice since XMPP declares no reliable native edit
      # (XEP-0308 only edits the last message and is unevenly supported); deletes
      # and reactions are native. Channel discovery is passive from every groupchat
      # message ({#learn_room}), plus XEP-0048 bookmarks and, with +muc_service+ set,
      # XEP-0030 disco#items at connect ({#discover_rooms}); either half can come back empty.
      class Adapter < Adapters::Base
        class << self
          def identity_durability = :session

          def adapter_name = :xmpp

          # One account is one password, one connection, so a missing password
          # cleanly means "not yet connected".
          def dormant_on_missing_secret? = true

          def account_schema
            Config::Schema.define do
              field :jid, :string, required: true,
                                   desc: "the bot's bare JID, for example bridge@example.org"
              field :password_env, :string, required: true, env: true,
                                            desc: "name of the environment variable holding the password"
              field :nick, :string,
                    desc: "MUC nick to join rooms under. Defaults to the JID local part."
              field :host, :string, desc: "connection host override, if it differs from the JID domain"
              field :port, :integer, default: 5222, desc: "XMPP client port"
              field :muc_service, :string,
                    desc: "MUC service JID, for example conference.example.org, to enumerate via " \
                          "service discovery (XEP-0030) for channel discovery (#38). Omit to skip " \
                          "active disco enumeration and rely on bookmarks and passive discovery."
              field :upload_service, :string,
                    desc: "XEP-0363 HTTP upload component JID, for example upload.example.org, asked " \
                          "for an upload slot when an attachment's own source URL cannot be relayed " \
                          "as is. Omit to query the bot's own server JID instead."
            end
          end

          def endpoint_schema
            Config::Schema.define do
              field :room_jid, :string, required: true,
                                        desc: "MUC room JID, for example room@conference.example.org"
              field :sender_prefix, :boolean, default: true,
                                              desc: "prepend the sender name to relayed messages"
              field :sender_separator, :string, default: ":", desc: "printed after the sender name"
            end
          end

          def validate_endpoint(settings, path)
            id = settings[:room_jid].to_s
            return [] if id.include?("@")

            ["#{path}.room_jid: expected a MUC room JID like room@conference.example.org, got #{id.inspect}"]
          end

          def discovers_channels? = true

          def route_key_for(endpoint) = endpoint.settings[:room_jid].to_s

          def addressing(route_key, external_id: nil)
            { "room_jid" => route_key.to_s }
          end

          # The MUC domain a room JID belongs to, the coarse space
          # {ControlPlane::ChannelDiscovery} groups a sweep by. A room JID with
          # no "@" (already rejected by {.validate_endpoint}) yields "".
          def muc_domain(room_jid) = room_jid.to_s.split("@", 2)[1].to_s

          # A one to one chat is ordinary XMPP: #send_admin_dm is a plain
          # type="chat" message and #delete_admin_dm is the same XEP-0424
          # retraction the MUC path already uses, just addressed to a bare
          # JID instead of a room.
          def supports_admin_dm? = true
          def supports_admin_dm_delete? = true
        end

        # No way to ask a server its real XEP-0363 upload ceiling ahead of a
        # slot request (the spec's max-file-size form field is optional and
        # per-server), so this just borrows the fetcher's own generic ceiling,
        # the same choice Matrix made for its own content-repo upload.
        MAX_ATTACHMENT_BYTES = Util::MediaFetcher::DEFAULT_LIMIT

        CAPABILITIES = Capabilities.new(
          # XEP-0308 correction only edits the last message and is unevenly
          # supported, so an edit still degrades to a text notice.
          edits: false,
          # XEP-0424 retraction, reflected by the room like any other message.
          deletes: true,
          # XEP-0461 replies exist but nothing here sends or reads them yet.
          replies: false,
          # RFC 6121 <thread> exists but nothing here sends or reads it yet.
          threads: false,
          max_attachment_bytes: MAX_ATTACHMENT_BYTES,
          # XEP-0444 reactions: an ordinary message payload, no server support needed.
          reactions: true,
          moderation: %i[kick ban unban delete]
        ).freeze

        def initialize(account:, settings:, dispatcher:, logger:, endpoints: [],
                       endpoint_resolver: nil, control_lane: nil, join_guard: nil, discovery: nil)
          super
          @nick = settings[:nick] || jid_localpart(settings[:jid])
          @client = Client.new(
            jid: settings[:jid], password: settings[:password], nick: @nick,
            host: settings[:host], port: settings[:port] || 5222,
            upload_service: settings[:upload_service], logger: logger
          )
          @outbound = Outbound.new(logger: logger)
          @fetcher = Util::MediaFetcher.new(limit: MAX_ATTACHMENT_BYTES, logger: logger)
          @index = build_index(endpoints)
          @inbound = Inbound.new(endpoint_for: method(:endpoint_for), logger: logger)
          @started = false
        end

        attr_reader :client

        def replace_client(client)
          @client = client
          self
        end

        def capabilities = CAPABILITIES

        # The origin platform token for the sender label: the domain the bridge's
        # own JID belongs to, so a relayed user reads as "ada@example.org".
        def origin_label(_endpoint = nil)
          jid_domain(settings[:jid]) || self.class.adapter_name.to_s
        end

        # A bare domain cannot say whether a sender is on XMPP, Matrix or IRC, so
        # Core::SenderLabel prefixes the handle with this: "xmpp::ada@example.org".
        def origin_protocol(_endpoint = nil) = "xmpp"

        # A MUC occupant is identified by nick, which is what an echoed message
        # carries and what loop prevention keys on.
        def own_account_id = @nick

        # A 409 nick collision (see Client#join) makes the client fall back to
        # a different nick in one room without touching the others, so this
        # account can be signed in under more than one nick at once. Loop
        # prevention has to recognise an echo under any of them, not just the
        # configured one #own_account_id still reports.
        def own_account_ids = @client.nicks.map { |nick| "occupant:#{nick}" }

        # @started only ever clears in #stop, so it alone would report a
        # connection the server dropped as healthy forever. Asking the client
        # whether its read loop is still up catches that, the same way the IRC
        # adapter already does.
        def running? = @started && @client.alive?

        # One XMPP stream, held open for the life of the process.
        def persistent_connection? = true

        def start
          @client.on_message(&method(:handle_message))
          @client.on_presence(&method(:handle_membership))
          @client.on_dm(&method(:handle_dm))
          @client.connect
          # A refused join (XEP-0045 7.2) is logged and skipped rather than
          # taking the whole adapter down, so a room the bot cannot enter never
          # blocks the ones it can.
          @endpoints.each do |endpoint|
            @client.join(endpoint.settings[:room_jid], @nick)
          rescue AdapterError => e
            logger.error { "xmpp: could not join #{endpoint.settings[:room_jid]}: #{e.message}" }
          end
          @started = true
          logger.info { "joined #{@client.joined_rooms.size} XMPP room(s) as #{@nick}" }
          # Best effort, and never allowed to fail connect.
          discover_rooms if discovery
          start_reconcile_loop
          self
        rescue AdapterError
          raise
        rescue StandardError => e
          raise AdapterError.new("XMPP adapter failed to start: #{e.class}: #{e.message}", adapter: :xmpp)
        end

        def stop
          @client.close
          @started = false
          self
        end

        def deliver(message, endpoint)
          uploaded = upload_credentialed_attachments(message.attachments)
          body = @outbound.compose(message, endpoint, uploaded: uploaded)
          # Nothing to send by design, so Bridge must not record a loss.
          return Core::DeliveryReceipt::NOT_APPLICABLE if body.strip.empty?

          id = @client.say(endpoint.settings[:room_jid], body)
          Core::DeliveryReceipt.new(
            endpoint_id: endpoint.id, native_id: id || "xmpp-#{Time.now.to_f}", extra: notes_extra(message, uploaded)
          )
        rescue AdapterError
          raise
        rescue StandardError => e
          raise AdapterError.new("XMPP send failed: #{e.class}: #{e.message}", adapter: :xmpp, retryable: true)
        end

        # Only called when {Capabilities#deletes?}: XEP-0424 retraction of a
        # message this bot posted.
        def delete(endpoint, native_id)
          @client.retract(endpoint.settings[:room_jid], native_id)
        rescue AdapterError
          raise
        rescue StandardError => e
          raise AdapterError.new("XMPP delete failed: #{e.class}: #{e.message}", adapter: :xmpp, retryable: true)
        end

        # XEP-0444 states the bot's whole reaction set on one message at once,
        # so +previous+ goes unused here the same way Telegram ignores it.
        def sync_reactions(endpoint, native_id, desired:, previous: [])
          @client.react(endpoint.settings[:room_jid], native_id, desired.map(&:label))
        rescue AdapterError
          raise
        rescue StandardError => e
          raise AdapterError.new("XMPP react failed: #{e.class}: #{e.message}", adapter: :xmpp, retryable: true)
        end

        def moderate(command, endpoint, native_id)
          room = endpoint.settings[:room_jid]
          case command.action
          when :kick then moderate_kick(command, endpoint, room)
          when :ban then moderate_ban(command, endpoint, room)
          when :unban then moderate_unban(command, endpoint, room)
          when :delete then moderate_delete(endpoint, room, native_id)
          else
            Core::Moderation::Result.new(endpoint_id: endpoint.id, status: :unsupported)
          end
        rescue PermissionError => e
          Core::Moderation::Result.new(endpoint_id: endpoint.id, status: :forbidden, detail: e.message)
        rescue AdapterError => e
          Core::Moderation::Result.new(endpoint_id: endpoint.id, status: :failed, detail: e.message)
        end

        def describe_endpoint(endpoint)
          "#{endpoint.label} (xmpp room #{endpoint.settings[:room_jid]})"
        end

        # Entry point the client drives, one message Hash at a time.
        def handle_message(event)
          # Learning never consumes the event.
          learn_room(event) if discovery
          emit_if(@inbound.message(event))
        end

        # Entry point the client drives for an occupant's join or leave presence.
        def handle_membership(event)
          emit_if(@inbound.membership(event))
        end

        # Entry point for a direct message to the bot: the operator control
        # lane's receiving half. Logs and drops when no control lane is wired.
        def handle_dm(event)
          jid = event["jid"].to_s
          return if jid.empty?

          if control_lane.nil?
            logger.info { "xmpp: dropped a direct message from #{jid}: no control lane configured" }
            return
          end

          # Only this bare-JID DM lane proves an account. Room occupants carry
          # arbitrary nicknames, which may themselves resemble a bare JID.
          identity = Security::GrantIdentity.native_id(adapter: :xmpp, native_id: "jid:#{jid}")
          return if identity.nil?

          author = Core::Author.new(native_id: identity, username: jid, kind: :user)
          reply = control_lane.handle_dm(adapter: self.class.adapter_name, account: account, author: author,
                                         text: event["body"].to_s)
          @client.send_dm(jid, reply) unless reply.nil?
        rescue StandardError => e
          logger.error { "xmpp: error handling a direct message: #{e.class}: #{e.message}" }
        end

        # DM +text+ to +native_id+ (a bare JID): a plain type="chat" message,
        # the same #send_dm the control lane's own replies use. The JID
        # doubles as the DM's channel_ref, since retracting it later needs
        # nothing #send_admin_dm was not already given.
        def send_admin_dm(native_id, text)
          return nil if text.to_s.strip.empty?

          jid = native_id.to_s.delete_prefix("jid:")
          sent = @client.send_dm(jid, text)
          Core::DmReceipt.new(native_id: sent, channel_ref: jid)
        rescue AdapterError => e
          dm_refused(native_id, e.message)
        end

        # Remove a DM #send_admin_dm sent: the same XEP-0424 retraction the
        # MUC path uses, addressed one to one instead of into a room.
        def delete_admin_dm(receipt)
          return false if receipt.nil? || receipt.channel_ref.nil?

          @client.retract_dm(receipt.channel_ref, receipt.native_id)
          true
        rescue AdapterError => e
          logger.info { "xmpp: could not delete a DM: #{e.message}" }
          false
        end

        def emit_if(message)
          return nil if message.nil?

          emit(message)
          message
        rescue StandardError => e
          logger.error { "error handling an XMPP message: #{e.class}: #{e.message}" }
          nil
        end

        private

        # Told to the sender through Features::Bridge#report_notes, the same
        # signal Discord's note_failed_upload gives when a file never crosses.
        # Empty, not a key holding an empty array, when nothing failed.
        def notes_extra(message, uploaded)
          notes = @outbound.unrelayed_attachments(message, uploaded: uploaded).map do |attachment|
            "could not relay #{attachment.label} to XMPP: the source URL could not be shown"
          end
          notes.empty? ? {} : { notes: notes }
        end

        # A credentialed source url (a Telegram file url embeds the bot token)
        # can never be posted as is, so it is fetched through the hardened
        # fetcher and pushed to the room's XEP-0363 upload service instead. A
        # url Outbound#attachment_link would already print needs none of this.
        #
        # @return [Hash{Core::Attachment => String}] the hosted url XEP-0363
        #   handed back, per attachment that needed one and got one.
        def upload_credentialed_attachments(attachments)
          attachments.each_with_object({}) do |attachment, uploaded|
            next if Util::SafeUrl.public(attachment.url)
            next unless attachment.resolvable?

            url = upload_attachment(attachment)
            uploaded[attachment] = url unless url.nil?
          end
        end

        # Download through the hardened fetcher (SSRF guarded, size capped),
        # then push the bytes to the XEP-0363 upload service. nil on either
        # half failing, which Outbound#attachment_link then reads as "fall
        # back to the could-not-relay marker".
        def upload_attachment(attachment)
          @fetcher.with(attachment.url, filename: attachment.filename) do |file|
            @client.upload(file.read, filename: attachment.filename, content_type: attachment.mime_type)
          end
        rescue StandardError => e
          logger.warn { "xmpp: could not upload an attachment: #{e.class}: #{e.message}" }
          nil
        end

        def ok(endpoint) = Core::Moderation::Result.new(endpoint_id: endpoint.id, status: :done)

        # A kick targets an occupant nick; a ban targets a bare account JID.
        # Strip only the namespace assigned by the corresponding trusted path.
        def moderate_kick(command, endpoint, room)
          nick = command.target_user_id.to_s.delete_prefix("occupant:")
          @client.kick(room, nick, reason: "bridged /kick by #{command.issuer}")
          ok(endpoint)
        end

        def moderate_ban(command, endpoint, room)
          @client.ban(room, command.target_user_id.to_s.delete_prefix("jid:"), reason: "bridged /ban by #{command.issuer}")
          ok(endpoint)
        end

        def moderate_unban(command, endpoint, room)
          @client.unban(room, command.target_user_id.to_s.delete_prefix("jid:"))
          ok(endpoint)
        end

        # No target message resolved (a reply-less /delete the feature could not
        # place) reads as unsupported here rather than attempting a retract with
        # nothing to retract.
        def moderate_delete(endpoint, room, native_id)
          return Core::Moderation::Result.new(endpoint_id: endpoint.id, status: :unsupported) if native_id.nil?

          @client.retract(room, native_id)
          ok(endpoint)
        end

        # What {#reconcile_channels} joins against: room JIDs the client
        # believes it has joined.
        def joined_route_keys = @client.joined_rooms

        def join_route(route_key, _endpoint)
          @client.join(route_key, @nick)
          logger.info { "xmpp: joined #{route_key} (live snapshot reconcile)" }
        rescue AdapterError => e
          logger.warn { "xmpp: could not join #{route_key} during reconcile: #{e.message}" }
        end

        # Learn a room from a live groupchat message, the passive source every
        # server supports with no configuration. The nick check excludes a stanza
        # with no occupant behind it; an empty body still proves the room is real.
        def learn_room(event)
          room_jid = event["room_jid"].to_s
          return if room_jid.empty?
          return if presence(event["nick"]).nil?

          @discovery.saw(
            adapter: :xmpp, account: account, external_id: muc_domain(room_jid),
            route_key: room_jid, name: nil
          )
        rescue StandardError => e
          logger.warn { "xmpp: room discovery failed: #{e.class}: #{e.message}" }
          nil
        end

        # Active enumeration at connect: XEP-0048 bookmarks, plus a XEP-0030
        # disco#items sweep of settings[:muc_service]. Rooms are recorded once per
        # MUC domain, since one account's bookmarks can span several domains.
        def discover_rooms
          rooms = (@client.bookmarked_rooms + disco_rooms).uniq { |room| room[:id] }
          return if rooms.empty?

          rooms.group_by { |room| muc_domain(room[:id]) }.each do |domain, group|
            @discovery.inventory(adapter: :xmpp, account: account, external_id: domain, channels: group)
          end
        rescue StandardError => e
          logger.warn { "xmpp: room enumeration failed: #{e.class}: #{e.message}" }
        end

        # Skipped with no query sent when no muc_service is configured. There is
        # no default to guess: a server can host several MUC services unrelated to
        # the bot's own JID.
        def disco_rooms
          service = settings[:muc_service]
          return [] if presence(service).nil?

          @client.discover_rooms(service)
        end

        # The MUC service domain out of a room JID, the coarse space for discovery.
        def muc_domain(room_jid) = self.class.muc_domain(room_jid)

        def presence(value)
          return nil if value.nil?

          string = value.to_s.strip
          string.empty? ? nil : string
        end

        def jid_localpart(jid) = jid.to_s.split("@", 2).first

        # "bridge@example.org" -> "example.org", for the sender label's origin token.
        def jid_domain(jid)
          domain = jid.to_s.split("@", 2)[1]
          domain.nil? || domain.empty? ? nil : domain
        end

        def build_index(endpoints)
          endpoints.each_with_object({}) do |endpoint, index|
            index[endpoint.settings[:room_jid].to_s] = endpoint
          end
        end

        def endpoint_for(room_jid)
          if @endpoint_resolver
            return nil if room_jid.nil?

            return @endpoint_resolver.endpoint_for(:xmpp, account, room_jid.to_s)
          end

          return nil if room_jid.nil?

          @index[room_jid.to_s]
        end
      end
    end
  end
end
