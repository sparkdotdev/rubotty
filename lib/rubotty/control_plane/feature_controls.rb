# frozen_string_literal: true

require "json"

module Rubotty
  module ControlPlane
    # Reads and writes feature_settings: the shared operations core the admin
    # CLI drives now and the dashboard drives later, dealing only in rows and
    # ids, knowing nothing about OptionParser, HTTP, or rendering. A write
    # targets exactly one row, never a fan-out: "all" is the community-wide
    # default (room_id NULL) every room inherits, and a room selector matches,
    # in order, a room key, a room label (case-insensitive), then an endpoint
    # or route key.
    class FeatureControls
      # Raised for a request that cannot be carried out: an unknown community, an
      # unknown feature, or a room selector that matched nothing.
      class Invalid < Rubotty::Error; end

      # How far under relay_claim_ttl backfill's safe_horizon_seconds must stay,
      # not a bare less-than: at exactly equal, a message at the far edge of the
      # window has its dedup claim expire the same instant the sweep re-reads it,
      # so it reads as unrelayed and goes out again. An hour comfortably covers a
      # paced sweep's own run time under the default pacing (max_messages at
      # interval_ms apart) plus ordinary clock skew between when a claim was
      # written and when the sweep re-checks it.
      BACKFILL_HORIZON_MARGIN_SECONDS = 3600

      # @param registry [Registry, nil] reloaded after a write when present; nil
      #   in the CLI (a separate process) and in a pure-data test
      # @param relay_claim_ttl [Integer, nil] the deployment's actual
      #   behaviour.relay_claim_ttl, checked against a written safe_horizon_seconds
      #   rather than an assumed default. Falls back to
      #   {Config::Model::DEFAULT_RELAY_CLAIM_TTL} when none is configured.
      def initialize(models:, registry: nil, logger: nil, clock: -> { Time.now }, relay_claim_ttl: nil)
        @models = models
        @registry = registry
        @logger = logger
        @clock = clock
        @relay_claim_ttl = relay_claim_ttl || Config::Model::DEFAULT_RELAY_CLAIM_TTL
      end

      # The community row for a slug, or raise {Invalid} naming it.
      def community!(slug)
        row = @models.community.where(slug: slug.to_s).first
        return row if row

        raise Invalid, "no community with slug #{slug.to_s.inspect}. " \
                       "Run `rubotty seed` first, or check `rubotty topology`."
      end

      # The feature_settings rows in scope: every row for the community with no
      # selector, just the community-wide default for "all", or one room's rows for
      # a room selector. Each row carries the room's room_key (nil for the default).
      #
      # @return [Array<Hash>] { scope:, room_key:, feature:, enabled:, config: }
      def list(community, selector: nil)
        rows =
          if selector.nil?
            @models.feature_setting.where(community_id: community.id).all
          elsif community_selector?(selector)
            @models.feature_setting.where(community_id: community.id, room_id: nil).all
          else
            room = resolve_room(community, selector)
            @models.feature_setting.where(community_id: community.id, room_id: room.id).all
          end
        rows.map { |row| describe_row(row) }.sort_by { |entry| [entry[:room_key].to_s, entry[:feature]] }
      end

      # Turn a feature on for a scope. Returns the affected rows.
      def enable(community:, selector:, feature:)
        write(community: community, selector: selector, feature: feature, enabled: true)
      end

      # Turn a feature off for a scope.
      def disable(community:, selector:, feature:)
        write(community: community, selector: selector, feature: feature, enabled: false)
      end

      # Set one config key under a feature's config blob, merged into whatever is
      # already there. Does not change an EXISTING row's enabled state; a brand-new
      # row inherits instead, see {#inherited_enabled}.
      def set(community:, selector:, feature:, key:, value:)
        raise Invalid, "a config key is required" if key.to_s.empty?

        coerced = snap_to_step(feature: feature, key: key, value: coerce_value(value, feature: feature, key: key))
        validate_range!(feature: feature, key: key, value: coerced)
        validate_backfill_horizon!(feature: feature, key: key, value: coerced)
        write(community: community, selector: selector, feature: feature,
              config_merge: { key.to_s => coerced })
      end

      # Change one config key from its current value, with the row held for the
      # whole read-modify-write, since two operators saving at once could
      # otherwise each write back a list missing the other's entry.
      #
      # @yieldparam current [Object, nil] the key's stored value, nil when unset
      # @yieldreturn [Object] what to store under the key
      # @return [Array<Hash>] the affected row, as {#list} describes it
      def update(community:, selector:, feature:, key:)
        raise Invalid, "a config key is required" if key.to_s.empty?

        feature = known!(feature)
        room_id = target_room_id(community, selector)
        row = @models.db.transaction do
          existing = locked_row(community_id: community.id, room_id: room_id, feature: feature)
          current = existing&.json_value(:config)&.fetch(key.to_s, nil)
          coerced = snap_to_step(feature: feature, key: key,
                                 value: coerce_value(yield(current), feature: feature, key: key))
          validate_range!(feature: feature, key: key, value: coerced)
          validate_backfill_horizon!(feature: feature, key: key, value: coerced)
          upsert(community_id: community.id, room_id: room_id, feature: feature, enabled: nil,
                 config_merge: { key.to_s => coerced }, existing: existing)
        end
        reload
        [describe_row(row)]
      end

      # The deployment-wide default row for one feature: no community, no room.
      # Nil when the deployment has never set one. The last live tier every
      # community's own settings fall back through ahead of a class's own
      # hardcoded default.
      def global_entry(feature)
        feature = known!(feature)
        row = @models.feature_setting.where(community_id: nil, room_id: nil, feature: feature).first
        row ? describe_row(row) : nil
      end

      # Set one config key on the deployment-wide default for a feature, merged
      # into whatever is already there: the same read-modify-write {#set} gives
      # a community or room scope, minus the selector, since there is no room
      # or community to resolve at this scope. A brand-new row starts enabled;
      # nothing today reads this scope's own enabled flag, since every
      # feature's enablement still resolves through the community it actually
      # runs in.
      def set_global(feature:, key:, value:)
        raise Invalid, "a config key is required" if key.to_s.empty?

        feature = known!(feature)
        coerced = snap_to_step(feature: feature, key: key, value: coerce_value(value, feature: feature, key: key))
        validate_range!(feature: feature, key: key, value: coerced)
        validate_backfill_horizon!(feature: feature, key: key, value: coerced)
        row = @models.db.transaction do
          existing = @models.feature_setting.where(community_id: nil, room_id: nil, feature: feature).for_update.first
          upsert(community_id: nil, room_id: nil, feature: feature, enabled: existing ? nil : true,
                 config_merge: { key.to_s => coerced }, existing: existing)
        end
        reload
        describe_row(row)
      end

      # Delete a room's OWN row for a feature, so the room falls back to inheriting
      # the community-wide default again. Refuses an "all" selector: the community
      # default has no broader scope of its own to fall back to.
      #
      # @return [Boolean] whether a row was actually removed
      def reset(community:, selector:, feature:)
        feature = feature.to_s
        if community_selector?(selector)
          raise Invalid, "the community-wide default has no broader scope to fall back to; disable it instead."
        end

        room = resolve_room(community, selector)
        row = @models.feature_setting.where(community_id: community.id, room_id: room.id, feature: feature).first
        return false if row.nil?

        row.destroy
        reload
        true
      end

      # The one room a selector resolves to, in the community; raises {Invalid}
      # when nothing matches. See the class comment for the match order.
      def resolve_room(community, selector)
        selector = selector.to_s
        rooms = @models.room.where(community_id: community.id).all

        room = rooms.find { |candidate| candidate.room_key == selector }
        room ||= rooms.find { |candidate| candidate.label.to_s.casecmp?(selector) }
        room ||= room_via_endpoint(community, selector)

        return room if room

        raise Invalid, "no room in community #{community.slug.inspect} matched " \
                       "#{selector.inspect}. Use a room key, a room label, an endpoint key, " \
                       "a route key, or `all`."
      end

      # A caller naming a platform endpoint (its endpoint_key, or the raw route_key
      # an adapter addresses it by) resolves to THAT endpoint's room, via
      # room_channels, preferring the receiving row when a hub group shares one
      # route_key. Nil rather than raising, so {#resolve_room} owns the error.
      def room_via_endpoint(community, selector)
        channels = @models.channel.where(community_id: community.id).all
        channel = channels.find { |candidate| candidate.endpoint_key == selector }
        channel ||= channels.find { |candidate| candidate.route_key == selector && candidate.receives }
        channel ||= channels.find { |candidate| candidate.route_key == selector }
        return nil if channel.nil?

        join = @models.room_channel.where(channel_id: channel.id).first
        join && @models.room[join.room_id]
      end

      # Whether a selector names the community-wide scope rather than a room.
      def community_selector?(selector)
        selector.to_s.casecmp?("all")
      end

      # Turn a raw value into a stored JSON value: a non-String (a Hash or
      # Array straight off parsed YAML) is stored as-is, never stringified
      # first, since that would corrupt it into Ruby's `=>` syntax before
      # JSON.parse. A String is guessed at: an explicit JSON scalar or
      # container wins, then a comma splits a value whose field the schema
      # declares a list, otherwise the bare string is kept. The schema is what
      # decides that split, so prose in a :string field keeps its own commas.
      def coerce_value(raw, feature: nil, key: nil)
        return raw unless raw.is_a?(String)

        json = try_json(raw)
        return json unless json == NO_JSON
        return raw.split(",").map(&:strip).reject(&:empty?) if splits_on_comma?(feature, key) && raw.include?(",")

        raw
      end

      # Whether a comma in this value means a list. The schema decides where it
      # describes the field: a declared :array splits and every other declared
      # type does not, which is what keeps prose in a :string field whole. A key
      # the schema does not describe keeps the old convenience, since taking it
      # away would silently change values nothing here can reason about.
      def splits_on_comma?(feature, key)
        return true if feature.nil? || key.nil?

        field = Features::Catalog.config_schema(feature.to_s)&.fields&.dig(key.to_sym)
        field.nil? || field.type == :array
      end

      private

      NO_JSON = Object.new.freeze
      private_constant :NO_JSON

      # Parse a string as JSON only when it clearly IS json, so a bare word is never
      # read as JSON. Returns {NO_JSON} for "not json", distinct from a real null.
      def try_json(string)
        stripped = string.strip
        return NO_JSON unless stripped.match?(/\A[\[{"]/) ||
                              stripped.match?(/\A-?\d+(\.\d+)?\z/) ||
                              %w[true false null].include?(stripped)

        JSON.parse(stripped)
      rescue JSON::ParserError
        NO_JSON
      end

      # The one write path behind enable / disable / set: resolve the scope to a
      # single target room_id (nil for the community scope), upsert the one row it
      # names, then reload. Validates the feature name against the catalog first.
      def write(community:, selector:, feature:, enabled: nil, config_merge: nil)
        feature = known!(feature)
        room_id = target_room_id(community, selector)
        row = @models.db.transaction do
          upsert(community_id: community.id, room_id: room_id,
                 feature: feature, enabled: enabled, config_merge: config_merge)
        end
        reload
        [describe_row(row)]
      end

      # +feature+ as a string, having checked it against the catalog and confirmed
      # it actually takes a feature_settings row. identify_topic and
      # disabled_command_notice are catalogued (so a config CLI or dashboard read
      # recognises the name) but always_enabled?, so a write here would sit in the
      # table lying about a state {Features::Pipeline#enabled?} never consults.
      def known!(feature)
        feature = feature.to_s
        klass = Features::Catalog.class_for(feature)
        if klass.nil?
          raise Invalid, "unknown feature #{feature.inspect}. Known features: " \
                         "#{Features::Catalog.names.join(", ")}."
        end
        if klass.always_enabled?
          raise Invalid, "#{feature} always runs here; there is nothing to enable, disable, or configure."
        end

        feature
      end

      # Refuses a backfill safe_horizon_seconds that does not sit comfortably
      # under relay_claim_ttl (see {BACKFILL_HORIZON_MARGIN_SECONDS}); a no-op
      # for every other feature and key. This is the one place {#set} and
      # {#update} both pass a coerced value through, so the API, dashboard,
      # CLI and operator console all get the same answer.
      # Round a value onto the scale its field declares, so what the API and the
      # CLI accept is what the form's own control could have produced. A field
      # with no step, or a value that is not a number, is handed back untouched.
      def snap_to_step(feature:, key:, value:)
        return value unless value.is_a?(Numeric)

        step = Features::Catalog.config_schema(feature.to_s)&.fields&.dig(key.to_sym)&.step
        return value if step.nil? || step.to_f <= 0

        # Rounded to the step's own precision as well, or a float step leaves
        # 0.7000000000000001 where 0.7 was meant.
        snapped = (value.to_f / step.to_f).round * step.to_f
        snapped.round(step_precision(step))
      end

      # How many decimal places the step itself carries, which is as many as a
      # value snapped onto it can need.
      def step_precision(step)
        text = step.to_f.to_s
        decimals = text.split(".", 2)[1].to_s.delete_suffix("0")
        decimals.length
      end

      # A field the schema bounded, held to it wherever it is written. Nothing
      # runs a feature's config_schema against a stored blob, so without this
      # the scale the form offers is one the API and the CLI would ignore.
      def validate_range!(feature:, key:, value:)
        return unless value.is_a?(Numeric)

        field = Features::Catalog.config_schema(feature.to_s)&.fields&.dig(key.to_sym)
        return if field&.range.nil? || field.range.cover?(value)

        raise Invalid, "#{feature}.#{key} must be between #{field.range.first} and #{field.range.last}, " \
                       "got #{value}"
      end

      def validate_backfill_horizon!(feature:, key:, value:)
        return unless feature.to_s == Features::Backfill.feature_name && key.to_s == "safe_horizon_seconds"
        return unless value.is_a?(Numeric)

        ceiling = @relay_claim_ttl - BACKFILL_HORIZON_MARGIN_SECONDS
        return if value <= ceiling

        raise Invalid, "backfill.safe_horizon_seconds must be at least " \
                       "#{BACKFILL_HORIZON_MARGIN_SECONDS} seconds under relay_claim_ttl " \
                       "(currently #{@relay_claim_ttl}s), or a message at the edge of the window can " \
                       "have its dedup claim expire the moment the sweep re-reads it and go out again. " \
                       "Got #{value}s; use at most #{ceiling}s."
      end

      # The room_id a write targets: nil for the community scope, else the room's.
      def target_room_id(community, selector)
        return nil if community_selector?(selector)

        resolve_room(community, selector).id
      end

      # Find-or-create the (community, room-or-default, feature) row, applying the
      # enabled change and/or the config merge, and always bumping updated_at so
      # the change detector sees the write.
      def upsert(community_id:, room_id:, feature:, enabled:, config_merge:, existing: :unread)
        now = @clock.call
        if existing == :unread
          existing = locked_row(community_id: community_id, room_id: room_id, feature: feature)
        end
        if existing
          existing.update(update_attributes(existing, enabled, config_merge, now))
          existing
        else
          @models.feature_setting.create(
            community_id: community_id, room_id: room_id, feature: feature,
            enabled: enabled.nil? ? inherited_enabled(community_id, room_id, feature) : enabled,
            config: Models.dump_json(config_merge || {}),
            created_at: now, updated_at: now
          )
        end
      end

      # The row a write is about to change, held for the rest of the transaction.
      # Without the lock two writers read the same config, each merges its own key
      # into it, and the second write drops the first.
      def locked_row(community_id:, room_id:, feature:)
        @models.feature_setting
               .where(community_id: community_id, room_id: room_id, feature: feature)
               .for_update.first
      end

      # The enabled state a brand-new row starts at when the caller did not say. A
      # room row inherits the community default, because a room row takes
      # unconditional priority and starting it off would disable an enabled feature.
      def inherited_enabled(community_id, room_id, feature)
        if room_id
          community_row = @models.feature_setting
                                 .where(community_id: community_id, room_id: nil, feature: feature).first
          return to_bool(community_row.enabled) if community_row
        end

        Features::Catalog.class_for(feature)&.default_enabled? || false
      end

      private

      def update_attributes(existing, enabled, config_merge, now)
        attributes = { updated_at: now }
        attributes[:enabled] = enabled unless enabled.nil?
        if config_merge
          merged = existing.json_value(:config).merge(config_merge)
          attributes[:config] = Models.dump_json(merged)
        end
        attributes
      end

      def describe_row(row)
        {
          scope: row.community_id.nil? ? :global : (row.room_id.nil? ? :community : :room),
          room_key: room_key_for(row.room_id),
          feature: row.feature,
          enabled: to_bool(row.enabled),
          config: row.json_value(:config)
        }
      end

      def room_key_for(room_id)
        return nil if room_id.nil?

        @models.room[room_id]&.room_key
      end

      # Rebuild and swap the Snapshot when a Registry is wired; a no-op in the
      # CLI and in a pure-data test. A reload failure never loses a committed
      # write, since the rows are already saved and only live recognition is
      # delayed.
      def reload
        @registry&.reload
      rescue StandardError => e
        @logger&.warn { "feature controls: snapshot reload after a write failed: #{e.message}" }
      end

      # SQLite returns booleans as 0/1 through some Sequel paths, so normalise
      # rather than trusting the raw value (0 is truthy in Ruby).
      def to_bool(value)
        return value if value == true || value == false

        [1, "1", "t", "true"].include?(value)
      end
    end
  end
end
