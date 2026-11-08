# frozen_string_literal: true

module Rubotty
  module Dashboard
    # The navigation catalogue, as data: which sections exist, how they
    # group, what they are called, where they point and what grant each one
    # costs, written down once and rendered several times ({App}'s pre-theme
    # bar, {ViewData#shell} over the internal surface, each theme in its own
    # shape). None of them decides what the sections ARE.
    #
    # The unit is a scope: one whole navigation tree with a name. A
    # community page carries two (itself, and the deployment around it).
    module Nav
      # One destination: +grant+ is the action {Role#can?} is asked about
      # before the entry is offered, +admin_only+ the stronger form for pages
      # gated by require_admin!, and +open+ the explicit "no gate at all", which
      # an ungated entry has to say. +badge+ names the count {ViewData} attaches.
      Item = Struct.new(:key, :label, :path, :grant, :admin_only, :open, :badge, keyword_init: true)

      # A run of items under one heading. A nil label is a group drawn bare
      # rather than under a heading, which is what Overview and Communities
      # are: one link that opens a scope rather than a section of it.
      Group = Struct.new(:key, :label, :items, keyword_init: true)

      # A community's own sections. Word filter, FAQ, Events, Guests, People
      # and Polls are absent on purpose: each is one feature's configuration
      # and is reached from Features, so the nav does not carry a second route
      # to the same page.
      COMMUNITY_GROUPS = [
        Group.new(key: "landing", label: nil, items: [
          Item.new(key: "overview", label: "Overview", path: "", grant: :view_community)
        ]),
        Group.new(key: "activity", label: "Activity", items: [
          Item.new(key: "analytics", label: "Analytics", path: "analytics", grant: :view_analytics),
          Item.new(key: "alerts", label: "Alerts", path: "alerts", grant: :view_community,
                   badge: "alerts"),
          Item.new(key: "files", label: "Files", path: "files", admin_only: true),
          Item.new(key: "audit", label: "Audit log", path: "audit", grant: :view_audit_log)
        ]),
        Group.new(key: "bridge", label: "Bridge", items: [
          Item.new(key: "rooms", label: "Rooms", path: "rooms", grant: :view_rooms, badge: "rooms"),
          Item.new(key: "platforms", label: "Platforms", path: "platforms", grant: :view_platforms)
        ]),
        Group.new(key: "automation", label: "Automation", items: [
          Item.new(key: "features", label: "Features", path: "features", grant: :view_community),
          Item.new(key: "participation", label: "Room games", path: "participation",
                   grant: :view_community),
          Item.new(key: "redirections", label: "Redirections", path: "redirections",
                   grant: :view_community),
          Item.new(key: "webhooks", label: "Webhooks", path: "webhooks", grant: :view_community,
                   badge: "webhook_failures")
        ]),
        Group.new(key: "scripting", label: "Scripting", items: [
          Item.new(key: "scripts", label: "Scripts (alpha)", path: "scripts", grant: :view_scripts),
          Item.new(key: "endpoints", label: "Script endpoints", path: "endpoints", grant: :view_endpoints)
        ]),
        Group.new(key: "people", label: "People and safety", items: [
          Item.new(key: "moderation", label: "Moderation", path: "moderation", grant: :view_community),
          Item.new(key: "misfires", label: "Policy misfires", path: "content-policy/misfires",
                   grant: :view_community),
          Item.new(key: "operators", label: "Operators", path: "operators", grant: :view_operators,
                   badge: "operator_requests")
        ])
      ].freeze

      # The deployment-wide sections. An +admin_only+ entry is hidden rather
      # than merely refused: Accounts, API keys and Operator logins list
      # credential names and live sign-in links (reconnaissance, not
      # oversight), and Onboarding's pending spaces belong to no community for
      # an operator to act in.
      DEPLOYMENT_GROUPS = [
        Group.new(key: "landing", label: nil, items: [
          Item.new(key: "communities", label: "Communities", path: "", grant: :list_communities)
        ]),
        Group.new(key: "activity", label: "Activity", items: [
          Item.new(key: "analytics", label: "Analytics", path: "analytics", grant: :view_analytics),
          Item.new(key: "audit", label: "Audit log", path: "audit", grant: :view_audit_log),
          Item.new(key: "backfill-proposals", label: "Backfill proposals", path: "backfill-proposals",
                   admin_only: true),
          Item.new(key: "jobs", label: "Jobs", path: "jobs", admin_only: true),
          Item.new(key: "logs", label: "Logs", path: "logs", admin_only: true)
        ]),
        Group.new(key: "connections", label: "Connections", items: [
          Item.new(key: "accounts", label: "Accounts", path: "accounts", admin_only: true),
          Item.new(key: "integrations", label: "Integrations", path: "integrations", admin_only: true)
        ]),
        Group.new(key: "access", label: "Access", items: [
          Item.new(key: "api-keys", label: "API keys", path: "api-keys", admin_only: true),
          Item.new(key: "operator-tokens", label: "Operator logins", path: "operator-tokens",
                   admin_only: true),
          Item.new(key: "viewers", label: "Viewers", path: "viewers", admin_only: true),
          Item.new(key: "administrators", label: "Administrators", path: "administrators",
                   admin_only: true),
          Item.new(key: "onboarding", label: "Onboarding", path: "onboarding", admin_only: true,
                   badge: "pending_spaces")
        ]),
        Group.new(key: "settings", label: "Settings", items: [
          Item.new(key: "datastore", label: "Datastore", path: "settings/datastore", admin_only: true)
        ])
      ].freeze

      module_function

      # The scopes a page carries: every value is a plain string-keyed
      # structure, both what the ERB fallback iterates and what goes on the wire as YAML.
      # @param role [Role, nil] the role behind the session
      # @param community [Object, nil] the community this page is about
      # @param prefix [String] the mount point, "" standalone
      # @param path [String] the page path being rendered, with the prefix on it
      # @param badges [Hash] counts by badge name, for the entries that carry one
      # @param counts [Hash] a community's own totals, by item key
      def scopes(role:, community: nil, prefix: "", path: "", badges: {}, counts: {})
        deployment = {
          "key" => "deployment", "label" => "Deployment", "current" => community.nil?,
          "path" => root_path(prefix),
          "groups" => deployment_groups(role: role, prefix: prefix, path: path, badges: badges)
        }
        return [deployment] if community.nil?

        [community_scope(community, role: role, prefix: prefix, path: path, badges: badges,
                         counts: counts),
         deployment]
      end

      # The communities a switcher may offer, which is exactly the set handed
      # in: a picker carrying anything else is a way into a community its
      # reader was just told they cannot read.
      def switcher(communities, community: nil, prefix: "")
        here = community && slug_of(community)
        communities.map do |row|
          { "slug" => slug_of(row), "label" => name_of(row), "status" => status_of(row),
            "path" => "#{prefix}/communities/#{slug_of(row)}",
            "current" => slug_of(row) == here }
        end
      end

      # The deployment scope's groups, resolved against a role: absolute
      # paths, entries this reader may not open dropped, the entry the current
      # path is on marked.
      def deployment_groups(role:, prefix: "", path: "", badges: {})
        resolve(DEPLOYMENT_GROUPS, role: role, community: Role::DEPLOYMENT, base: prefix, path: path,
                badges: badges)
      end

      # One community's groups, resolved the same way. Every path is under
      # /communities/:slug, and the grants are asked against that community
      # rather than the deployment.
      def community_groups(community, role:, prefix: "", path: "", badges: {}, counts: {})
        resolve(COMMUNITY_GROUPS, role: role, community: community,
                base: "#{prefix}/communities/#{slug_of(community)}", path: path, badges: badges,
                counts: counts)
      end

      # The breadcrumb for a page, deepest last, three entries at most since no
      # section nests deeper than a community and one of its pages (the last
      # carries no path). A renderer takes what it has room for: the pre-theme
      # header draws the whole trail, Series A's topbar the last two.
      def crumbs(community:, title:, prefix: "")
        trail = []
        if community
          trail << { "label" => "Communities", "path" => root_path(prefix) }
          trail << { "label" => name_of(community),
                     "path" => "#{prefix}/communities/#{slug_of(community)}" }
        end
        trail << { "label" => title, "path" => nil } if title
        return [] if trail.empty?

        trail.each_with_index.map do |crumb, index|
          crumb.merge("current" => index == trail.length - 1)
        end.tap { |built| built.last["path"] = nil }
      end

      # The label of the entry a path is on, for a breadcrumb tail. nil when
      # the path is not a section this catalogue names.
      def title_for(path:, community: nil, prefix: "")
        groups = community ? COMMUNITY_GROUPS : DEPLOYMENT_GROUPS
        base = community ? "#{prefix}/communities/#{slug_of(community)}" : prefix
        groups.flat_map(&:items)
              .find { |item| current?(href(base, item.path), path, landing: item.path.to_s.empty?) }
              &.label
      end

      def community_scope(community, role:, prefix:, path:, badges:, counts: {})
        {
          "key" => "community",
          "label" => name_of(community),
          "current" => true,
          "path" => "#{prefix}/communities/#{slug_of(community)}",
          "slug" => slug_of(community),
          "status" => status_of(community),
          "groups" => community_groups(community, role: role, prefix: prefix, path: path,
                                       badges: badges, counts: counts)
        }
      end

      # The shared half of both scopes: drop what this role may not open, put
      # the mount prefix on every path, mark the current entry.
      def resolve(groups, role:, community:, base:, path:, badges:, counts: {})
        groups.filter_map do |group|
          items = group.items.filter_map do |item|
            next nil unless permits?(role, item, community)

            entry(item, base: base, path: path, badges: badges, counts: counts)
          end
          next nil if items.empty?

          { "key" => group.key, "label" => group.label, "items" => items }
        end
      end

      def entry(item, base:, path:, badges:, counts: {})
        destination = href(base, item.path)
        row = { "key" => item.key, "label" => item.label, "path" => destination,
                "current" => current?(destination, path, landing: item.path.to_s.empty?) }
        badge_count = badges[item.badge].to_i
        row["badge"] = badge_count if item.badge && badge_count.positive?
        row["count"] = counts[item.key] if counts.key?(item.key)
        row
      end

      # Whether the page being drawn belongs to an entry. A section owns its
      # own sub-pages (/endpoints owns /endpoints/new), so the match is on the
      # path prefix; a landing entry is matched exactly, since its path is the
      # prefix of every other entry in the same scope.
      def current?(destination, path, landing:)
        return destination == path if landing

        path == destination || path.start_with?("#{destination}/")
      end

      # Whether this role is offered an entry at all. An entry that names no
      # gate is hidden rather than offered: a community section added with
      # neither a grant nor +open+ would otherwise appear in every community to
      # every signed-in reader.
      def permits?(role, item, community)
        return role&.administrator? == true if item.admin_only
        return true if item.open
        return false if item.grant.nil?

        !role.nil? && role.can?(item.grant, community: community)
      end

      def href(base, path)
        return root_path(base) if path.to_s.empty?

        "#{base}/#{path}"
      end

      def root_path(prefix) = prefix.to_s.empty? ? "/" : prefix.to_s

      def slug_of(community) = community.respond_to?(:slug) ? community.slug : community[:slug]

      def name_of(community) = community.respond_to?(:name) ? community.name : community[:name]

      def status_of(community)
        community.respond_to?(:status) ? community.status : community[:status]
      end
    end
  end
end
