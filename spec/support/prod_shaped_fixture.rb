# frozen_string_literal: true

require "sequel"

Sequel.extension :migration

# A synthetic control plane shaped like a long-running deployment, so the
# migration chain runs against rows rather than an empty database. Every value
# below is invented, so the fixture cannot leak what it never held. Each layer is
# written against a migration version that has already shipped and is then
# migrated forward, which keeps the inserts valid however far the chain grows.
module ProdShapedFixture
  MIGRATIONS = File.expand_path("../../db/migrations", __dir__)

  # Migration version => the writer that fills the tables that version has.
  LAYERS = { 11 => :seed_topology, 31 => :seed_scripts }.freeze

  # The lowest version this fixture can be rolled back to and still be a fixture.
  FLOOR = LAYERS.keys.min

  # A fixed instant, with every timestamp a whole number of minutes apart:
  # migration 012 collapses rows by newest updated_at, and MariaDB's DATETIME has
  # no fractional seconds to break a tie with.
  EPOCH = Time.utc(2025, 3, 14, 9, 0, 0)

  COMMUNITIES = [
    { slug: "harbourside", name: "Harbourside Makers", status: "active" },
    { slug: "lantern-club", name: "The Lantern Club", status: "active" },
    { slug: "meridian", name: "Meridian Study Group", status: "suspended" }
  ].freeze

  # Keyed by account, which is unique across the fixture.
  CONNECTIONS = [
    { community: "harbourside", account: "hs-tg", adapter: "telegram",
      external_id: "-1001987654", label: "Harbourside supergroup" },
    { community: "harbourside", account: "hs-dc", adapter: "discord",
      external_id: "884210000000000001", label: "Harbourside guild" },
    { community: "harbourside", account: "hs-irc", adapter: "irc",
      external_id: "irc.example.invalid", label: "Harbourside on IRC" },
    { community: "lantern-club", account: "lc-tg", adapter: "telegram",
      external_id: "-1002233445", label: "Lantern Club supergroup" },
    { community: "lantern-club", account: "lc-dc", adapter: "discord",
      external_id: "884210000000000002", label: "Lantern Club guild" },
    { community: "meridian", account: "md-xmpp", adapter: "xmpp",
      external_id: "meridian.example.invalid", label: "Meridian MUC host" },
    { community: "meridian", account: "md-dc", adapter: "discord",
      external_id: "884210000000000003", label: "Meridian guild" }
  ].freeze

  # endpoint_key is the fixture's handle for a channel everywhere below.
  CHANNELS = [
    { account: "hs-tg", route_key: "-1001987654/12", label: "general" },
    { account: "hs-dc", route_key: "884210000000000101", label: "general" },
    { account: "hs-irc", route_key: "#harbourside", label: "general" },
    { account: "hs-tg", route_key: "-1001987654/48", label: "workshop" },
    { account: "hs-dc", route_key: "884210000000000102", label: "workshop" },
    { account: "hs-dc", route_key: "884210000000000103", label: "announcements",
      receives: false },
    { account: "lc-tg", route_key: "-1002233445/3", label: "lounge" },
    { account: "lc-dc", route_key: "884210000000000201", label: "lounge" },
    { account: "lc-dc", route_key: "884210000000000202", label: "events" },
    { account: "md-xmpp", route_key: "hall@conference.meridian.example.invalid",
      label: "hall" },
    { account: "md-dc", route_key: "884210000000000301", label: "hall" }
  ].freeze

  # A room and the channels bridged into it. A channel belongs to exactly one
  # room: migration 012's `down` repoints a room-scoped row at one channel of
  # that room, so a shared channel would make the result depend on insertion order.
  ROOMS = [
    { community: "harbourside", room_key: "general", label: "General",
      channels: ["ch:telegram:hs-tg:-1001987654/12", "ch:discord:hs-dc:884210000000000101",
                 "ch:irc:hs-irc:#harbourside"] },
    { community: "harbourside", room_key: "workshop", label: "Workshop",
      channels: ["ch:telegram:hs-tg:-1001987654/48", "ch:discord:hs-dc:884210000000000102"] },
    { community: "harbourside", room_key: "announcements", label: "Announcements",
      channels: ["ch:discord:hs-dc:884210000000000103"] },
    { community: "lantern-club", room_key: "lounge", label: "Lounge",
      channels: ["ch:telegram:lc-tg:-1002233445/3", "ch:discord:lc-dc:884210000000000201"] },
    { community: "lantern-club", room_key: "events", label: "Events",
      channels: ["ch:discord:lc-dc:884210000000000202"] },
    { community: "meridian", room_key: "hall", label: "Hall",
      channels: ["ch:xmpp:md-xmpp:hall@conference.meridian.example.invalid",
                 "ch:discord:md-dc:884210000000000301"] }
  ].freeze

  PEOPLE = [
    { community: "harbourside", name: "wren", actions: "\"all\"", scope: "\"all\"",
      identities: [{ adapter: "telegram", native_id: "70110001", username: "wren" },
                   { adapter: "discord", native_id: "990110001", username: "wren" }] },
    { community: "harbourside", name: "orla", actions: "[\"warn\",\"kick\"]",
      scope: "[\"general\"]",
      identities: [{ adapter: "telegram", native_id: "70110002", username: "orla_h" }] },
    { community: "lantern-club", name: "tamsin", actions: "\"all\"", scope: "\"all\"",
      identities: [{ adapter: "discord", native_id: "990220001", username: "tamsin" }] },
    { community: "meridian", name: "birch", actions: "\"all\"", scope: "\"all\"",
      identities: [{ adapter: "xmpp", native_id: "birch@meridian.example.invalid",
                     username: "birch" }] }
  ].freeze

  # A row with no channel is the community-wide default, a row with one overrides
  # it for that endpoint. The three word_filter rows share the harbourside
  # "general" room so migration 012 must collapse them, and `minute` sets the
  # updated_at that decides the discord row survives.
  FEATURE_SETTINGS = [
    { community: "harbourside", channel: nil, feature: "bridge", enabled: true,
      config: "{}", minute: 0 },
    { community: "harbourside", channel: nil, feature: "moderation", enabled: true,
      config: "{\"warn_limit\":3}", minute: 5 },
    { community: "harbourside", channel: "ch:telegram:hs-tg:-1001987654/12",
      feature: "word_filter", enabled: true, config: "{\"list\":[\"telegram\"]}", minute: 10 },
    { community: "harbourside", channel: "ch:irc:hs-irc:#harbourside",
      feature: "word_filter", enabled: false, config: "{\"list\":[\"irc\"]}", minute: 20 },
    { community: "harbourside", channel: "ch:discord:hs-dc:884210000000000101",
      feature: "word_filter", enabled: true, config: "{\"list\":[\"discord\"]}", minute: 30 },
    { community: "harbourside", channel: "ch:discord:hs-dc:884210000000000102",
      feature: "guest_portal", enabled: true,
      config: "{\"who_can_invite\":\"operators\"}", minute: 40 },
    { community: "lantern-club", channel: nil, feature: "bridge", enabled: true,
      config: "{}", minute: 45 },
    { community: "lantern-club", channel: "ch:telegram:lc-tg:-1002233445/3",
      feature: "link_annotation", enabled: true, config: "{\"max\":2}", minute: 50 },
    { community: "lantern-club", channel: "ch:discord:lc-dc:884210000000000201",
      feature: "guest_portal", enabled: true, config: "{}", minute: 55 },
    { community: "meridian", channel: nil, feature: "bridge", enabled: true,
      config: "{}", minute: 60 },
    { community: "meridian", channel: nil, feature: "moderation", enabled: false,
      config: "{}", minute: 65 },
    { community: "meridian", channel: "ch:xmpp:md-xmpp:hall@conference.meridian.example.invalid",
      feature: "faq", enabled: true, config: "{\"threshold\":0.7}", minute: 70 }
  ].freeze

  # Three guest sessions in three states: live, revoked and expired.
  GUEST_INVITES = [
    { community: "harbourside", channel: "ch:discord:hs-dc:884210000000000101",
      nickname: "Ada", token_hash: "a1" * 32, created_by: "wren", expires_minutes: 240,
      revoked: false, joined: true },
    { community: "harbourside", channel: "ch:telegram:hs-tg:-1001987654/48",
      nickname: "Bram", token_hash: "b2" * 32, created_by: "orla", expires_minutes: 180,
      revoked: true, joined: true },
    { community: "lantern-club", channel: "ch:discord:lc-dc:884210000000000201",
      nickname: "Cleo", token_hash: "c3" * 32, created_by: "tamsin", expires_minutes: -60,
      revoked: false, joined: false }
  ].freeze

  # What a guest session leaves in the feed: the pending send, the room's reply,
  # and a reaction pointing back at that reply.
  FEED_ROWS_PER_INVITE = 3

  # Layer two: the script tables, which only exist from migration 031.
  SCRIPTS = [
    { community: "harbourside", name: "welcome", kind: "command", language: "lua",
      trigger_type: "command", trigger_config: "{\"name\":\"welcome\"}", enabled: true,
      created_by: "wren", source: "return function(ctx) return ctx.reply(\"welcome\") end" },
    { community: "harbourside", name: "quiet-hours", kind: "processor", language: "moonscript",
      trigger_type: "always", trigger_config: "{}", enabled: false, created_by: "orla",
      source: "(ctx) -> ctx.allow!" },
    { community: "lantern-club", name: "roll", kind: "command", language: "lua",
      trigger_type: "command", trigger_config: "{\"name\":\"roll\"}", enabled: true,
      created_by: "tamsin", source: "return function(ctx) return ctx.reply(\"4\") end" }
  ].freeze

  ENDPOINTS = [
    { community: "harbourside", name: "tide", description: "Tide times",
      http_method: "GET", url: "https://tides.example.invalid/{port}",
      headers: "{\"Accept\":\"application/json\"}", allow_sync: true },
    { community: "lantern-club", name: "notify", description: "Push a notice",
      http_method: "POST", url: "https://hooks.example.invalid/notify",
      headers: "{}", allow_sync: false }
  ].freeze

  # Migrations 032 and 034 are loops over these rows, so they need rows here to
  # do anything at all.
  MEMOS = [
    { community: "harbourside", script: "welcome", key: "greeted:wren",
      value: "1", expires_minutes: 1440 },
    { community: "harbourside", script: "welcome", key: "greeted:orla",
      value: "1", expires_minutes: 1440 },
    { community: "harbourside", script: "quiet-hours", key: "warned:orla",
      value: "2", expires_minutes: 60 },
    { community: "lantern-club", script: "roll", key: "last:tamsin",
      value: "6", expires_minutes: 720 }
  ].freeze

  # Migrate to each layer's version, fill it, and finish at the head of the chain.
  def self.install(db, dir: MIGRATIONS)
    LAYERS.each do |version, writer|
      Sequel::Migrator.run(db, dir, target: version)
      send(writer, db)
    end
    Sequel::Migrator.run(db, dir)
    db
  end

  # Layer one, written against the schema migration 011 leaves behind.
  def self.seed_topology(db)
    communities = insert_communities(db)
    channels = insert_channels(db, communities)
    insert_rooms(db, communities, channels)
    insert_people(db, communities)
    insert_feature_settings(db, communities, channels)
    insert_guests(db, communities, channels)
    insert_operational_rows(db, communities)
    db
  end

  # Layer two, written against the schema migration 031 leaves behind.
  def self.seed_scripts(db)
    communities = db[:communities].select_hash(:slug, :id)

    scripts = SCRIPTS.to_h do |script|
      id = db[:community_scripts].insert(
        community_id: communities.fetch(script[:community]), name: script[:name],
        kind: script[:kind], language: script[:language], source: script[:source],
        compiled: script[:source], trigger_type: script[:trigger_type],
        trigger_config: script[:trigger_config], enabled: script[:enabled],
        consecutive_failures: 0, created_by: script[:created_by],
        created_at: minute(0), updated_at: minute(5)
      )
      [script[:name], id]
    end

    ENDPOINTS.each do |endpoint|
      db[:script_endpoints].insert(
        community_id: communities.fetch(endpoint[:community]), name: endpoint[:name],
        description: endpoint[:description], http_method: endpoint[:http_method],
        url: endpoint[:url], headers: endpoint[:headers], allow_sync: endpoint[:allow_sync],
        timeout_seconds: 2, cache_seconds: 30, enabled: true, created_by: "wren",
        created_at: minute(0), updated_at: minute(5)
      )
    end

    MEMOS.each do |memo|
      db[:script_memos].insert(
        community_id: communities.fetch(memo[:community]),
        community_script_id: scripts.fetch(memo[:script]),
        key: memo[:key], value: memo[:value], expires_at: minute(memo[:expires_minutes]),
        created_at: minute(0), updated_at: minute(1)
      )
    end
    db
  end

  # What the fixture holds, resolved through slugs and keys because the round trip
  # does not preserve row ids. Readable only at the head of the chain, where the
  # room-scoped columns exist.
  def self.census(db)
    {
      communities: db[:communities].order(:slug).select_map(%i[slug name status]),
      # settings is the column migration 015 adds to a table that already has rows.
      connections: db[:platform_connections].order(:account)
                                            .select_map(%i[account adapter external_id settings]),
      channels: db[:channels].order(:endpoint_key)
                             .select_map(%i[endpoint_key adapter route_key receives sends]),
      rooms: room_endpoints(db),
      feature_settings: feature_settings_census(db),
      guest_invites: guest_invite_census(db),
      guest_messages: guest_message_census(db),
      people: db[:people].order(:name).select_map(:name),
      operators: operator_census(db)
    }
  end

  # Read back separately from the census because a rollback below migration 031
  # takes these tables away and they come back empty.
  def self.script_census(db)
    {
      scripts: db[:community_scripts].order(:name).select_map(%i[name kind language enabled]),
      endpoints: db[:script_endpoints].order(:name).select_map(%i[name http_method url]),
      # room_key and scope are what 032 and 034 write onto every existing row.
      memos: db[:script_memos].order(:key).select_map(%i[key value room_key scope])
    }
  end

  # Row counts for the first layer's tables, which unlike the census can be taken
  # at FLOOR as well as at the head of the chain.
  def self.row_counts(db)
    %i[communities platform_connections channels rooms room_channels people
       person_identities operators feature_settings guest_invites guest_messages
       guest_uploads observed_identities warnings audit_events].to_h do |table|
      [table, db[table].count]
    end
  end

  def self.room_endpoints(db)
    db[:rooms].join(:communities, id: :community_id)
              .left_join(:room_channels, room_id: Sequel[:rooms][:id])
              .left_join(:channels, id: Sequel[:room_channels][:channel_id])
              .select_map([Sequel[:communities][:slug], Sequel[:rooms][:room_key],
                           Sequel[:channels][:endpoint_key]])
              .group_by { |slug, room_key, _| [slug, room_key] }
              .map { |scope, rows| scope + [rows.map(&:last).compact.sort] }
              .sort_by { |row| [row[0], row[1]] }
  end

  def self.feature_settings_census(db)
    db[:feature_settings].join(:communities, id: Sequel[:feature_settings][:community_id])
                         .left_join(:rooms, id: Sequel[:feature_settings][:room_id])
                         .select_map([Sequel[:communities][:slug], Sequel[:rooms][:room_key],
                                      Sequel[:feature_settings][:feature],
                                      Sequel[:feature_settings][:enabled],
                                      Sequel[:feature_settings][:config]])
                         .sort_by { |row| row[0, 3].map(&:to_s) }
  end

  def self.guest_invite_census(db)
    db[:guest_invites].join(:communities, id: Sequel[:guest_invites][:community_id])
                      .left_join(:rooms, id: Sequel[:guest_invites][:room_id])
                      .left_join(:channels, id: Sequel[:guest_invites][:channel_id])
                      .select_map([Sequel[:communities][:slug], Sequel[:rooms][:room_key],
                                   Sequel[:channels][:endpoint_key],
                                   Sequel[:guest_invites][:nickname],
                                   Sequel[:guest_invites][:token_hash]])
                      .sort_by { |row| row.map(&:to_s) }
  end

  def self.guest_message_census(db)
    db[:guest_messages].left_join(:rooms, id: Sequel[:guest_messages][:room_id])
                       .select_map([Sequel[:rooms][:room_key], Sequel[:guest_messages][:direction],
                                    Sequel[:guest_messages][:kind], Sequel[:guest_messages][:body],
                                    Sequel[:guest_messages][:attachments]])
                       .sort_by { |row| row.map(&:to_s) }
  end

  def self.operator_census(db)
    db[:operators].join(:people, id: Sequel[:operators][:person_id])
                  .join(:communities, id: Sequel[:operators][:community_id])
                  .select_map([Sequel[:communities][:slug], Sequel[:people][:name],
                               Sequel[:operators][:actions], Sequel[:operators][:scope]])
                  .sort_by { |row| row.map(&:to_s) }
  end

  def self.minute(offset) = EPOCH + (offset * 60)

  def self.insert_communities(db)
    COMMUNITIES.to_h do |community|
      id = db[:communities].insert(
        slug: community[:slug], name: community[:name], status: community[:status],
        settings: "{\"locale\":\"en\"}", bootstrap_source: "fixture",
        created_at: minute(0), updated_at: minute(1)
      )
      [community[:slug], id]
    end
  end

  # Connections and channels together, because a channel names its connection.
  def self.insert_channels(db, communities)
    connections = CONNECTIONS.to_h do |connection|
      id = db[:platform_connections].insert(
        community_id: communities.fetch(connection[:community]), adapter: connection[:adapter],
        account: connection[:account], external_id: connection[:external_id],
        label: connection[:label], created_at: minute(0), updated_at: minute(1)
      )
      [connection[:account], { id: id, community: connection[:community],
                               adapter: connection[:adapter] }]
    end

    CHANNELS.to_h do |channel|
      connection = connections.fetch(channel[:account])
      key = endpoint_key(connection[:adapter], channel[:account], channel[:route_key])
      id = db[:channels].insert(
        community_id: communities.fetch(connection[:community]),
        platform_connection_id: connection[:id], adapter: connection[:adapter],
        account: channel[:account], route_key: channel[:route_key], endpoint_key: key,
        label: channel[:label], receives: channel.fetch(:receives, true), sends: true,
        relay: "{}", display_name: "{}", settings: "{}",
        created_at: minute(0), updated_at: minute(2)
      )
      [key, id]
    end
  end

  def self.endpoint_key(adapter, account, route_key) = "ch:#{adapter}:#{account}:#{route_key}"

  def self.insert_rooms(db, communities, channels)
    ROOMS.to_h do |room|
      id = db[:rooms].insert(
        community_id: communities.fetch(room[:community]), room_key: room[:room_key],
        label: room[:label], display_name: "{}", created_at: minute(0), updated_at: minute(3)
      )
      room[:channels].each do |key|
        db[:room_channels].insert(room_id: id, channel_id: channels.fetch(key),
                                  created_at: minute(3))
      end
      [[room[:community], room[:room_key]], id]
    end
  end

  def self.insert_people(db, communities)
    PEOPLE.each do |person|
      community_id = communities.fetch(person[:community])
      person_id = db[:people].insert(community_id: community_id, name: person[:name],
                                     created_at: minute(0), updated_at: minute(4))
      person[:identities].each do |identity|
        db[:person_identities].insert(person_id: person_id, adapter: identity[:adapter],
                                      native_id: identity[:native_id],
                                      username: identity[:username], created_at: minute(0))
      end
      db[:operators].insert(community_id: community_id, person_id: person_id,
                            actions: person[:actions], scope: person[:scope],
                            granted_at: minute(4), granted_by: "fixture")
    end
  end

  def self.insert_feature_settings(db, communities, channels)
    FEATURE_SETTINGS.each do |setting|
      db[:feature_settings].insert(
        community_id: communities.fetch(setting[:community]),
        channel_id: setting[:channel] && channels.fetch(setting[:channel]),
        feature: setting[:feature], enabled: setting[:enabled], config: setting[:config],
        created_at: minute(0), updated_at: minute(setting[:minute])
      )
    end
  end

  def self.insert_guests(db, communities, channels)
    GUEST_INVITES.each do |invite|
      community_id = communities.fetch(invite[:community])
      channel_id = channels.fetch(invite[:channel])
      invite_id = db[:guest_invites].insert(
        community_id: community_id, channel_id: channel_id, nickname: invite[:nickname],
        token_hash: invite[:token_hash], created_by: invite[:created_by],
        expires_at: minute(invite[:expires_minutes]),
        revoked_at: invite[:revoked] ? minute(90) : nil,
        joined_at: invite[:joined] ? minute(15) : nil,
        join_cursor: invite[:joined] ? 0 : nil,
        created_at: minute(10), updated_at: minute(15)
      )
      insert_guest_feed(db, community_id: community_id, channel_id: channel_id,
                        invite_id: invite_id, invite: invite)
    end
  end

  # A short conversation per invite, plus one upload each, which migration 045
  # deletes on the way up.
  def self.insert_guest_feed(db, community_id:, channel_id:, invite_id:, invite:)
    out_id = db[:guest_messages].insert(
      community_id: community_id, channel_id: channel_id, invite_id: invite_id,
      direction: "out", author_label: "#{invite[:nickname]}@guest-user",
      body: "hello from #{invite[:nickname]}", attachments: "[]", kind: "chat",
      relayed_at: nil, created_at: minute(16)
    )
    in_id = db[:guest_messages].insert(
      community_id: community_id, channel_id: channel_id, invite_id: nil,
      direction: "in", author_label: "wren (telegram)", body: "hello back", attachments: "[]",
      kind: "chat", relayed_at: minute(17), created_at: minute(17)
    )
    db[:guest_messages].insert(
      community_id: community_id, channel_id: channel_id, invite_id: nil,
      direction: "in", author_label: "orla (telegram)", body: "wave", attachments: "[]",
      kind: "reaction", ref_id: in_id, relayed_at: minute(18), created_at: minute(18)
    )
    db[:guest_uploads].insert(
      community_id: community_id, channel_id: channel_id,
      token: "#{invite[:token_hash][0, 40]}upload", filename: "sketch.png",
      content_type: "image/png", data: ["fixture bytes for #{invite[:nickname]}"].pack("m0"),
      byte_size: 32, created_at: minute(19)
    )
    out_id
  end

  # The tables nothing later reshapes, filled so no migration in the chain runs
  # against a database that is empty everywhere it is not looking.
  def self.insert_operational_rows(db, communities)
    communities.each do |slug, community_id|
      db[:observed_identities].insert(
        community_id: community_id, adapter: "telegram", native_id: "8800#{community_id}",
        username: "passerby", display_name: "Passer By",
        first_seen_at: minute(0), last_seen_at: minute(60)
      )
      db[:warnings].insert(
        community: slug, adapter: "telegram", subject_native_id: "8800#{community_id}",
        subject_username: "passerby", subject_display: "Passer By", reason: "link spam",
        issued_by: "wren", active: true, issued_at: minute(20)
      )
      db[:audit_events].insert(
        community: slug, source: "dashboard", action: "feature.enable", adapter: "telegram",
        actor: "wren", actor_native_id: "70110001", outcome: "ok",
        metadata: "{\"feature\":\"bridge\"}", created_at: minute(21)
      )
      db[:scheduled_jobs].insert(
        community: slug, kind: "retention.sweep", payload: "{}", run_at: minute(120),
        status: "pending", attempts: 0, created_at: minute(22)
      )
    end

    db[:active_sanctions].insert(
      community: "harbourside", adapter: "telegram", subject_native_id: "88001",
      subject_username: "passerby", action: "mute", endpoints: "[]", until_at: minute(300),
      active: true, created_at: minute(23)
    )
    db[:ephemeral_messages].insert(
      group_id: "grp-fixture-1", endpoint_id: "ch:telegram:hs-tg:-1001987654/12",
      channel: "{}", native_id: "5501", delete_at: minute(30), session_id: "fixture",
      created_at: minute(24)
    )
  end

  private_class_method :insert_communities, :insert_channels, :insert_rooms, :insert_people,
                       :insert_feature_settings, :insert_guests, :insert_guest_feed,
                       :insert_operational_rows, :endpoint_key
end
