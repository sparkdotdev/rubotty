# frozen_string_literal: true

require "sequel"

module Rubotty
  module ControlPlane
    # The dashboard's "where is X" lookup: one pass over the control
    # plane, read only. Every query goes through {Scope#narrow}, which
    # puts the reader's grants into the WHERE clause itself, so a row
    # outside their grants is never fetched. The REST API answers 404
    # rather than 403 cross-community so a result list can't leak a
    # tenant's existence either. Matching is a case-folded LIKE
    # substring, no ranking, no index: a deliberate tradeoff, identical
    # across all three backends.
    class Search
      # Below this a query matches most of the deployment and answers nothing
      # useful, so it answers nothing at all.
      MIN_QUERY_LENGTH = 2

      # Most hits one kind may contribute, so a community with a thousand alerts
      # cannot crowd every other kind out of the answer.
      PER_KIND_LIMIT = 5

      # Most destinations one query offers. Higher than {PER_KIND_LIMIT}: a
      # section name typed on a deployment with many communities means one hit
      # per community, and they are all the same answer to the same question.
      DESTINATION_LIMIT = 12

      # Most entity hits one query answers with, and the ceiling a caller may
      # raise its own limit to. An unbounded search over a large deployment is
      # a performance problem waiting for the first busy tenant.
      DEFAULT_LIMIT = 25
      MAX_LIMIT = 100

      # How much of a description or an alert body a hit carries. Enough to tell
      # two similar rows apart, short enough that this is no place to read one.
      MAX_DETAIL = 120

      # The Files page is the one destination here that no {Dashboard::Role}
      # action names, because its route is require_admin!. The scope builder
      # answers this one with the administrator check instead.
      FILES_ACTION = :view_files

      # The dashboard pages a search may offer, in the order it offers them,
      # each with the read action its own route already checks. A page absent
      # from this list is unreachable from here, which is the safe default for
      # one added later.
      SECTIONS = [
        ["", "Overview", :view_community],
        ["rooms", "Rooms", :view_rooms],
        ["platforms", "Platforms", :view_platforms],
        ["discovered", "Discovered connections", :view_discovered],
        ["endpoints", "Script endpoints", :view_endpoints],
        ["features", "Features", :view_community],
        ["word-filter", "Word filter", :view_community],
        ["faq", "FAQ", :view_community],
        ["redirections", "Redirections", :view_community],
        ["webhooks", "Webhooks", :view_community],
        ["scripts", "Scripts", :view_scripts],
        ["alerts", "Alerts", :view_community],
        ["moderation", "Moderation", :view_community],
        ["people", "People", :view_community],
        ["participation", "Room games", :view_community],
        ["events", "Events", :view_community],
        ["polls", "Polls", :view_community],
        ["guests", "Guests", :view_guests],
        ["files", "Files", FILES_ACTION],
        ["operators", "Operators", :view_operators],
        ["analytics", "Analytics", :view_analytics],
        ["audit", "Audit log", :view_audit_log]
      ].freeze

      # Every read action this service asks a scope about, which is the whole
      # question the dashboard's scope builder has to answer.
      ACTIONS = SECTIONS.map { |entry| entry[2] }.uniq.freeze

      # section key => the action gating it, for the kinds below and for the
      # destination filter.
      ACTION_BY_SECTION = SECTIONS.to_h { |key, _label, action| [key, action] }.freeze

      # Which communities a search may read, and which read actions it may take
      # in each. The one place scoping happens: {#narrow} is how every query in
      # this service reaches a table, so no kind can quietly skip it and a
      # reader's grants are always in the SQL rather than applied afterwards to
      # rows that were already fetched.
      class Scope
        # An administrator or a deployment-wide viewer: every community, with
        # one set of actions that holds in all of them.
        def self.deployment_wide(actions:) = new(deployment_wide: true, actions: actions)

        # An operator or a community-scoped viewer: only the communities named,
        # each with its own actions, which genuinely differ, since a viewer
        # grant on one community reads more of it than operating another does.
        def self.communities(actions_by_community_id:) = new(by_community: actions_by_community_id)

        # Reads nothing anywhere, which is what a session with no role gets.
        def self.none = new

        def initialize(deployment_wide: false, actions: [], by_community: {})
          @deployment_wide = deployment_wide == true
          @actions = actions.map(&:to_sym).uniq.freeze
          @by_community = by_community.to_h { |id, list| [id.to_i, list.map(&:to_sym).uniq.freeze] }.freeze
        end

        def deployment_wide? = @deployment_wide

        # Whether +action+ is permitted anywhere at all, so a kind nobody may
        # read is skipped before it costs a query.
        def anywhere?(action)
          return @actions.include?(action.to_sym) if deployment_wide?

          @by_community.any? { |_id, list| list.include?(action.to_sym) }
        end

        # Whether +action+ is permitted in one named community.
        def allows?(action, community_id:)
          return @actions.include?(action.to_sym) if deployment_wide?

          @by_community.fetch(community_id.to_i, []).include?(action.to_sym)
        end

        # +dataset+ narrowed to the communities where +action+ is permitted. A
        # named-community scope always ends up with a literal id list in the
        # WHERE clause, and a scope holding none produces an empty IN, which
        # every backend renders as a predicate matching nothing.
        def narrow(dataset, action, column: :community_id)
          return dataset if deployment_wide? && @actions.include?(action.to_sym)

          dataset.where(column => community_ids(action))
        end

        # The communities where +action+ is permitted. Empty for a
        # deployment-wide scope, which names none and needs none.
        def community_ids(action)
          @by_community.filter_map { |id, list| id if list.include?(action.to_sym) }
        end
      end

      # One searchable kind of row: the {Models} accessor it reads, the columns
      # matched, the columns a title and a detail line are taken from (first
      # non-blank wins), the ordering that makes an answer stable, and the
      # section a hit points at, which is also what decides its read action.
      Kind = Struct.new(:name, :model, :section, :columns, :title, :detail, :order,
                        :scope_column, :select, :distinct, keyword_init: true) do
        def action = ACTION_BY_SECTION.fetch(section)

        def column = scope_column || :community_id
      end

      # The passively-learned identity directory is deliberately absent: it
      # holds people who have never asked to be indexed and has its own
      # retention and anti-stalking rule. The one search over it
      # ({IdentityDirectory#search}) is a mute-target picker on the
      # moderation page, not navigation, and it stays that way.
      KINDS = [
        Kind.new(name: :community, model: :community, section: "", scope_column: :id,
                 columns: %i[slug name], title: %i[name slug], detail: %i[status], order: %i[slug]),
        Kind.new(name: :room, model: :room, section: "rooms",
                 columns: %i[room_key label], title: %i[label room_key], detail: %i[room_key],
                 order: %i[room_key id]),
        Kind.new(name: :platform_connection, model: :platform_connection, section: "platforms",
                 columns: %i[label adapter account external_id], title: %i[label external_id],
                 detail: %i[adapter], order: %i[adapter external_id id]),
        Kind.new(name: :endpoint, model: :script_endpoint, section: "endpoints",
                 columns: %i[name description], title: %i[name], detail: %i[description],
                 order: %i[name id]),
        # An operator row carries no name of its own: the name is on the person
        # the grant was made to, which is why this one kind reads two tables.
        Kind.new(name: :operator, model: nil, section: "operators",
                 scope_column: Sequel[:operators][:community_id],
                 columns: ["people.name"], title: %i[name], detail: %i[granted_by],
                 order: [Sequel[:people][:name], Sequel[:operators][:id]]),
        # One hit per feature rather than one per row: a feature set on four
        # rooms is four rows and one answer.
        Kind.new(name: :feature, model: :feature_setting, section: "features",
                 columns: %i[feature], title: %i[feature], detail: nil,
                 select: %i[community_id feature], distinct: true, order: %i[community_id feature]),
        Kind.new(name: :script, model: :community_script, section: "scripts",
                 columns: %i[name], title: %i[name], detail: %i[kind], order: %i[name id]),
        Kind.new(name: :webhook, model: :webhook_subscription, section: "webhooks",
                 columns: %i[label url room_key], title: %i[label url], detail: %i[room_key],
                 order: %i[label id]),
        Kind.new(name: :redirection, model: :redirection, section: "redirections",
                 columns: %i[source_endpoint_id target_room_id operator],
                 title: %i[target_room_id], detail: %i[source_endpoint_id], order: [Sequel.desc(:id)]),
        Kind.new(name: :alert, model: :alert, section: "alerts",
                 columns: %i[text script room_key], title: %i[text], detail: %i[script],
                 order: [Sequel.desc(:id)]),
        Kind.new(name: :event, model: :event, section: "events",
                 columns: %i[title description game_title], title: %i[title], detail: %i[description],
                 order: [Sequel.desc(:starts_at), Sequel.desc(:id)]),
        Kind.new(name: :poll, model: :poll, section: "polls",
                 columns: %i[question detail], title: %i[question], detail: %i[detail],
                 order: [Sequel.desc(:id)])
      ].freeze

      # A row that matched: what it is, which community it belongs to, and the
      # page it is shown on. The path is relative to wherever the dashboard is
      # mounted, the same convention the navigation uses.
      Hit = Struct.new(:kind, :community_slug, :community_name, :title, :detail, :path, keyword_init: true)

      # A dashboard page offered because its own name matched, or because the
      # community it belongs to did. A different kind of answer from {Hit}: it
      # names no row and only says where to go.
      Destination = Struct.new(:section, :label, :community_slug, :community_name, :path, keyword_init: true)

      # What one query answers with. +query+ is the normalised needle that was
      # actually searched rather than the raw input, and +truncated+ says a cap
      # was reached and there is more behind it, so a caller can say so instead
      # of implying this is everything.
      Results = Struct.new(:query, :entities, :destinations, :truncated, keyword_init: true) do
        def truncated? = truncated == true

        def empty? = entities.empty? && destinations.empty?
      end

      # @param models [ControlPlane::Models] bound to the control-plane database
      # @param logger [#warn, nil]
      def initialize(models:, logger: nil)
        @models = models
        @logger = logger
      end

      # Everything +query+ matches that +scope+ is allowed to see.
      #
      # @param scope [Scope] the reader's grants, applied in SQL by every query
      #   this makes
      # @param limit [Integer] most entity hits to answer with, clamped to
      #   {MAX_LIMIT}. Destinations are capped separately at
      #   {DESTINATION_LIMIT}.
      # @return [Results]
      def call(query:, scope:, limit: DEFAULT_LIMIT)
        needle = presence(query)&.downcase
        return blank(needle) if needle.nil? || needle.length < MIN_QUERY_LENGTH

        cap = limit.to_i.clamp(1, MAX_LIMIT)
        hits, hits_cut = entity_hits(needle, scope)
        offers, offers_cut = destination_hits(needle, scope)
        Results.new(
          query: needle, entities: hits.first(cap), destinations: offers,
          truncated: hits_cut || offers_cut || hits.length > cap
        )
      end

      private

      def blank(needle) = Results.new(query: needle.to_s, entities: [], destinations: [], truncated: false)

      # Every kind, each capped on its own, with the community a hit belongs to
      # resolved once at the end rather than joined onto twelve queries.
      def entity_hits(needle, scope)
        pattern = Util::LikePattern.contains(needle)
        cut = false
        found = KINDS.flat_map do |kind|
          # A kind the reader may not read anywhere never reaches the database.
          next [] unless scope.anywhere?(kind.action)

          rows = matching(kind, pattern, scope).all
          cut ||= rows.length > PER_KIND_LIMIT
          rows.first(PER_KIND_LIMIT).map { |row| [kind, row] }
        end
        [build_hits(found), cut]
      end

      # One kind's matching rows, narrowed to the reader's grants BEFORE the
      # text predicate is added, one over the cap so the caller can tell a full
      # page from an exact fit.
      def matching(kind, pattern, scope)
        dataset = base_dataset(kind)
        dataset = dataset.select(*kind.select) if kind.select
        dataset = dataset.distinct if kind.distinct
        scope.narrow(dataset, kind.action, column: kind.column)
             .where(any_like(kind.columns, pattern))
             .order(*kind.order)
             .limit(PER_KIND_LIMIT + 1)
      end

      # Plain hashes for every kind, so a partial select or a DISTINCT never has
      # to round trip through a model instance.
      def base_dataset(kind)
        return operator_dataset if kind.name == :operator

        @models.public_send(kind.model).dataset.naked
      end

      # The operators kind's two-table read. Selected with explicit aliases so
      # the hash a row arrives as looks like every other kind's.
      def operator_dataset
        @models.db[:operators]
               .join(:people, id: :person_id)
               .select(Sequel[:operators][:id].as(:id),
                       Sequel[:operators][:community_id].as(:community_id),
                       Sequel[:operators][:granted_by].as(:granted_by),
                       Sequel[:people][:name].as(:name))
      end

      def any_like(columns, pattern)
        columns.map { |column| Util::LikePattern.like_lower(column, pattern) }
               .reduce { |left, right| Sequel.|(left, right) }
      end

      def build_hits(found)
        names = community_names(found.map { |kind, row| community_id_of(kind, row) })
        found.filter_map do |kind, row|
          community = names[community_id_of(kind, row)]
          next if community.nil?

          Hit.new(kind: kind.name, community_slug: community[:slug], community_name: community[:name],
                  title: first_present(row, kind.title).to_s, detail: first_present(row, kind.detail),
                  path: path_for(community[:slug], kind.section))
        end
      end

      def community_id_of(kind, row) = kind.name == :community ? row[:id] : row[:community_id]

      # Slugs and names for ids that have already passed scoping, so this
      # lookup needs no narrowing of its own.
      def community_names(ids)
        return {} if ids.empty?

        @models.community.dataset.naked.where(id: ids.uniq).select(:id, :slug, :name).to_hash(:id)
      end

      # The pages on offer: the sections whose own name matched, in every
      # community the reader may open them in, plus every section of a community
      # whose slug or name matched, which is what makes typing a slug a way into
      # that community's resources.
      def destination_hits(needle, scope)
        named = SECTIONS.select { |key, label, _| section_matches?(key, label, needle) }
        rows = destination_communities(needle, scope, named.any?)
        cut = rows.length > DESTINATION_LIMIT
        offers = rows.first(DESTINATION_LIMIT).flat_map do |row|
          sections = community_matches?(row, needle) ? SECTIONS : named
          sections.filter_map { |key, label, action| destination(row, key, label, action, scope) }
        end
        [offers.first(DESTINATION_LIMIT), cut || offers.length > DESTINATION_LIMIT]
      end

      # The communities a destination may be offered in: the ones whose slug or
      # name matched, or every readable one once the query named a section
      # rather than a community. Narrowed on view_community in SQL either way.
      def destination_communities(needle, scope, named_section)
        dataset = scope.narrow(@models.community.dataset.naked, :view_community, column: :id)
        unless named_section
          dataset = dataset.where(any_like(%i[slug name], Util::LikePattern.contains(needle)))
        end
        dataset.select(:id, :slug, :name).order(:slug).limit(DESTINATION_LIMIT + 1).all
      end

      def destination(row, key, label, action, scope)
        return nil unless scope.allows?(action, community_id: row[:id])

        Destination.new(section: key, label: label, community_slug: row[:slug],
                        community_name: row[:name], path: path_for(row[:slug], key))
      end

      # Overview's key is empty, so it is reachable by its label alone rather
      # than by every query in the deployment.
      def section_matches?(key, label, needle)
        (!key.empty? && key.include?(needle)) || label.downcase.include?(needle)
      end

      def community_matches?(row, needle)
        row[:slug].to_s.downcase.include?(needle) || row[:name].to_s.downcase.include?(needle)
      end

      def path_for(slug, section)
        section.to_s.empty? ? "/communities/#{slug}" : "/communities/#{slug}/#{section}"
      end

      def first_present(row, columns)
        return nil if columns.nil?

        columns.filter_map { |column| presence(row[column]) }.first&.slice(0, MAX_DETAIL)
      end

      def presence(value)
        return nil if value.nil?

        text = value.to_s.strip
        text.empty? ? nil : text
      end
    end
  end
end
