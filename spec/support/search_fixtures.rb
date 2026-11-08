# frozen_string_literal: true

# One community populated with a row of every kind {ControlPlane::Search} reads,
# each carrying the same marker word, so a spec can ask for another tenant's
# exact value and prove it comes back empty.
module SearchFixtures
  # Every kind, with the exact stored value a search for it would match, built
  # from the marker the community was populated with. Keyed by kind so an
  # isolation spec can loop over the whole surface rather than a chosen few.
  def search_terms(marker)
    {
      community: "#{marker} Assembly",
      room: "#{marker} Lounge",
      platform_connection: "#{marker} Telegram",
      endpoint: "#{marker}_weather",
      operator: "#{marker} Operator",
      feature: "#{marker}_filter",
      script: "#{marker}_greeter",
      webhook: "#{marker} hook",
      redirection: "#{marker}-destination",
      alert: "#{marker} needs attention",
      event: "#{marker} Movie Night",
      poll: "which #{marker} night?"
    }
  end

  # A community whose every searchable row contains +marker+, plus the shared
  # room_key every community in this deployment uses, which is what makes a
  # cross-tenant collision ordinary rather than exotic here.
  def search_community(models, slug:, marker:, now: Time.now)
    community = models.community.create(
      slug: slug, name: "#{marker} Assembly", status: "active", settings: "{}",
      created_at: now, updated_at: now
    )
    room = models.room.create(community_id: community.id, room_key: "general",
                              label: "#{marker} Lounge", display_name: "{}",
                              created_at: now, updated_at: now)
    models.platform_connection.create(
      community_id: community.id, adapter: "telegram", account: "tg",
      external_id: "-100#{community.id}", label: "#{marker} Telegram",
      created_at: now, updated_at: now
    )
    models.script_endpoint.create(
      community_id: community.id, name: "#{marker}_weather", description: "the #{marker} forecast",
      http_method: "GET", url: "https://example.test", created_at: now, updated_at: now
    )
    person = models.person.create(community_id: community.id, name: "#{marker} Operator",
                                  created_at: now, updated_at: now)
    models.operator.create(community_id: community.id, person_id: person.id, actions: '"all"',
                           scope: '"all"', granted_at: now, granted_by: "seed")
    models.feature_setting.create(community_id: community.id, feature: "#{marker}_filter",
                                  enabled: true, config: "{}", created_at: now, updated_at: now)
    models.community_script.create(community_id: community.id, name: "#{marker}_greeter",
                                   kind: "command", language: "lua", source: "-- nothing",
                                   trigger_type: "command", created_at: now, updated_at: now)
    models.webhook_subscription.create(
      community_id: community.id, public_id: "public-#{community.id}",
      url: "https://hooks.test/#{marker}", label: "#{marker} hook", event_types: "[]",
      secret: "secret", created_at: now, updated_at: now
    )
    models.redirection.create(community_id: community.id, source_endpoint_id: "#{marker}-source",
                              target_room_id: "#{marker}-destination", operator: "op",
                              status: "done", created_at: now, updated_at: now)
    models.alert.create(community_id: community.id, text: "#{marker} needs attention", mode: "quiet",
                        script: "#{marker}_watch", created_at: now)
    models.event.create(community_id: community.id, room_id: room.id, title: "#{marker} Movie Night",
                        kind: "generic", starts_at: now, created_at: now, updated_at: now)
    models.poll.create(community_id: community.id, room_id: room.id, kind: "poll",
                       question: "which #{marker} night?", closes_at: now + 3600,
                       created_at: now, updated_at: now)
    community
  end
end

RSpec.configure do |config|
  config.include SearchFixtures, :control_plane
end
