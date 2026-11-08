# frozen_string_literal: true

# The platform adapter contract, written once and run against every adapter, the way
# spec/support/sequel_backend_contract.rb is run against every Sequel backend, driven from
# spec/adapters/contract_spec.rb. The rules themselves live in lib/rubotty/adapters/base.rb;
# what lives here is only the part a spec cannot read off the class: how to build one adapter
# against its fakes, which endpoints are worth exercising, and where an adapter genuinely
# cannot comply, declared in its profile with a reason rather than left out of the walk
# unnoticed.
module AdapterContract
  # Channel management only ever runs under the control plane, where every
  # endpoint carries the community that owns it, so the fixtures that exercise
  # it carry one too. Any id will do; what matters is that it is the same one
  # the endpoints have.
  CONTRACT_COMMUNITY_ID = 1

  # A live adapter and the seams the contract reaches through, one field per fixture. +declines+ and
  # +sends+ are label => [endpoint, message]: a decline answers NOT_APPLICABLE, a send returns a
  # receipt, both lists since one adapter can address a platform more than one way. +started+ has
  # #start called against its fakes, the only fixture where #own_account_id is populated in time to
  # test loop prevention; the caller owns #stop. +truthy_returns+ is label => {happy:, unhappy:,
  # raises:}, one entry per documented-truthy method this adapter implements. +membership_event+ and
  # +bulk_delete_event+ feed the adapter its own raw native event and hand back what the dispatcher
  # recorded, so a :native/:compacted claim can be checked against real behaviour.
  Harness = Struct.new(
    :adapter, :endpoints, :declines, :sends, :native_id, :dm_target,
    :refuse_reaction, :moderation_action, :moderation_target, :break_moderation,
    :started, :truthy_returns, :membership_event, :bulk_delete_event,
    keyword_init: true
  )

  # @param supports [Array<Symbol>] optional parts this adapter answers true for
  # @param not_written_here [Hash<Symbol, String>] false because nobody's written it, though the platform could carry it
  # @param platform_cannot [Hash<Symbol, String>] false because the platform itself never can, unlike not_written_here
  # @param capability_reasons [Hash<Symbol, String>] why a false {CAPABILITY_METHODS} floor answer is false
  # @param lifecycle [Hash<Symbol, Array(Symbol, String)>] [state, reason] per {LIFECYCLE_PARTS} entry
  # @param negotiable [Hash<Symbol, String>] false-floor capabilities #capabilities_for can still raise on
  # @param exemptions [Hash<Symbol, String>] contract properties this adapter is excused from, with reasons
  # @param route_key_aliases [Array<Array<Hash>>] endpoint-setting groups naming the SAME channel
  class Profile
    # The only properties an adapter may excuse itself from, so a typo in an
    # exemption key cannot quietly turn a rule off.
    PROPERTIES = %i[route_key_for constructor sends].freeze

    # +puppeting+ is send:, edit: and, where either is false, why not.
    # +narrowable+ says why an instance may declare LESS than its own constant,
    # the mirror of +negotiable+; nil means it may not.
    attr_reader :name, :adapter_class, :settings, :sample, :supports, :not_written_here,
                :platform_cannot, :capability_reasons, :lifecycle, :negotiable, :exemptions,
                :persistent_connection, :route_key_aliases, :puppeting, :narrowable

    def initialize(name, adapter_class:, build:, persistent_connection:, settings: nil,
                   sample: nil, supports: [], not_written_here: {}, platform_cannot: {},
                   capability_reasons: {}, lifecycle: {}, negotiable: {},
                   exemptions: {}, route_key_aliases: [], puppeting: {}, narrowable: nil)
      @name = name
      @adapter_class = adapter_class
      @build = build
      @settings = settings
      @sample = sample
      @supports = supports.freeze
      @not_written_here = not_written_here.freeze
      @platform_cannot = platform_cannot.freeze
      @capability_reasons = capability_reasons.freeze
      @lifecycle = lifecycle.freeze
      @negotiable = negotiable.freeze
      @exemptions = exemptions.freeze
      @persistent_connection = persistent_connection
      @route_key_aliases = route_key_aliases.freeze
      @puppeting = puppeting.freeze
      @narrowable = narrowable
      freeze
    end

    def build(context) = @build.call(context)

    def exempt?(property) = @exemptions.key?(property)

    def unknown_exemptions = @exemptions.keys - PROPERTIES
  end

  # Every optional part of the contract, as the +supports_x?+ question and the
  # method that has to exist behind a yes. An adapter answering yes with Base's
  # own no-op still behind it is the shape the audit found repeatedly.
  OPTIONAL_PARTS = {
    leave: %i[supports_leave? leave_space],
    space_notice: %i[supports_space_notice? post_space_notice],
    space_enumeration: %i[supports_space_enumeration? enumerate_space],
    admin_dm: %i[supports_admin_dm? send_admin_dm],
    admin_dm_delete: %i[supports_admin_dm_delete? delete_admin_dm],
    backfill: %i[supports_backfill? backfill_messages],
    gap_ownership: %i[supports_gap_ownership? backfill_candidates],
    reaction_backfill: %i[supports_reaction_backfill? backfill_reactions],
    native_events: %i[supports_native_events? create_scheduled_event],
    channel_management: %i[supports_channel_management? create_channel]
  }.freeze

  # The capability-gated half of the same idea: declaring the capability is what
  # obliges the adapter to implement the method, and implementing it without
  # declaring it means the code can never run.
  CAPABILITY_METHODS = {
    edits?: :edit,
    deletes?: :delete,
    reactions?: :sync_reactions
  }.freeze

  # Message-kind lifecycle parts outside both {OPTIONAL_PARTS} and {CAPABILITY_METHODS}:
  # reached through inbound/outbound paths no flag names, so silent no-ops go uncaught.
  #
  #   attachment_upload:     a file relayed onto this platform
  #   membership_produce:    a join/leave built from this platform's OWN event
  #   custom_emoji_crossing: a reaction naming another platform's custom emoji, placed here
  #   bulk_delete:           many messages removed by one platform event
  LIFECYCLE_PARTS = %i[attachment_upload membership_produce custom_emoji_crossing bulk_delete].freeze

  # Every legitimate answer a {LIFECYCLE_PARTS} entry can give. :native and
  # :compacted are the two ways of actually doing something; :unwritten and
  # :impossible are the two ways of doing nothing, and the only difference
  # between them and the silence this exists to catch is that they say so.
  LIFECYCLE_STATES = %i[native compacted unwritten impossible].freeze

  # What every adapter must override, whatever else it declines to do.
  REQUIRED_CLASS_METHODS = %i[adapter_name account_schema endpoint_schema].freeze
  REQUIRED_INSTANCE_METHODS = %i[start stop own_account_id capabilities deliver].freeze

  # A native id every harness stores a message under, so one contract example
  # can name a target without knowing whose platform it is on.
  TARGET_ID = "700"

  # What "already gone" has to mean, and what it must never be stretched to
  # cover. One wording per platform, plus the two refusals the whole rule exists
  # to keep out: a swallowed 403 or 429 is what leaves storage believing in an
  # emoji or a copy the platform does not have.
  GONE_CASES = {
    "Fluxer delete failed (404): Unknown Message" => true,
    "Stoat request failed: NotFound" => true,
    "Matrix redact failed (404 M_NOT_FOUND)" => true,
    "Telegram deleteMessage failed (400): message to delete not found" => true,
    "Telegram editMessageText failed (400): message to edit not found" => true,
    "403 Missing Permissions" => false,
    "429 Too Many Requests, retry after 30" => false,
    "Telegram refused deleteMessage: Forbidden: bot is not a member of the supergroup chat" => false,
    "the connection reset while sending" => false
  }.freeze

  module_function

  def profile(name) = PROFILES.fetch(name)

  def dispatcher = Fakes::RecordingDispatcher.new

  def logger = Rubotty::Log.null

  # A message with nothing in it: no body, no attachments, and an author with no
  # name to prefix. Every adapter's "there was nothing to send" guard is reached
  # this way, which is the case #deliver must answer NOT_APPLICABLE for.
  def blank_message(context, origin)
    context.message(origin, text: "", author: Rubotty::Core::Author.new(native_id: "u1"))
  end

  def ordinary_message(context, origin)
    context.message(origin, text: "hello",
                            author: Rubotty::Core::Author.new(native_id: "u1", username: "ada"))
  end

  def thumbs = Rubotty::Core::Reaction.new(emoji: "\u{1F44D}")

  def command(action, origin, target_user_id: nil)
    Rubotty::Core::Moderation::Command.new(
      action: action,
      issuer: Rubotty::Core::Moderation::Operator.new(name: "mod"),
      origin: origin,
      target_user_id: target_user_id
    )
  end

  PROFILES = {
    telegram: Profile.new(
      :telegram,
      adapter_class: Rubotty::Adapters::Telegram::Adapter,
      persistent_connection: false,
      settings: { token: "123:abc", transport: :long_polling },
      sample: { route_key: "-1008000000001/142483", external_id: "-1008000000001" },
      supports: %i[leave space_notice admin_dm admin_dm_delete channel_management],
      not_written_here: {
        backfill: "Telegram has no history API, so a sweep has nothing to read",
        space_enumeration: "a bot is told about one chat at a time and cannot list a space"
      },
      platform_cannot: {
        gap_ownership: "backfill_candidates has nothing to pair, the history API it would read does not exist",
        reaction_backfill: "Telegram exposes reactions only as live push updates, there is no history to sweep",
        native_events: "Telegram has no native scheduled-event object to create one in"
      },
      puppeting: { send: false, edit: false,
                   reason: "a bot posts as itself; the Bot API has no per message name or avatar override" },
      lifecycle: {
        attachment_upload: [:native, nil],
        membership_produce: [:native, nil],
        custom_emoji_crossing: [:impossible,
                                 "custom emoji reactions are Premium-account only, a bot cannot hold one"],
        bulk_delete: [:impossible, "the Bot API delivers no bulk-delete event to a bot"]
      },
      build: lambda { |context|
        http = Fakes::TelegramHttp.new
        client = Rubotty::Adapters::Telegram::ApiClient.new(token: "123:abc", http: http)
        chat = context.endpoint("tg-general", adapter: :telegram,
                                              settings: { chat_id: "-1008000000001" },
                                              community_id: CONTRACT_COMMUNITY_ID)
        adapter = Rubotty::Adapters::Telegram::Adapter.new(
          account: "tg", settings: { token: "123:abc", transport: :long_polling },
          dispatcher: dispatcher, logger: logger, endpoints: [chat]
        ).replace_client(client)

        Harness.new(
          adapter: adapter,
          endpoints: { "a chat" => chat },
          declines: { "an empty body with nothing attached" => [chat, blank_message(context, chat)] },
          sends: { "an ordinary message" => [chat, ordinary_message(context, chat)] },
          native_id: TARGET_ID,
          dm_target: "55",
          refuse_reaction: lambda { |error|
            context.allow(client).to context.receive(:call_tolerating_gone).and_raise(error)
          },
          moderation_action: :delete,
          moderation_target: "55",
          started: lambda {
            http.on("getMe", { "id" => 999, "username" => "bridgebot" })
            http.on("deleteWebhook", true)
            http.on("getUpdates", [])
            adapter.start
          },
          break_moderation: lambda {
            context.allow(client).to context.receive(:call_tolerating_gone).and_raise(RuntimeError.new("boom"))
            context.allow(client).to context.receive(:call).and_raise(RuntimeError.new("boom"))
          },
          truthy_returns: {
            leave_space: {
              happy: -> { adapter.leave_space("-1008000000001") },
              unhappy: lambda {
                context.allow(client).to context.receive(:call)
                                        .and_raise(Rubotty::AdapterError.new("boom", adapter: :telegram))
                adapter.leave_space("-1008000000001")
              }
            },
            post_space_notice: {
              happy: -> { adapter.post_space_notice("-1008000000001", "a notice") },
              unhappy: lambda {
                context.allow(client).to context.receive(:call)
                                        .and_raise(Rubotty::AdapterError.new("boom", adapter: :telegram))
                adapter.post_space_notice("-1008000000001", "a notice")
              }
            },
            create_channel: {
              happy: lambda {
                http.on("createForumTopic", { "message_thread_id" => 777 })
                adapter.create_channel(name: "new-topic", community_id: CONTRACT_COMMUNITY_ID)
              },
              unhappy: lambda {
                context.allow(client).to context.receive(:call)
                                        .and_raise(Rubotty::AdapterError.new("boom", adapter: :telegram))
                adapter.create_channel(name: "new-topic", community_id: CONTRACT_COMMUNITY_ID)
              },
              raises: true
            },
            delete_channel: {
              happy: -> { adapter.delete_channel("777", community_id: CONTRACT_COMMUNITY_ID) },
              unhappy: lambda {
                context.allow(client).to context.receive(:call)
                                        .and_raise(Rubotty::AdapterError.new("boom", adapter: :telegram))
                adapter.delete_channel("777", community_id: CONTRACT_COMMUNITY_ID)
              },
              raises: true
            }
          }
        )
      }
    ),

    discord: Profile.new(
      :discord,
      adapter_class: Rubotty::Adapters::Discord::Adapter,
      persistent_connection: true,
      settings: { token: "t" },
      sample: { route_key: "800000000000000011", external_id: "70707070" },
      supports: %i[leave space_notice space_enumeration admin_dm admin_dm_delete
                   backfill gap_ownership reaction_backfill native_events channel_management],
      puppeting: { send: true, edit: true },
      lifecycle: {
        attachment_upload: [:native, nil],
        membership_produce: [:native, nil],
        custom_emoji_crossing: [:compacted,
                                 "a foreign platform's custom id can never resolve on Discord's own emoji " \
                                 "registry, so Bridge#mirror_reactions keeps it out of sync_reactions and " \
                                 "degrades it to a text notice instead"],
        bulk_delete: [:native, nil]
      },
      build: lambda { |context|
        client = DiscordFakes::Client.new
        bot = context.endpoint("dc-bot", adapter: :discord,
                                         settings: { channel_id: "8000000000000000003", webhook: :off })
        hooked = context.endpoint("dc-hooked", adapter: :discord,
                                               settings: { channel_id: "222222222", webhook: :auto })
        adapter = Rubotty::Adapters::Discord::Adapter.new(
          account: "dc", settings: { token: "t" }, dispatcher: dispatcher, logger: logger,
          endpoints: [bot, hooked]
        ).replace_client(client)
        target = DiscordFakes::Message.new(
          id: TARGET_ID, content: "hi", author: DiscordFakes.user(id: "55", username: "ada")
        )
        client.channel("8000000000000000003").store(target)

        # create_channel reads its guild from an endpoint's guild_id, and
        # enumerate_space needs a discovery seam neither bot nor hooked above
        # carries, so both live on a second, otherwise identical adapter
        # rather than adding a guild_id nothing else here reads.
        mgmt_client = DiscordFakes::Client.new
        mgmt_endpoint = context.endpoint("dc-mgmt", adapter: :discord,
                                                     settings: { channel_id: "300000000",
                                                                 guild_id: "70707070", webhook: :off },
                                                     community_id: CONTRACT_COMMUNITY_ID)
        mgmt_adapter = Rubotty::Adapters::Discord::Adapter.new(
          account: "dc-mgmt", settings: { token: "t" }, dispatcher: dispatcher, logger: logger,
          endpoints: [mgmt_endpoint], discovery: Object.new
        ).replace_client(mgmt_client)

        Harness.new(
          adapter: adapter,
          endpoints: { "a channel" => bot, "a channel with a webhook" => hooked },
          declines: {
            "an empty body posted as the bot" => [bot, blank_message(context, bot)],
            "an empty body posted through a webhook" => [hooked, blank_message(context, hooked)]
          },
          sends: {
            "an ordinary message as the bot" => [bot, ordinary_message(context, bot)],
            "an ordinary message through a webhook" => [hooked, ordinary_message(context, hooked)]
          },
          native_id: TARGET_ID,
          dm_target: "55",
          refuse_reaction: lambda { |error|
            context.allow(target).to context.receive(:create_reaction).and_raise(error)
          },
          moderation_action: :delete,
          moderation_target: "55",
          started: lambda { adapter.start },
          break_moderation: lambda {
            context.allow(client).to context.receive(:channel).and_raise(RuntimeError.new("boom"))
          },
          truthy_returns: {
            leave_space: {
              happy: -> { adapter.leave_space("70707070") },
              unhappy: lambda {
                context.allow(client).to context.receive(:leave_server).and_raise(RuntimeError.new("boom"))
                adapter.leave_space("70707070")
              }
            },
            post_space_notice: {
              happy: -> { adapter.post_space_notice("70707070", "a notice") },
              unhappy: lambda {
                context.allow(client).to context.receive(:post_guild_notice).and_raise(RuntimeError.new("boom"))
                adapter.post_space_notice("70707070", "a notice")
              }
            },
            enumerate_space: {
              happy: -> { mgmt_adapter.enumerate_space("70707070") },
              unhappy: lambda {
                context.allow(mgmt_client).to context.receive(:guild_text_channels)
                                              .and_raise(RuntimeError.new("boom"))
                mgmt_adapter.enumerate_space("70707070")
              }
            },
            create_channel: {
              happy: -> { mgmt_adapter.create_channel(name: "new-channel", community_id: CONTRACT_COMMUNITY_ID) },
              unhappy: lambda {
                context.allow(mgmt_client).to context.receive(:create_guild_channel)
                                              .and_raise(Rubotty::AdapterError.new("boom", adapter: :discord))
                mgmt_adapter.create_channel(name: "new-channel", community_id: CONTRACT_COMMUNITY_ID)
              },
              raises: true
            },
            delete_channel: {
              happy: -> { adapter.delete_channel("900101", community_id: CONTRACT_COMMUNITY_ID) },
              unhappy: lambda {
                context.allow(client).to context.receive(:delete_guild_channel)
                                        .and_raise(Rubotty::AdapterError.new("boom", adapter: :discord))
                adapter.delete_channel("900101", community_id: CONTRACT_COMMUNITY_ID)
              },
              raises: true
            },
            copy_channel_permissions: {
              happy: lambda {
                client.set_permission_overwrites("900101", [{ id: "role1", allow: "1", deny: "0" }])
                adapter.copy_channel_permissions(from: "900101", to: "900102")
              },
              unhappy: lambda {
                context.allow(client).to context.receive(:copy_permission_overwrites)
                                        .and_raise(Rubotty::AdapterError.new("boom", adapter: :discord))
                adapter.copy_channel_permissions(from: "900101", to: "900102")
              },
              raises: true
            }
          }
        )
      }
    ),

    fluxer: Profile.new(
      :fluxer,
      adapter_class: Rubotty::Adapters::Fluxer::Adapter,
      persistent_connection: true,
      settings: { token: "t" },
      sample: { route_key: "900001", external_id: "8000000000000000008" },
      supports: %i[leave space_notice space_enumeration admin_dm admin_dm_delete],
      not_written_here: {
        backfill: "channel history is readable, nobody has written the sweep here",
        gap_ownership: "backfill itself is not written yet, so there is nothing to pair an ownership answer with",
        reaction_backfill: "the history sweep this would ride on is not written yet either",
        native_events: "nobody has checked whether Fluxer exposes a scheduled-event object to mirror this into",
        channel_management: "channels can be created and deleted over REST, nobody has wired it here"
      },
      puppeting: { send: true, edit: true },
      lifecycle: {
        attachment_upload: [:unwritten,
                             "AttachmentUploadService takes a multipart upload the same way Discord's does, " \
                             "nobody has wired it here, so a link is posted instead"],
        membership_produce: [:native, nil],
        custom_emoji_crossing: [:compacted,
                                 "a foreign platform's custom id can never resolve on Fluxer's own emoji " \
                                 "registry, so Bridge#mirror_reactions keeps it out of sync_reactions and " \
                                 "degrades it to a text notice instead"],
        bulk_delete: [:compacted,
                      "message_delete_bulk names many ids in one frame, so handle_bulk_delete expands it " \
                      "into one emitted delete per id"]
      },
      build: lambda { |context|
        client = FluxerFakes::Client.new
        # guild_id lets GUILD_MEMBER_ADD/REMOVE, which name only a guild, route to
        # this endpoint the same way ban and kick already resolve one; it is the
        # same guild the profile's own sample external_id names.
        bot = context.endpoint("fx-bot", adapter: :fluxer,
                                         settings: { channel_id: "111111111",
                                                     guild_id: "8000000000000000008", webhook: :off })
        hooked = context.endpoint("fx-hooked", adapter: :fluxer,
                                               settings: { channel_id: "222222222", webhook: :auto })
        adapter = Rubotty::Adapters::Fluxer::Adapter.new(
          account: "fx", settings: { token: "t" }, dispatcher: dispatcher, logger: logger,
          endpoints: [bot, hooked]
        ).replace_client(client).replace_gateway(FluxerFakes::Gateway.new)

        # enumerate_space answers true the moment discovery is wired and the
        # guild id is non-blank, whatever the platform call behind it does,
        # so it needs its own discovery seam rather than a stubbed refusal.
        mgmt_client = FluxerFakes::Client.new
        mgmt_adapter = Rubotty::Adapters::Fluxer::Adapter.new(
          account: "fx-mgmt", settings: { token: "t" }, dispatcher: dispatcher, logger: logger,
          endpoints: [], discovery: Object.new
        ).replace_client(mgmt_client).replace_gateway(FluxerFakes::Gateway.new)

        Harness.new(
          adapter: adapter,
          endpoints: { "a channel" => bot, "a channel with a webhook" => hooked },
          declines: {
            "an empty body posted as the bot" => [bot, blank_message(context, bot)],
            "an empty body posted through a webhook" => [hooked, blank_message(context, hooked)]
          },
          sends: {
            "an ordinary message as the bot" => [bot, ordinary_message(context, bot)],
            "an ordinary message through a webhook" => [hooked, ordinary_message(context, hooked)]
          },
          native_id: TARGET_ID,
          dm_target: "55",
          refuse_reaction: lambda { |error|
            context.allow(client).to context.receive(:add_reaction).and_raise(error)
          },
          moderation_action: :delete,
          moderation_target: "55",
          started: lambda { adapter.start },
          break_moderation: lambda {
            context.allow(client).to context.receive(:delete_message).and_raise(RuntimeError.new("boom"))
          },
          truthy_returns: {
            enumerate_space: {
              happy: -> { mgmt_adapter.enumerate_space("70707070") },
              unhappy: -> { mgmt_adapter.enumerate_space("") }
            }
          },
          membership_event: lambda {
            adapter.handle_event(
              FluxerFakes.dispatch("GUILD_MEMBER_ADD",
                                   FluxerFakes.member_data(guild_id: "8000000000000000008"))
            )
            adapter.dispatcher.messages
          },
          bulk_delete_event: lambda {
            adapter.handle_event(
              FluxerFakes.dispatch("MESSAGE_DELETE_BULK", { "channel_id" => "111111111", "ids" => %w[701 702] })
            )
          }
        )
      }
    ),

    stoat: Profile.new(
      :stoat,
      adapter_class: Rubotty::Adapters::Stoat::Adapter,
      persistent_connection: true,
      settings: { token: "t" },
      sample: { route_key: "CHAN01", external_id: "SRV1" },
      supports: %i[space_notice space_enumeration admin_dm admin_dm_delete],
      not_written_here: {
        leave: "a bot can leave a Stoat server, nobody has written it here",
        backfill: "channel history is readable, nobody has written the sweep here",
        gap_ownership: "backfill itself is not written yet, so there is nothing to pair an ownership answer with",
        reaction_backfill: "the history sweep this would ride on is not written yet either",
        native_events: "nobody has checked whether Stoat exposes a scheduled-event object to mirror this into",
        channel_management: "channels can be created and deleted over REST, nobody has wired it here"
      },
      puppeting: { send: true, edit: true },
      lifecycle: {
        attachment_upload: [:unwritten,
                             "the bot-upload endpoint takes a multipart POST returning a usable id, nobody " \
                             "has wired it here, so a link is posted instead"],
        membership_produce: [:native, nil],
        custom_emoji_crossing: [:impossible, "a foreign custom emoji has no equivalent on a Stoat server"],
        bulk_delete: [:compacted,
                      "BulkMessageDelete names many ids in one frame, so handle_bulk_delete expands it " \
                      "into one emitted delete per id"]
      },
      build: lambda { |context|
        client = StoatFakes::Client.new
        channel = context.endpoint("st-general", adapter: :stoat, settings: { channel_id: "CHAN01" })
        adapter = Rubotty::Adapters::Stoat::Adapter.new(
          account: "st", settings: { token: "t" }, dispatcher: dispatcher, logger: logger,
          endpoints: [channel]
        ).replace_client(client).replace_gateway(StoatFakes::Gateway.new)

        # enumerate_space also needs at least one channel already cached
        # against the server (normally learned from a live Ready/ServerCreate
        # event), so its own adapter seeds that cache directly rather than
        # replaying a gateway event nothing else here needs.
        mgmt_client = StoatFakes::Client.new
        mgmt_adapter = Rubotty::Adapters::Stoat::Adapter.new(
          account: "st-mgmt", settings: { token: "t" }, dispatcher: dispatcher, logger: logger,
          endpoints: [], discovery: Object.new
        ).replace_client(mgmt_client).replace_gateway(StoatFakes::Gateway.new)
        mgmt_adapter.send(:remember_channel_server, "CHAN99", "SRV1")

        Harness.new(
          adapter: adapter,
          endpoints: { "a channel" => channel },
          declines: { "an empty body with nothing attached" => [channel, blank_message(context, channel)] },
          sends: { "an ordinary message" => [channel, ordinary_message(context, channel)] },
          native_id: TARGET_ID,
          dm_target: "u-ada",
          refuse_reaction: lambda { |error|
            context.allow(client).to context.receive(:add_reaction).and_raise(error)
          },
          moderation_action: :delete,
          moderation_target: "u-bad",
          started: lambda { adapter.start },
          break_moderation: lambda {
            context.allow(client).to context.receive(:delete_message).and_raise(RuntimeError.new("boom"))
          },
          truthy_returns: {
            enumerate_space: {
              happy: -> { mgmt_adapter.enumerate_space("SRV1") },
              unhappy: -> { mgmt_adapter.enumerate_space("") }
            }
          }
        )
      }
    ),

    matrix: Profile.new(
      :matrix,
      adapter_class: Rubotty::Adapters::Matrix::Adapter,
      persistent_connection: true,
      settings: { token: "t", homeserver: "https://example.org" },
      sample: { route_key: "!abc123:example.org", external_id: "mx-account" },
      supports: %i[leave space_notice backfill gap_ownership reaction_backfill admin_dm admin_dm_delete],
      not_written_here: {
        space_enumeration: "joined_rooms already lists every room this account can see, nobody has wired it " \
                           "to a second enumeration call",
        native_events: "nobody has checked whether a scheduled-event object exists here to mirror this into",
        channel_management: "rooms can be created and left over the client API, nobody has wired it here"
      },
      puppeting: { send: false, edit: false,
                   reason: "posting as somebody else needs an application service and a namespace of " \
                           "ghost users; a plain client account can only ever speak as itself" },
      lifecycle: {
        attachment_upload: [:native, nil],
        membership_produce: [:native, nil],
        custom_emoji_crossing: [:impossible,
                                 "a foreign custom emoji has no Matrix equivalent, only unicode reactions " \
                                 "are placed"],
        bulk_delete: [:impossible, "Matrix redacts one event at a time, there is no bulk-delete primitive"]
      },
      build: lambda { |context|
        client = MatrixFakes::Client.new
        room = context.endpoint("mx-general", adapter: :matrix,
                                              settings: { room_id: "!room:example.org" })
        adapter = Rubotty::Adapters::Matrix::Adapter.new(
          account: "mx", settings: { token: "t", homeserver: "https://example.org" },
          dispatcher: dispatcher, logger: logger, endpoints: [room]
        ).replace_client(client).replace_sync(MatrixFakes::Sync.new)

        Harness.new(
          adapter: adapter,
          endpoints: { "a room" => room },
          declines: { "an empty body with nothing attached" => [room, blank_message(context, room)] },
          sends: { "an ordinary message" => [room, ordinary_message(context, room)] },
          native_id: "$m1",
          dm_target: "@ada:example.org",
          refuse_reaction: lambda { |error|
            context.allow(client).to context.receive(:send_event).and_raise(error)
          },
          moderation_action: :delete,
          moderation_target: "@bad:example.org",
          started: lambda { adapter.start },
          break_moderation: lambda {
            context.allow(client).to context.receive(:redact).and_raise(RuntimeError.new("boom"))
          },
          truthy_returns: {
            leave_space: {
              happy: -> { adapter.leave_space("!room:example.org") },
              unhappy: lambda {
                context.allow(client).to context.receive(:leave_room)
                                        .and_raise(Rubotty::AdapterError.new("boom", adapter: :matrix))
                adapter.leave_space("!room:example.org")
              }
            },
            post_space_notice: {
              happy: -> { adapter.post_space_notice("!room:example.org", "a notice") },
              unhappy: lambda {
                context.allow(client).to context.receive(:send_event)
                                        .and_raise(Rubotty::AdapterError.new("boom", adapter: :matrix))
                adapter.post_space_notice("!room:example.org", "a notice")
              }
            }
          }
        )
      }
    ),

    xmpp: Profile.new(
      :xmpp,
      adapter_class: Rubotty::Adapters::Xmpp::Adapter,
      persistent_connection: true,
      settings: { jid: "bot@example.org", password: "s" },
      sample: { route_key: "room@conference.example.org", external_id: "conference.example.org" },
      supports: %i[admin_dm admin_dm_delete],
      not_written_here: {
        leave: "an unavailable presence to one room is exactly what #stop sends for every room, nobody has " \
               "wired it to a single space",
        space_notice: "an ordinary groupchat stanza can be sent to any room_jid already joined, nobody has " \
                      "wired a bare external_id notice poster",
        space_enumeration: "disco#items against the MUC domain could list its rooms, nobody has wired it here",
        backfill: "XEP-0313 archive queries could read room history where a server supports it, nobody has " \
                  "wired it here",
        gap_ownership: "backfill itself is not written yet, so there is nothing to pair an ownership answer with",
        channel_management: "a MUC room can be created and destroyed over the protocol, nobody has wired it here"
      },
      platform_cannot: {
        reaction_backfill: "reactions have no native representation here at all, there is nothing to backfill",
        native_events: "there is no standard XMPP scheduled-event object to mirror this into"
      },
      capability_reasons: {
        edits?: "XEP-0308 correction only replaces the last message and is not reliably supported across " \
                "MUC implementations, so this floor never claims a native edit",
        deletes?: "no delete stanza is reliably supported across MUC implementations, so this floor never " \
                  "claims a native delete"
      },
      puppeting: { send: false, edit: false,
                   reason: "a MUC occupant is one nick for the whole session, so every relayed line is " \
                           "the bridge speaking and the sender is named in the text" },
      lifecycle: {
        attachment_upload: [:compacted,
                             "XEP-0363 HTTP upload is not universally available across MUC servers, so a " \
                             "link is posted instead"],
        membership_produce: [:unwritten,
                              "join and leave presence stanzas are never read, handle_stanza only processes " \
                              "groupchat message stanzas, and the outbound composer already renders the " \
                              "notice for one relayed in"],
        custom_emoji_crossing: [:impossible, "reactions have no native representation here at all"],
        bulk_delete: [:impossible, "deletes have no native representation here at all, let alone a bulk one"]
      },
      build: lambda { |context|
        client = XmppFakes::Client.new
        room = context.endpoint("xmpp-general", adapter: :xmpp,
                                                settings: { room_jid: "room@conference.example.org" })
        adapter = Rubotty::Adapters::Xmpp::Adapter.new(
          account: "xm", settings: { jid: "bridge@example.org", password: "pw", nick: "rubotty" },
          dispatcher: dispatcher, logger: logger, endpoints: [room]
        ).replace_client(client)

        Harness.new(
          adapter: adapter,
          endpoints: { "a MUC room" => room },
          declines: { "an empty body with nothing attached" => [room, blank_message(context, room)] },
          sends: { "an ordinary message" => [room, ordinary_message(context, room)] },
          native_id: "m1",
          dm_target: "ada@example.org",
          refuse_reaction: lambda { |error|
            context.allow(client).to context.receive(:react).and_raise(error)
          },
          moderation_action: :kick,
          moderation_target: "bad@example.org",
          started: lambda { adapter.start },
          break_moderation: lambda {
            context.allow(client).to context.receive(:kick).and_raise(RuntimeError.new("boom"))
          }
        )
      }
    ),

    irc: Profile.new(
      :irc,
      adapter_class: Rubotty::Adapters::Irc::Adapter,
      persistent_connection: true,
      settings: { server: "irc.example.org", nick: "rubotty" },
      # The RFC 1459 floor deliberately understates what a modern network can
      # do, and #capabilities_for raises it once IRCv3 negotiation has settled,
      # so #delete and #sync_reactions exist behind a floor that says false.
      negotiable: {
        deletes?: "draft/message-redaction, negotiated per connection",
        reactions?: "draft/react, which needs message-tags and msgid together"
      },
      supports: %i[admin_dm],
      not_written_here: {
        leave: "PART for one channel is a single line the client never sends, only QUIT for the whole connection",
        space_notice: "a PRIVMSG can already reach any channel the client is joined to, nobody has wired a " \
                      "bare external_id notice poster",
        space_enumeration: "LIST enumerates every channel on the network, nobody has wired it to a scoped " \
                           "re-enumeration here"
      },
      platform_cannot: {
        backfill: "IRC has no history API, so a sweep has nothing to read",
        gap_ownership: "backfill itself is impossible here, so there is nothing to pair an ownership answer with",
        reaction_backfill: "there is no history API to sweep, whether or not reactions are negotiated",
        native_events: "IRC has no native scheduled-event object to create one in",
        channel_management: "a channel is created by being joined and destroyed by emptying, there is no " \
                            "create or delete call to make",
        admin_dm_delete: "draft/message-redaction is negotiated per connection, so a static yes here would " \
                         "promise a server that never offers it, the same reason the deletes? floor is false"
      },
      capability_reasons: {
        edits?: "IRCv3 has never specified a message-edit mechanism, only draft/message-redaction for delete"
      },
      puppeting: { send: false, edit: false,
                   reason: "one connection is one nick, so every relayed line is the bot speaking and " \
                           "the sender is named in the text" },
      lifecycle: {
        attachment_upload: [:compacted, "a PRIVMSG carries no file, a link is the only way one can ever arrive"],
        membership_produce: [:native, nil],
        custom_emoji_crossing: [:impossible, "reactions have no native representation here at all"],
        bulk_delete: [:impossible, "deletes have no native representation on plain IRC, let alone a bulk one"]
      },
      # An IRC channel name is case insensitive, and every inbound lookup in
      # this adapter downcases before resolving.
      route_key_aliases: [[{ channel: "#Rubotty" }, { channel: "#rubotty" }]],
      build: lambda { |context|
        client = IrcFakes::Client.new(
          negotiated_capabilities: %w[message-tags msgid draft/message-redaction]
        )
        channel = context.endpoint("irc-general", adapter: :irc, settings: { channel: "#general" })
        adapter = Rubotty::Adapters::Irc::Adapter.new(
          account: "irc", settings: { server: "irc.example.org", nick: "rubotty" },
          dispatcher: dispatcher, logger: logger, endpoints: [channel]
        ).replace_client(client)
        adapter.start

        Harness.new(
          adapter: adapter,
          endpoints: { "a channel" => channel },
          declines: { "an empty body with nothing attached" => [channel, blank_message(context, channel)] },
          sends: { "an ordinary message" => [channel, ordinary_message(context, channel)] },
          native_id: "m1",
          dm_target: "ada",
          refuse_reaction: lambda { |error|
            context.allow(client).to context.receive(:react).and_raise(error)
          },
          moderation_action: :kick,
          moderation_target: "bad",
          # Already started above, since #capabilities_for needs the negotiated
          # connection for every other example in the walk. Calling #start a
          # second time would rejoin every channel on the same fake client for
          # no reason, so this seam just hands back the adapter it already is.
          started: lambda { adapter },
          break_moderation: lambda {
            context.allow(client).to context.receive(:kick).and_raise(RuntimeError.new("boom"))
          }
        )
      }
    ),

    guest: Profile.new(
      :guest,
      adapter_class: Rubotty::Adapters::Guest::Adapter,
      persistent_connection: false,
      supports: [],
      not_written_here: {},
      platform_cannot: {
        leave: "a guest holds a session on a room, not membership in a space to leave",
        space_notice: "a guest session has no space of its own to post a notice into",
        space_enumeration: "a guest session has no space of its own to enumerate",
        admin_dm: "a guest holds a session, not an account with a native id to message",
        admin_dm_delete: "a guest holds a session, not an account with a native id to message",
        backfill: "the feed only ever mirrors what already arrived live, there is no history to sweep",
        gap_ownership: "backfill itself is impossible here, so there is nothing to pair an ownership answer with",
        reaction_backfill: "backfill itself is impossible here, so there is nothing to pair a reaction with",
        native_events: "a guest session has no platform of its own to hold a scheduled-event object",
        channel_management: "a guest session has no platform of its own to create or delete a channel on"
      },
      puppeting: { send: false, edit: false,
                   reason: "a guest reads a rendered feed rather than a platform timeline, so the " \
                           "sender is display text and there is no account to post under" },
      lifecycle: {
        attachment_upload: [:native, nil],
        membership_produce: [:impossible,
                              "a guest session observes a room, it is not a member whose own join or leave " \
                              "the platform would ever report"],
        custom_emoji_crossing: [:compacted, "reactions are display-only here, a custom emoji renders as its " \
                                            "shortcode"],
        bulk_delete: [:impossible,
                      "the feed only ever receives whatever the upstream adapter already expanded into " \
                      "single deletes, there is no bulk event of its own"]
      },
      exemptions: {
        route_key_for: "a guest endpoint is synthesised from a feature row, never seeded from YAML",
        constructor: "built by Runtime#build_guest_adapter from services, not from a config account"
      },
      build: lambda { |context|
        _db, models = context.seeded_sample
        config = context.sample_model
        community = models.community.where(slug: "sample").first
        room = models.room.where(community_id: community.id, room_key: "general").first
        feed = Rubotty::ControlPlane::GuestFeed.new(models: models)
        invites = Rubotty::ControlPlane::GuestInvites.new(models: models)
        registry = Rubotty::ControlPlane::Registry.build(models: models, accounts: config.accounts)
        Rubotty::ControlPlane::FeatureControls.new(models: models)
                                              .enable(community: community, selector: "general",
                                                      feature: "guest_portal")
        registry.reload
        invites.issue(community: community, room: room, nickname: "Sam", ttl_seconds: 3600)
        adapter = Rubotty::Adapters::Guest::Adapter.new(
          dispatcher: dispatcher, feed: feed, invites: invites, models: models,
          registry: registry, logger: logger
        )
        live = registry.current.topology.endpoint(Rubotty::Adapters::Guest.endpoint_key_for(room.id))
        roomless = context.endpoint("guest:0", adapter: :guest, settings: {})

        Harness.new(
          adapter: adapter,
          endpoints: { "a room a guest is reading" => live },
          declines: {
            "an endpoint that names no room" => [roomless, ordinary_message(context, roomless)]
          },
          sends: { "an ordinary message" => [live, ordinary_message(context, live)] },
          native_id: TARGET_ID,
          refuse_reaction: lambda { |error|
            context.allow(feed).to context.receive(:record_event).and_raise(error)
          },
          moderation_action: :delete,
          moderation_target: nil,
          started: lambda { adapter.start },
          break_moderation: lambda {
            context.allow(feed).to context.receive(:message).and_raise(RuntimeError.new("boom"))
          }
        )
      }
    ),

    api: Profile.new(
      :api,
      adapter_class: Rubotty::Adapters::Api::Adapter,
      persistent_connection: false,
      supports: [],
      not_written_here: {},
      platform_cannot: {
        leave: "an api endpoint has no external space to leave",
        space_notice: "an api endpoint has no external space to post a notice into",
        space_enumeration: "an api endpoint has no external space to enumerate",
        admin_dm: "an api endpoint has no native user id to message",
        admin_dm_delete: "an api endpoint has no native user id to message",
        backfill: "the queue only ever holds what was posted through it, there is no history to sweep",
        gap_ownership: "backfill itself is impossible here, so there is nothing to pair an ownership answer with",
        reaction_backfill: "backfill itself is impossible here, so there is nothing to pair a reaction with",
        native_events: "an api endpoint has no platform of its own to hold a scheduled-event object",
        channel_management: "an api endpoint has no platform of its own to create or delete a channel on"
      },
      capability_reasons: {
        edits?: "an api endpoint only ever queues an outbound post, nothing is ever read back through it to edit",
        deletes?: "an api endpoint only ever queues an outbound post, nothing is ever read back through it " \
                  "to delete",
        reactions?: "an api endpoint only ever queues an outbound post, there is nothing here to react to"
      },
      puppeting: { send: false, edit: false,
                   reason: "deliver always answers NOT_APPLICABLE, so nothing is ever posted here for " \
                           "a name to sit on" },
      lifecycle: {
        attachment_upload: [:impossible, "deliver always answers NOT_APPLICABLE, nothing is ever sent here"],
        membership_produce: [:impossible, "an api endpoint has no platform of its own to report a join or " \
                                          "leave from"],
        custom_emoji_crossing: [:impossible, "deliver always answers NOT_APPLICABLE, nothing is ever sent here"],
        bulk_delete: [:impossible, "deliver always answers NOT_APPLICABLE, nothing is ever sent here"]
      },
      exemptions: {
        route_key_for: "an api endpoint is synthesised per room, never seeded from YAML",
        constructor: "built by Runtime from services, not from a config account",
        sends: "an api endpoint is synthesised with sends: false, so the fan-out never targets it"
      },
      build: lambda { |context|
        _db, models = context.seeded_sample
        config = context.sample_model
        community = models.community.where(slug: "sample").first
        room = models.room.where(community_id: community.id, room_key: "general").first
        registry = Rubotty::ControlPlane::Registry.build(models: models, accounts: config.accounts)
        adapter = Rubotty::Adapters::Api::Adapter.new(
          dispatcher: dispatcher,
          messages: Rubotty::ControlPlane::ApiMessages.new(models: models),
          models: models, registry: registry, logger: logger
        )
        endpoint = registry.current.topology.endpoint(Rubotty::Adapters::Api.endpoint_key_for(room.id))

        Harness.new(
          adapter: adapter,
          endpoints: { "a room's api endpoint" => endpoint },
          declines: {
            "anything at all, since nothing is ever routed here" =>
              [endpoint, ordinary_message(context, endpoint)]
          },
          sends: {},
          native_id: TARGET_ID,
          refuse_reaction: nil,
          moderation_action: nil,
          moderation_target: nil,
          started: lambda { adapter.start },
          break_moderation: nil
        )
      }
    ),

    api_wrapper: Profile.new(
      :api_wrapper,
      adapter_class: Rubotty::Adapters::ApiWrapper::Adapter,
      persistent_connection: false,
      settings: { webhook_url: "https://example.invalid/hook", signing_secret: "whsec_x" },
      supports: [],
      not_written_here: {
        admin_dm: "the wire protocol could carry a DM as another webhook event to a specific native_id, " \
                  "nobody has wired it here",
        admin_dm_delete: "admin_dm itself is not written yet, so there is nothing to delete",
        channel_management: "the wire protocol could ask the remote to create or delete a channel, nobody " \
                            "has wired it here"
      },
      platform_cannot: {
        leave: "an api_wrapper account has no space above a channel to leave; disconnecting it happens by " \
               "removing the account from configuration",
        space_notice: "same reason as leave: there is no space here, only channels",
        space_enumeration: "channels are configured explicitly rather than discovered, so there is nothing " \
                           "here to enumerate",
        backfill: "this is a push based integration with no way to ask the remote for history it did not " \
                  "already push",
        gap_ownership: "backfill itself is impossible here, so there is nothing to pair an ownership answer with",
        reaction_backfill: "backfill itself is impossible here, so there is nothing to pair a reaction with",
        native_events: "a generic REST integration has no native scheduled-event object of its own to " \
                       "mirror one into"
      },
      puppeting: { send: true, edit: true },
      narrowable: "the remote behind one account is any HTTP system at all, and several of the game servers " \
                  "this shape is meant to cover cannot edit, react or ban; an account lists what it does not " \
                  "have under unsupported and the floor comes down to match",
      lifecycle: {
        attachment_upload: [:native, nil],
        membership_produce: [:native, nil],
        custom_emoji_crossing: [:impossible, "a generic REST integration has no custom emoji registry of its " \
                                             "own for a foreign platform's asset id to resolve against"],
        bulk_delete: [:unwritten, "the wire protocol names one message per delete call, nobody has added a " \
                                  "bulk variant for a remote reporting many removals at once"]
      },
      build: lambda { |context|
        client = Fakes::ApiWrapperClient.new
        support = context.endpoint("acme:support-42", adapter: :api_wrapper, account: "acme",
                                                       settings: { channel_id: "support-42" })
        adapter = Rubotty::Adapters::ApiWrapper::Adapter.new(
          account: "acme", settings: { webhook_url: "https://example.invalid/hook", signing_secret: "whsec_x" },
          dispatcher: dispatcher, logger: logger, endpoints: [support]
        ).replace_client(client)
        # The inbound half needs the table it drains, and this suite already
        # runs with a control plane, so the membership event below exercises
        # the real queue rather than a stand-in for it.
        events = Rubotty::ControlPlane::ApiWrapperEvents.new(models: context.build_models(context.migrated_db))
        adapter.inbound_events = events

        Harness.new(
          adapter: adapter,
          endpoints: { "a bridged channel" => support },
          declines: { "an empty body with nothing attached" => [support, blank_message(context, support)] },
          sends: { "an ordinary message" => [support, ordinary_message(context, support)] },
          native_id: TARGET_ID,
          started: lambda { adapter.start },
          refuse_reaction: lambda { |error|
            context.allow(client).to context.receive(:post).and_raise(error)
          },
          moderation_action: :delete,
          moderation_target: "700",
          break_moderation: lambda {
            context.allow(client).to context.receive(:post).and_raise(RuntimeError.new("boom"))
          },
          membership_event: lambda {
            events.enqueue_join(account: "acme", channel_id: "support-42",
                                author: { native_id: "u1", display_name: "Remote Ada" })
            adapter.receive_pending
            adapter.dispatcher.messages
          }
        )
      }
    )
  }.freeze
