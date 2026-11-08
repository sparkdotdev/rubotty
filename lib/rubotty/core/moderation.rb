# frozen_string_literal: true

require_relative "../security/grant_identity"

module Rubotty
  module Core
    # Moderation actions issued at one endpoint and carried out across a whole
    # room, since Telegram never tells a bot that a message was deleted;
    # without this a moderator would remove the relayed copy by hand on every
    # other platform. A command is never relayed as content, and the message
    # that carried it is swallowed; it produces a {Result} per endpoint,
    # summarised back to the issuer. Adapters declare what they support
    # through {Adapters::Capabilities#moderation}.
    module Moderation
      # Every action the framework knows about; adapters implement the subset they can.
      # `unban` reverses a temp-ban, issued by the warnings ladder's sanction expiry.
      ACTIONS = %i[delete ban unban kick mute unmute pin unpin unpinall clean lock unlock].freeze

      # Actions nobody types. `unban` reverses a temp-ban when its sanction
      # expires; `unpinall` is what /unpin carries out when it names a room
      # instead of replying to a message, and is a separate action because it
      # is a separate call on every platform that has one at all.
      PROGRAMMATIC_ACTIONS = %i[unban unpinall].freeze

      # What a person can actually type, which is every action bar those.
      TYPED_ACTIONS = (ACTIONS - PROGRAMMATIC_ACTIONS).freeze

      # Actions on a message, so the command must be issued as a reply to one.
      MESSAGE_ACTIONS = %i[delete pin unpin].freeze

      # Actions that operate on a person.
      USER_ACTIONS = %i[ban unban kick mute unmute].freeze

      # Actions that operate on the room itself rather than a message or a
      # person: no reply and no argument, just whatever room the invoking
      # command was typed in. No adapter carries these out; they are a
      # FeatureControls write over moderated_room's own config instead.
      #
      # `unpinall` and `clean` take no reply either and still do not belong
      # here: one is a real adapter call with a nil target, the other fans a
      # delete over every message BotMessages recorded. Both handled on their own.
      ROOM_ACTIONS = %i[lock unlock].freeze

      # Actions no adapter is ever asked to carry out, because the feature does
      # it: the two above, plus `clean`, which fans an ordinary delete over what
      # BotMessages recorded rather than being one call of its own. An adapter
      # declares nothing for these; every other action it either supports or
      # answers :unsupported for.
      FEATURE_ACTIONS = (ROOM_ACTIONS + %i[clean]).freeze

      # Human phrasing per action, as a [gerund, past] pair: the "Acknowledged, <gerund>
      # ..." notice and the "Successfully <past> ..." it is then edited to.
      PHRASES = {
        delete: ["deleting this message", "removed message"],
        ban: ["banning this user", "banned user"],
        unban: ["unbanning this user", "unbanned user"],
        kick: ["kicking this user", "kicked user"],
        mute: ["muting this user", "muted user"],
        unmute: ["unmuting this user", "unmuted user"],
        pin: ["pinning this message", "pinned message"],
        unpin: ["unpinning this message", "unpinned message"],
        unpinall: ["clearing every pinned message", "cleared every pinned message"],
        clean: ["clearing up after myself", "cleared up after myself"],
        lock: ["locking this room", "locked room"],
        unlock: ["unlocking this room", "unlocked room"]
      }.freeze

      module_function

      def message_action?(action) = MESSAGE_ACTIONS.include?(action.to_sym)

      def user_action?(action) = USER_ACTIONS.include?(action.to_sym)

      def room_action?(action) = ROOM_ACTIONS.include?(action.to_sym)

      def known?(action) = ACTIONS.include?(action.to_sym)

      # The gerund phrase for +action+, for the "Acknowledged, ..." notice.
      def gerund(action) = PHRASES.dig(action.to_sym, 0) || "carrying out #{action}"

      # The past tense phrase for +action+, for the "Successfully ..." notice.
      def past(action) = PHRASES.dig(action.to_sym, 1) || "carried out #{action}"

      # A moderation command, parsed out of a message and no longer one.
      class Command
        attr_reader :action, :issuer, :origin, :room_id, :target_ref, :target_user,
                    :target_user_id, :arguments, :source_ref, :targeting, :issuer_native_id,
                    :target_text

        # @param target_ref [MessageRef, nil] the message it acts on, in the ORIGIN
        #   endpoint's id space; nil for a reply-less /delete until resolved.
        # @param targeting [Symbol] how the target is named: :reply, :text (a recent
        #   message matching the argument text) or :own_last; only /delete varies.
        # @param issuer_native_id [String, nil] the issuer's own id on the origin, so a
        #   reply-less delete can confirm "my last message" ownership for a non-operator.
        # @param target_text [String, nil] what the target said, quoted to the operators
        #   and never written down; see PRIVACY.md.
        def initialize(action:, issuer:, origin:, room_id: nil, target_ref: nil,
                       target_user: nil, target_user_id: nil, arguments: [], source_ref: nil,
                       targeting: :reply, issuer_native_id: nil, target_text: nil)
          @action = action.to_sym
          @issuer = issuer
          @origin = origin
          @room_id = room_id
          @target_ref = target_ref
          @target_user = target_user
          # The target person's native id ON THE ENDPOINT being acted upon, filled in
          # per endpoint by the router since the same human has a different id on each.
          @target_user_id = target_user_id
          @arguments = Array(arguments).freeze
          @source_ref = source_ref
          @targeting = targeting.to_sym
          @issuer_native_id = issuer_native_id&.to_s
          @target_text = target_text&.to_s
          freeze
        end

        def needs_target_message? = Moderation.message_action?(action)

        def needs_target_user? = Moderation.user_action?(action)

        def with_target_user_id(id)
          self.class.new(
            action: action, issuer: issuer, origin: origin, room_id: room_id,
            target_ref: target_ref, target_user: target_user, target_user_id: id,
            arguments: arguments, source_ref: source_ref, targeting: targeting,
            issuer_native_id: issuer_native_id, target_text: target_text
          )
        end

        # A copy with its target message resolved: the feature fills in the id it found
        # for a reply-less /delete, and the pipeline treats it like a replied-to delete.
        # +text+ is what that message said, which the buffer the id came from also
        # holds, so an alert about it can quote it.
        def with_target_ref(ref, text: target_text)
          self.class.new(
            action: action, issuer: issuer, origin: origin, room_id: room_id,
            target_ref: ref, target_user: target_user, target_user_id: target_user_id,
            arguments: arguments, source_ref: source_ref, targeting: targeting,
            issuer_native_id: issuer_native_id, target_text: text
          )
        end

        def to_s = "#{action}#{target_ref ? " #{target_ref}" : ""}"
      end

      # What happened on one endpoint.
      class Result
        STATUSES = %i[done unsupported not_found forbidden failed skipped].freeze

        attr_reader :endpoint_id, :status, :detail

        def initialize(endpoint_id:, status:, detail: nil)
          @endpoint_id = endpoint_id.to_s
          @status = status.to_sym
          @detail = detail
          freeze
        end

        def ok? = status == :done

        def to_s
          detail ? "#{endpoint_id}: #{status} (#{detail})" : "#{endpoint_id}: #{status}"
        end
      end

      # A person, with their identities on every platform they use, so revoking access
      # is one deletion.
      class Operator
        attr_reader :name, :identities, :actions, :rooms, :community_id

        # @param name [String] human label, used in logs and result summaries
        # @param identities [Hash{Symbol=>Array<String>}] adapter name to native
        #   ids. One person may have several accounts on one platform.
        # @param actions [Array<Symbol>, :all] which actions they may perform
        # @param rooms [Array<String>, :all] which rooms they may act in
        # @param community_id [Integer, nil] the community whose rooms +rooms+
        #   names. Nil is the config-file path and the deployment-configured owner floor,
        #   neither of which has another tenant to reach.
        def initialize(name:, identities: {}, actions: :all, rooms: :all, community_id: nil)
          @name = name.to_s
          @identities = normalise(identities).freeze
          @actions = actions == :all ? :all : Array(actions).map(&:to_sym).freeze
          @rooms = rooms == :all ? :all : Array(rooms).map(&:to_s).freeze
          @community_id = community_id
          freeze
        end

        # Is this operator the person behind +native_id+ on +adapter_name+?
        def identity?(adapter_name, native_id)
          return false if native_id.nil?

          @identities.fetch(adapter_name.to_sym, []).include?(native_id.to_s)
        end

        # @param room_key [String] the room, in +community_id+'s key space
        # @param community_id [Integer, nil] the community that room belongs to.
        #   Required, because a room key is unique only within one: an operator
        #   of another community must never match, and a caller that lost the
        #   community is denied rather than answered.
        def may?(action, room_key, community_id:)
          return false unless @actions == :all || @actions.include?(action.to_sym)
          return false unless @community_id.nil? || @community_id == community_id
          return false unless @rooms == :all || @rooms.include?(room_key.to_s)

          true
        end

        def to_s = name

        private

        def normalise(identities)
          (identities || {}).each_with_object({}) do |(adapter, ids), out|
            out[adapter.to_sym] = Array(ids).map(&:to_s)
          end
        end
      end

      # Resolves an author on some endpoint into an {Operator}, or nobody;
      # fails closed, so an unknown user resolves to nil and the router
      # refuses the command. Above the configured/DB operators sits
      # {Security::ProtectedOperators}, a deployment-configured owner floor that always
      # resolves to an owner-level operator so access cannot be lost: it only
      # ever grants, it matches on the USERNAME, and it does not count
      # towards {#empty?}.
      class Directory
        # @param protected_operators [Security::ProtectedOperators, nil] the
        #   deployment-configured owner floor; nil builds a directory with no floor.
        def initialize(operators = [], protected_operators: Security::ProtectedOperators.default)
          @operators = operators.freeze
          @protected = protected_operators
        end

        attr_reader :operators

        # Only the EXPLICIT operators count: the owner floor must not flip an
        # unconfigured directory to non-empty and enable the command surface.
        def empty? = @operators.empty?

        # @param username [String, nil] the issuer's stable handle, matched against
        #   the deployment-configured owner floor. NEVER the display name.
        def resolve(adapter_name, native_id, username: nil)
          # Consulted first and by username, so a deployment-configured owner resolves whatever
          # the DB says. It can only ADD an operator.
          owner = @protected&.operator_for(adapter: adapter_name, username: username, native_id: native_id)
          return owner if owner

          # Room occupants on XMPP are represented by arbitrary nicknames,
          # including nicknames shaped like somebody else's bare JID. IRC
          # nicknames are equally temporary; only a scoped authenticated
          # account identity could authorise a future account-aware producer.
          return nil if adapter_name.to_s == "xmpp"
          if %w[irc matrix].include?(adapter_name.to_s)
            native_id = Security::GrantIdentity.native_id(adapter: adapter_name, native_id: native_id)
            return nil if native_id.nil?
          end

          @operators.find { |operator| operator.identity?(adapter_name, native_id) }
        end
      end
    end
  end
end