end

# Every rule below holds for every adapter. Which examples EXIST for one adapter
# is decided from its declared capabilities and its profile, so a property an
# adapter is exempt from is absent by name rather than passing vacuously.
RSpec.shared_examples "the platform adapter contract" do |adapter_name|
  profile = AdapterContract.profile(adapter_name)
  klass = profile.adapter_class
  # The declared floor, read without building one. The example below pins
  # #capabilities to it, so reading the constant here cannot go stale.
  floor = klass::CAPABILITIES

  let(:profile) { AdapterContract.profile(adapter_name) }
  let(:adapter_class) { klass }
  let(:harness) { profile.build(self) }
  let(:adapter) { harness.adapter }
  let(:capabilities) { adapter.capabilities }
  let(:first_endpoint) { harness.endpoints.values.first }

  # An override of its own, as opposed to Base's answer still sitting underneath.
  def overrides?(method_name)
    adapter_class.instance_method(method_name).owner != Rubotty::Adapters::Base
  end

  def class_overrides?(method_name)
    adapter_class.method(method_name).owner != Rubotty::Adapters::Base.singleton_class
  end

  it "names itself, and declares the two schemas configuration is validated against" do
    missing = AdapterContract::REQUIRED_CLASS_METHODS.reject { |name| class_overrides?(name) }
    expect(missing).to be_empty, "#{adapter_name} inherits Base's raise for .#{missing.join(", .")}"
    expect(adapter_class.adapter_name).to eq(adapter_name)
  end

  it "implements every method the contract requires of every adapter" do
    missing = AdapterContract::REQUIRED_INSTANCE_METHODS.reject { |name| overrides?(name) }
    expect(missing).to be_empty, "#{adapter_name} inherits Base's raise for ##{missing.join(", #")}"
  end

  if profile.narrowable
    # The mirror of negotiable. A transport whose remote genuinely cannot edit
    # or react had no way to say so, and the suite held it to promises it could
    # not keep, which is what blocked bridging a game server through here.
    it "reports at most its declared floor, and says why it may be less" do
      AdapterContract::CAPABILITY_METHODS.each_key do |question|
        next if floor.public_send(question)

        expect(capabilities.public_send(question)).to be(false),
                                                      "#{adapter_name} claims #{question} its own floor denies"
      end
      expect(capabilities.moderation - floor.moderation).to be_empty
      expect(profile.narrowable.to_s.strip).not_to be_empty
    end

    it "narrows to what an instance was told it does not have" do
      narrowed = floor.without(%i[edits ban])
      expect(narrowed.edits?).to be(false)
      expect(narrowed.moderates?(:ban)).to be(false)
      expect(narrowed.deletes?).to be(floor.deletes?)
    end
  else
    it "reports the declared floor from #capabilities" do
      AdapterContract::CAPABILITY_METHODS.each_key do |question|
        expect(capabilities.public_send(question)).to be(floor.public_send(question))
      end
      expect(capabilities.moderation).to eq(floor.moderation)
    end
  end

  it "answers #{profile.persistent_connection} to persistent_connection?, so the nightly cycle knows" do
    expect(adapter.persistent_connection?).to be(profile.persistent_connection)
  end

  # base.rb says #own_account_id must be populated by the time #start returns, since self
  # authorship is the one loop prevention layer entirely this adapter's own responsibility.
  # Nothing short of actually calling #start held anyone to that until now: every other
  # example here runs against an adapter that was only ever built, never started.
  describe "starting" do
    # A small budget rather than an exact figure, since a fake's own overhead
    # (a real control-plane query for guest and api) is real but should never
    # approach it. #start blocking past this is exactly the shape of bug a
    # background gateway connect or an unbounded retry would produce.
    start_budget = 3

    it "populates own_account_id by the time #start returns" do
      live = harness.started.call
      expect(live.own_account_id).not_to be_nil, "#{adapter_name}'s own_account_id is still nil after #start"
    ensure
      live&.stop
    end

    it "returns from #start within #{start_budget}s, so a caller waiting on it is never blocked long" do
      began = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      live = harness.started.call
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - began
      expect(elapsed).to be < start_budget,
                          "#{adapter_name}'s #start took #{elapsed.round(2)}s, past the #{start_budget}s budget"
    ensure
      live&.stop
    end

    it "leaves running? false after #stop" do
      live = harness.started.call
      live.stop
      expect(live.running?).to be(false)
    end
  end

  # base.rb documents seven optional methods as answering something truthy on success and
  # falsy (or, for #delete_channel and its channel_management siblings, an AdapterError) on
  # failure. #send_admin_dm and #delete_admin_dm are exercised end to end above; the other
  # six were declared and never called, so "exists" and "answers what the contract says" differ.
  describe "documented truthy returns" do
    it "answers truthy on the happy path" do
      Hash(harness.truthy_returns).each do |method_name, spec|
        result = spec.fetch(:happy).call
        expect(result).to be_truthy, "#{adapter_name}##{method_name} answered #{result.inspect} on its happy path"
      end
    end

    it "answers honestly once it cannot" do
      Hash(harness.truthy_returns).each do |method_name, spec|
        if spec[:raises]
          expect { spec.fetch(:unhappy).call }.to raise_error(Rubotty::AdapterError),
                                                    "#{adapter_name}##{method_name} did not raise once it could not"
        else
          result = spec.fetch(:unhappy).call
          expect(result).to be_falsy, "#{adapter_name}##{method_name} answered #{result.inspect} once it could not"
        end
      end
    end
  end

  AdapterContract::CAPABILITY_METHODS.each do |question, method_name|
    if floor.public_send(question)
      it "has a real ##{method_name} behind #{question}" do
        complaint = "#{adapter_name} declares #{question} and inherits Base's raise for ##{method_name}"
        expect(overrides?(method_name)).to be(true), complaint
      end
    elsif profile.negotiable.key?(question)
      it "implements ##{method_name} for the #{question} its floor understates" do
        expect(overrides?(method_name)).to be(true)
      end

      it "can actually reach #{question}, so ##{method_name} is not dead code" do
        complaint = "#{adapter_name} says #{question} is negotiable (#{profile.negotiable[question]}) but " \
                    "a connection that negotiated everything still answers false"
        expect(adapter.capabilities_for(first_endpoint).public_send(question)).to be(true), complaint
      end
    else
      it "does not implement ##{method_name} while #{question} answers false" do
        complaint = "#{adapter_name} implements ##{method_name} and nothing can ever call it. Declare the " \
                    "capability, or say in its profile how the capability is negotiated."
        expect(overrides?(method_name)).to be(false), complaint
      end

      it "says why #{question} answers false" do
        reason = profile.capability_reasons[question]
        complaint = "#{adapter_name} answers false to #{question} with no reason on record, so a defect and " \
                    "a design choice read the same"
        expect(reason).to be_a(String), complaint
        expect(reason.strip).not_to be_empty, complaint
      end
    end
  end

  # A native id the directory anchors an identity on has to name one person for
  # longer than one session, and nothing said which platforms' do.
  it "declares how durable its identity is, from the stated vocabulary" do
    expect(Rubotty::Adapters::Base::IDENTITY_DURABILITY).to include(adapter_class.identity_durability)
    expect(Rubotty::Adapters::Base::IDENTITY_DURABILITY).to include(adapter.identity_durability)
  end

  # Held both ways: the profile cannot claim what the adapter does not declare,
  # and an adapter that does not puppet has to say why.
  describe "puppeting" do
    it "declares whether a relayed message can wear the sender's own name" do
      declared = profile.puppeting
      expect(declared).to include(:send, :edit),
                          "#{adapter_name} has no puppeting entry in its profile, so nobody can tell whether " \
                          "it can post under the sender's name or simply never had it written"
      expect(floor.puppets_send?).to be(declared[:send])
      expect(floor.puppets_edit?).to be(declared[:edit])
    end

    it "says why, where either half does not puppet" do
      next if profile.puppeting[:send] && profile.puppeting[:edit]

      reason = profile.puppeting[:reason]
      complaint = "#{adapter_name} does not puppet and gives no reason, so a platform that cannot and a " \
                  "platform nobody wired read the same"
      expect(reason).to be_a(String), complaint
      expect(reason.strip).not_to be_empty, complaint
    end
  end

  if floor.moderation.empty?
    it "does not implement #moderate while it lists no moderation action" do
      expect(overrides?(:moderate)).to be(false)
    end
  else
    it "has a real #moderate behind the actions it lists" do
      expect(overrides?(:moderate)).to be(true)
    end

    it "lists no moderation action outside the vocabulary the features speak" do
      expect(floor.moderation - Rubotty::Core::Moderation::ACTIONS).to be_empty
    end
  end

  describe "the optional parts of the contract" do
    it "answers yes to exactly what its profile declares" do
      answered = AdapterContract::OPTIONAL_PARTS.keys.select do |part|
        adapter.public_send(AdapterContract::OPTIONAL_PARTS.fetch(part).first)
      end
      expect(answered).to match_array(profile.supports)
    end

    it "has a real implementation behind every yes" do
      profile.supports.each do |part|
        method_name = AdapterContract::OPTIONAL_PARTS.fetch(part).last
        complaint = "#{adapter_name} answers yes to #{part} with Base's no-op still behind it"
        expect(overrides?(method_name)).to be(true), complaint
      end
    end

    it "implements nothing it answers no to, so no code sits there unreachable" do
      unreachable = AdapterContract::OPTIONAL_PARTS
                    .reject { |part, _| profile.supports.include?(part) }
                    .select { |_, (_, method_name)| overrides?(method_name) }
      complaint = "#{adapter_name} implements #{unreachable.keys.join(", ")} and answers no, so the code is " \
                  "dead and `rubotty check` reports a gap that is not there"
      expect(unreachable.keys).to be_empty, complaint
    end

    # A no cannot say whether the platform cannot carry it or nobody has written
    # it here. Where the answer is the second, the profile says which, since a
    # bare false reads as the first to every caller.
    it "gives a reason for anything it declines that the platform itself could carry" do
      expect(profile.not_written_here.keys - AdapterContract::OPTIONAL_PARTS.keys).to be_empty
      expect(profile.not_written_here.keys & profile.supports).to be_empty
      expect(profile.not_written_here.values).to all(be_a(String))
    end

    # The platform-cannot half of the same question: a part this platform has
    # no way to carry at all, as opposed to one nobody has written yet.
    it "gives a reason for anything the platform itself cannot carry" do
      expect(profile.platform_cannot.keys - AdapterContract::OPTIONAL_PARTS.keys).to be_empty
      expect(profile.platform_cannot.keys & profile.supports).to be_empty
      expect(profile.platform_cannot.keys & profile.not_written_here.keys).to be_empty
      expect(profile.platform_cannot.values).to all(be_a(String))
    end

    # Every optional part answers yes, not written here, or platform cannot.
    # Nothing may sit outside all three, since that is a silent no with no
    # record of which of the two it actually is.
    it "answers every optional part in one of the three ways, so none goes unaccounted for" do
      accounted = profile.supports + profile.not_written_here.keys + profile.platform_cannot.keys
      unaccounted = AdapterContract::OPTIONAL_PARTS.keys - accounted
      complaint = "#{adapter_name} answers nothing at all for #{unaccounted.join(", ")}"
      expect(unaccounted).to be_empty, complaint
    end

    # The one optional part whose ANSWER a caller reads rather than discards:
    # Core::EphemeralMessage keeps the receipt so it can take the DM back later,
    # and refuses to send a DM it could not make ephemeral. A bare true here
    # means the operator gets a permanent DM instead of a temporary one.
    if profile.supports.include?(:admin_dm)
      it "hands back a DmReceipt from #send_admin_dm, so the DM can be taken back" do
        receipt = adapter.send_admin_dm(harness.dm_target, "the contract is checking on you")
        expect(receipt).to be_a(Rubotty::Core::DmReceipt)
        expect(receipt.native_id).not_to be_empty

        if profile.supports.include?(:admin_dm_delete)
          expect(adapter.delete_admin_dm(receipt)).to be_truthy
        end
      end
    end
  end

  # For every part of {AdapterContract::LIFECYCLE_PARTS} this adapter is in
  # exactly one of four states, native, compacted, unwritten or impossible, and
  # says which. A part with no entry at all is the state nobody chose: the code
  # silently does nothing and nothing here would have noticed.
  describe "the message-kind lifecycle" do
    it "answers every part, so a new one cannot go undeclared" do
      missing = AdapterContract::LIFECYCLE_PARTS - profile.lifecycle.keys
      complaint = "#{adapter_name} never answers #{missing.join(", ")}: native, compacted, unwritten, impossible"
      expect(missing).to be_empty, complaint
    end

    it "declares only real lifecycle parts" do
      expect(profile.lifecycle.keys - AdapterContract::LIFECYCLE_PARTS).to be_empty
    end

    it "answers with a real state, and a reason for anything short of native" do
      profile.lifecycle.each do |part, (state, reason)|
        expect(AdapterContract::LIFECYCLE_STATES).to include(state),
                                                      "#{adapter_name} answers #{part} with #{state.inspect}"
        next if state == :native

        complaint = "#{adapter_name} answers #{part} with #{state} and no reason on record"
        expect(reason).to be_a(String), complaint
        expect(reason.strip).not_to be_empty, complaint
      end
    end

    # Everything above checks that a state and reason are on record, never that the state
    # is true: this and the next example prove it, running harness.membership_event and
    # harness.bulk_delete_event against the same fake gateway every other example uses.
    # Nil for an adapter nobody has wired one for yet, so the declared state stays unchecked.
    it "actually produces a join or leave when membership_produce is exercised" do
      event = harness.membership_event
      next if event.nil?

      state, = profile.lifecycle[:membership_produce]
      expect(state).to eq(:native),
                       "#{adapter_name} exercises a native membership event but its profile still says #{state}"

      messages = event.call
      expect(messages).not_to be_empty, "#{adapter_name}'s own membership event produced nothing"
      kinds = messages.map(&:kind).uniq
      expect(kinds - %i[join leave]).to be_empty,
                                        "#{adapter_name}'s membership event produced #{kinds.inspect}, not " \
                                        "join or leave"
    end

    it "actually expands into one delete per id when bulk_delete is exercised" do
      event = harness.bulk_delete_event
      next if event.nil?

      state, = profile.lifecycle[:bulk_delete]
      expect(state).to eq(:compacted),
                       "#{adapter_name} exercises an expanding bulk delete but its profile still says #{state}"

      messages = event.call
      expect(messages.size).to be > 1,
                               "#{adapter_name}'s own bulk-delete event produced #{messages.size} message(s), " \
                               "not one per id"
      expect(messages).to all(have_attributes(kind: :delete))
    end
  end

  describe "seeding and discovery addressing the same channel" do
    unless profile.exempt?(:route_key_for)
      it "maps a seeded endpoint onto the route_key discovery would have given it" do
        expect(class_overrides?(:route_key_for)).to be(true)
      end

      # Every spelling of one channel has to seed the same route_key, since the
      # snapshot resolves an inbound event by exact match and normalises nothing.
      it "answers one route_key for every spelling of the same channel" do
        profile.route_key_aliases.each do |spellings|
          keys = spellings.map do |settings|
            adapter_class.route_key_for(
              Rubotty::Core::Endpoint.new(id: "alias", adapter_name: adapter_name,
                                          account: "a", settings: settings)
            )
          end
          expect(keys.uniq.size).to eq(1),
                                    "#{adapter_name} seeds #{keys.inspect} for one channel, so all but one " \
                                    "spelling resolves nothing inbound"
        end
      end
    end

    it "overrides .addressing exactly when it feeds channel discovery" do
      expect(class_overrides?(:addressing)).to be(adapter_class.discovers_channels?)
    end

    if klass.discovers_channels?
      it "round trips a discovered route_key through .addressing and back" do
        sample = profile.sample
        settings = adapter_class.addressing(sample[:route_key], external_id: sample[:external_id])
        coerced = adapter_class.endpoint_schema.call(settings, path: "channel")

        expect(coerced.problems).to be_empty
        expect(adapter_class.validate_endpoint(coerced.value, "channel")).to be_empty

        discovered = Rubotty::Core::Endpoint.new(
          id: "round-trip", adapter_name: adapter_name, account: "a", settings: coerced.value
        )
        complaint = "a channel discovery found and a channel seeded from YAML would land on two rows"
        expect(adapter_class.route_key_for(discovered)).to eq(sample[:route_key]), complaint
      end
    end
  end

  describe "outbound" do
    it "answers NOT_APPLICABLE, never a bare nil, for a send with nothing to deliver" do
      harness.declines.each do |label, (endpoint, message)|
        receipt = adapter.deliver(message, endpoint)
        expect(receipt).to equal(Rubotty::Core::DeliveryReceipt::NOT_APPLICABLE),
                           "#{adapter_name} answered #{receipt.inspect} for #{label}. Bridge logs a bare nil " \
                           "as RELAY LOST and counts it against the operator's reconcile."
      end
    end

    unless profile.exempt?(:sends)
      it "hands back a receipt naming the endpoint for a send that happened" do
        expect(harness.sends).not_to be_empty
        harness.sends.each do |label, (endpoint, message)|
          receipt = adapter.deliver(message, endpoint)
          expect(receipt).to be_a(Rubotty::Core::DeliveryReceipt), "no receipt for #{label}"
          expect(receipt).not_to equal(Rubotty::Core::DeliveryReceipt::NOT_APPLICABLE)
          expect(receipt.endpoint_id).to eq(endpoint.id)
          expect(receipt.native_id).not_to be_empty
        end
      end
    end

    if floor.edits?
      it "answers an edit with a receipt or a bare nil, and nothing else" do
        answer = adapter.edit(
          AdapterContract.ordinary_message(self, first_endpoint), first_endpoint, harness.native_id
        )
        expect(answer).to be_a(Rubotty::Core::DeliveryReceipt).or be_nil
      end
    end
  end

  if floor.reactions? || profile.negotiable.key?(:reactions?)
    describe "reactions" do
      # The bridge records the mirror as placed for any return that did not
      # raise, and storage has already written the emoji as held, so a swallowed
      # refusal leaves the aggregate believing in an emoji nobody can see.
      it "lets a refusal out rather than reporting a mirror that is not there" do
        [Rubotty::PermissionError.new("403 Missing Permissions", adapter: adapter_name),
         Rubotty::RateLimitedError.new("429 Too Many Requests", adapter: adapter_name)].each do |error|
          harness.refuse_reaction.call(error)
          expect do
            adapter.sync_reactions(first_endpoint, harness.native_id,
                                   desired: [AdapterContract.thumbs], previous: [])
          end.to raise_error(Rubotty::AdapterError),
                 "#{adapter_name} swallowed a #{error.class} and reported success upward"
        end
      end
    end
  end

  unless floor.moderation.empty?
    describe "moderation" do
      it "answers a Result for every action it lists, and raises for none of them" do
        floor.moderation.each do |action|
          command = AdapterContract.command(action, first_endpoint,
                                            target_user_id: harness.moderation_target)
          answer = nil
          expect { answer = adapter.moderate(command, first_endpoint, harness.native_id) }
            .not_to raise_error, "#{adapter_name} raised for /#{action}, which it lists as supported"
          expect(answer).to be_a(Rubotty::Core::Moderation::Result)
          expect(answer.status).not_to eq(:unsupported),
                 "#{adapter_name} lists /#{action} and then calls it unsupported"
        end
      end

      it "answers unsupported for an action it does not list" do
        answer = adapter.moderate(
          AdapterContract.command(:defenestrate, first_endpoint), first_endpoint, harness.native_id
        )
        expect(answer.status).to eq(:unsupported)
      end

      # #moderate rescues AdapterError (and PermissionError) alone, not StandardError more
      # widely, since Features::Moderation#execute_command turns any raise from here into
      # a failed Result. Adapters' own delete/pin helpers may wrap a platform failure into
      # AdapterError before it reaches #moderate too, but it must never report a false success.
      it "never reports a false success for an unanticipated platform failure" do
        harness.break_moderation.call
        command = AdapterContract.command(harness.moderation_action, first_endpoint,
                                          target_user_id: harness.moderation_target)
        begin
          answer = adapter.moderate(command, first_endpoint, harness.native_id)
          expect(answer.status).to eq(:failed),
                 "#{adapter_name} reported #{answer.status.inspect} for an ordinary bug, not :failed"
        rescue StandardError
          # Letting it out is the other correct outcome.
        end
      end
    end
  end

  describe "lifecycle" do
    it "stops safely twice in a row" do
      expect { adapter.stop }.not_to raise_error
      expect { adapter.stop }.not_to raise_error
    end

    unless profile.exempt?(:constructor)
      it "takes every keyword Runtime passes, and stops safely having never started" do
        built = klass.new(
          account: "contract-test", settings: profile.settings,
          dispatcher: AdapterContract.dispatcher, logger: AdapterContract.logger,
          endpoints: [], endpoint_resolver: nil, control_lane: nil, join_guard: nil, discovery: nil
        )
        expect { built.stop }.not_to raise_error
        expect { built.stop }.not_to raise_error
      end
    end
  end

  if klass.private_method_defined?(:gone?)
    describe "already gone" do
      it "reads the one shared definition rather than a copy of its own" do
        AdapterContract::GONE_CASES.each do |message, expected|
          error = Rubotty::AdapterError.new(message, adapter: adapter_name)
          complaint = "#{adapter_name} disagrees with the shared definition about #{message.inspect}"
          expect(adapter.send(:gone?, error)).to be(expected), complaint
        end
      end
    end
  end
end
