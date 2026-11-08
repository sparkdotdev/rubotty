# frozen_string_literal: true

require "json"

module Rubotty
  module ControlPlane
    # Operator admin console over DM. Adapters call {#handle_dm} and send
    # back the text it returns; the console does no I/O itself and remembers
    # which community the sender is focused on between messages. {AdminReach}
    # resolves the sender to every community they operate, and that list is
    # the console's entire authority: a sender who operates none falls
    # through to {ControlLane}.
    class OperatorConsole
      # Key namespace, so console state does not collide with other bridge_state keys.
      SESSION_PREFIX = "console"

      # {FeatureControls}'s selector for the community-wide default row.
      COMMUNITY_SCOPE = "all"

      # The words the client already owns in a private chat, which is the only
      # place this console is ever read. `start` opens the chat and `stop` asks
      # to be left alone, so a bare one of either is the member's own gesture
      # and never the lifecycle verb. `resume` and `suspend` are ours and mean
      # the lifecycle verb outright; these two only do when an explicit
      # `@<slug>` says which community was meant, which nobody types by accident.
      RESERVED_WORDS = %w[start stop].freeze

      # The verbs each kind of alert tells an operator to answer with. Reading a
      # quoted alert for its own pair alone is what keeps a proposal code out of
      # the vindication lookup, and an action code out of the proposal lookup.
      VINDICATION_VERBS = /vindicate|innocent/
      PROPOSAL_VERBS = /approve|reject/

      # In-memory session store, keyed by the operator's (adapter, account, native
      # id). The runtime injects the durable store instead.
      class MemorySessions
        def initialize = @store = {}

        def read(key) = @store[key] || {}

        def write(key, value) = @store[key] = value
      end

      # Durable session store over the +bridge_state+ key/value table, so a
      # multi-step conversation survives a restart and is shared across instances.
      class KvSessions
        # Seconds an idle session survives. Any command refreshes it.
        DEFAULT_TTL = 3600

        def initialize(store, ttl: DEFAULT_TTL)
          @store = store
          @ttl = ttl
        end

        def read(key)
          raw = @store.get_state(namespaced(key))
          raw.nil? || raw.empty? ? {} : JSON.parse(raw)
        rescue JSON::ParserError
          {}
        end

        def write(key, value)
          @store.put_state(namespaced(key), JSON.generate(value), expires_at: Time.now + @ttl)
        end

        private

        def namespaced(key) = "#{SESSION_PREFIX}:#{key}"
      end

      # Every service is optional; nil hides the commands that need it, and a nil
      # +operator_flow+ makes the whole console inert.
      #
      # @param auth [AuthCommand, nil] where a presented token is redeemed. The
      #   same instance the request lane holds, so a token reads the same way
      #   whichever surface a DM lands on.
      def initialize(operator_flow:, reach: nil, request_lane: nil, lifecycle: nil, mapper: nil,
                     web_login: nil, dashboard_url: nil, feature_controls: nil, analytics: nil,
                     vindication: nil, proposals: nil, sessions: MemorySessions.new, viewers: Security::DashboardViewers.default,
                     administrators: Security::DashboardAdministrators.default,
                     community_viewers: nil, auth: nil, undelivered: nil, adapters: {}, logger: nil)
        @operator_flow = operator_flow
        @undelivered = undelivered
        @adapters = adapters
        @reach = reach || (operator_flow && AdminReach.new(operator_flow: operator_flow, logger: logger))
        @request_lane = request_lane
        @lifecycle = lifecycle
        @mapper = mapper
        @web_login = web_login
        @dashboard_url = dashboard_url
        @feature_controls = feature_controls
        @analytics = analytics
        @vindication = vindication
        @proposals = proposals
        @sessions = sessions
        @viewers = viewers
        @administrators = administrators
        @community_viewers = community_viewers
        @auth = auth
        @logger = logger
      end

      # Handle a DM to the bot, returning the reply text or nil to stay silent;
      # a non-operator DM falls through to the request lane. The sender is
      # resolved once per DM, and that list's order is what a numbered pick reads against.
      #
      # @param quoted [String, nil] the text of the message this DM replied to,
      #   where the platform carries one. `vindicate` reads the code out of it,
      #   so replying to an alert is enough and nothing has to be typed twice.
      # @return [String, nil]
      def handle_dm(adapter:, account:, author:, text:, quoted: nil, subject: nil)
        # Before the operator gate: reporting is for everybody, and a reporter
        # has no membership to resolve a community from. This lane is the one a
        # control plane wires, so leaving it out gated the feature by accident.
        report = report_dm(adapter, account, author, text, subject)
        return report unless report.nil?

        return nil if @operator_flow.nil?
        return fallback(adapter, account, author, text) if author.nil? || author.native_id.nil?

        # Before anything is read. A bot cannot open a conversation on some
        # platforms, so this DM may be the first chance to hand over a notice
        # written while they were unreachable. It goes out whatever they said
        # and whatever this lane answers back, including nothing.
        flush_undelivered(adapter, account, author)
        memberships = operated_communities(adapter, author)
        # A viewer who operates nothing still reaches the console, so `web-login`
        # can mint them the read-only dashboard link their status entitles them
        # to. Every community-scoped command here holds or answers "none" for
        # them, since the viewer dimension grants no write anywhere.
        if memberships.empty? && !viewer?(adapter, author) && !administrator?(adapter, author) &&
           viewed_community_ids(adapter, author).empty?
          return fallback(adapter, account, author, text)
        end

        respond(adapter, account, author, memberships, text.to_s, quoted)
      rescue StandardError => e
        @logger&.warn { "operator console: could not handle a DM: #{e.class}: #{e.message}" }
        nil
      end

      private

      def fallback(adapter, account, author, text)
        @request_lane&.handle_dm(adapter: adapter, account: account, author: author, text: text)
      end

      # Handed straight to the request lane, which is where the report store
      # lives. Nil wherever that lane cannot take one, which is every
      # deployment without a control plane and every DM that is not a report.
      def report_dm(adapter, account, author, text, subject)
        return nil unless @request_lane.respond_to?(:report_dm)

        @request_lane.report_dm(adapter: adapter, account: account, author: author,
                                text: text, subject: subject)
      end

      # The {AdminReach::Membership}s this sender holds, in slug order.
      def operated_communities(adapter, author)
        @reach.operated(adapter: adapter, native_id: author.native_id, username: author.username)
      end

      def respond(adapter, account, author, memberships, text, quoted = nil)
        key = session_key(adapter, account, author)
        session = @sessions.read(key)

        reply = route(adapter, account, author, memberships, text, session, quoted)
        @sessions.write(key, session)
        reply
      end

      # One DM, in precedence order: an open wizard captures the reply (`cancel`
      # always exits), then an answer to a held "which community?", then a command.
      def route(adapter, account, author, memberships, text, session, quoted = nil)
        return continue_wizard(session, memberships, text) if in_wizard?(session, text)

        held = held_command(adapter, account, author, memberships, session, text)
        return held if held

        run(adapter, account, author, memberships, text, session, quoted)
      end

      def in_wizard?(session, text)
        return false unless session["wizard"]

        command, = parse(text)
        command != "cancel"
      end

      # Dispatch one command. A word the client reserves is answered as the
      # member's own gesture first. An `@<slug>` override picks the community
      # for this command only; a community-scoped command with none resolved
      # is held.
      def run(adapter, account, author, memberships, text, session, quoted = nil)
        command, args = parse(text)
        override, args = extract_override(args)
        return reserved_reply(command, memberships) if reserved?(command, override)

        unless override.nil?
          current = find_membership(memberships, override)
          return unknown_community(override) if current.nil?
        end
        current ||= current_membership(memberships, session)

        # A role ask from somebody who operates nothing has no community to be
        # parked against, so it is answered from what they already read instead
        # of asking a question with no answers in it.
        scoped = community_scoped?(command, args) && !(role?(command) && memberships.empty?)
        current ||= inferred_membership(command, args, memberships, quoted) if scoped
        return ask_which_community(memberships, session, text) if scoped && current.nil?

        session.delete("held")
        dispatch(command, args, memberships: memberships, current: current, session: session,
                 author: author, adapter: adapter, account: account, quoted: quoted)
      end

      # Parse a console line into [command, args]. A bare line, or one that is
      # only a prefix, is treated as `help`; a leading command marker is optional.
      def parse(text)
        body = text.strip.sub(%r{\A[/!]}, "").strip
        return ["help", []] if body.empty?

        words = body.split(/\s+/)
        # Telegram appends "@botname" to a command picked from its menu.
        head = words.first.to_s.split("@").first.to_s.downcase
        [head, words[1..] || []]
      end

      def dispatch(command, args, memberships:, current:, session:, author:, adapter:, account:, quoted: nil)
        case command
        when "help", "?", "commands" then help(memberships)
        when "whoami", "who" then whoami(memberships)
        when "communities", "list", "ls" then list_communities(memberships)
        when "use", "community", "switch" then use_community(args, memberships, session)
        when "status" then status(current)
        when "config", "feature", "features" then configure(args, current)
        when "analytics", "stats" then analytics_report(args, current)
        when "requests", "pending" then list_requests(current)
        when "approve" then approve(args, current, adapter, author, quoted)
        when "deny", "reject" then reject(args, current, adapter, author, quoted)
        when "resume", "start" then lifecycle_change(current, start: true)
        when "suspend", "stop" then lifecycle_change(current, start: false)
        when "map" then start_map_wizard(current, session)
        when "cancel", "abort" then cancel_wizard(session)
        when "web-login", "weblogin" then web_login(memberships, author, adapter, account)
        when "vindicate", "innocent" then vindicate(args, current, adapter, author, quoted)
        when "role", "roles" then ask_for_role(args, current, adapter, author)
        when "auth" then redeem_token(args, adapter, account, author)
        else unknown(command)
        end
      end

      # Hand over what was written while this member could not be reached,
      # oldest first. Each is stamped only once it has actually gone out, so a
      # refusal leaves it for the next time they write in rather than losing it.
      def flush_undelivered(adapter, account, author)
        return if @undelivered.nil?

        owed = @undelivered.pending_for(adapter: adapter, account: account, native_id: author.native_id)
        return if owed.empty?

        sender = @adapters[[adapter.to_s.to_sym, account.to_s]]
        return unless sender.respond_to?(:supports_admin_dm?) && sender.supports_admin_dm?

        owed.each do |row|
          @undelivered.delivered!(row) if sender.send_admin_dm(author.native_id, row.body)
        end
      rescue StandardError => e
        @logger&.warn { "operator console: could not hand over a kept DM: #{e.class}: #{e.message}" }
      end

      def help(memberships)
        lines = [
          "Operator console. Commands:",
          "  help                 this list",
          "  whoami               your operator identity",
          "  communities          the communities you run",
          "  use <slug>           work in a community",
          "  status               the current community's state",
          "  requests             open operator requests here",
          "  approve <id>         approve a request",
          "  deny <id>            deny a request",
          "  role <name>          ask for a role: operator, viewer"
        ]
        lines << "  auth <token>         redeem a token somebody handed you" if auth?
        lines << "  vindicate <code> <why>  reverse a content policy action, and say so" if vindication?
        if feature_controls?
          lines << "  config               every feature and whether it is on"
          lines << "  config <feature>     one feature's settings, every scope"
          lines << "  config <feature> on|off [in <room>]     turn it on or off"
          lines << "  config <feature> set <key> <value> [in <room>]  set a config key"
        end
        if analytics?
          windows = Analytics::WINDOWS.keys.join("|")
          lines << "  analytics [#{windows}]  the community's numbers (default #{Analytics::DEFAULT_WINDOW})"
        end
        if lifecycle?
          lines << "  resume               start the bot in the current community"
          lines << "  suspend              stop the bot in the current community"
        end
        lines << "  map                  map channels into rooms" if mapper?
        lines << "  web-login            get a one-time dashboard sign-in link" if web_login?
        lines << ""
        lines << "Add `@<slug>` to any command to run it in that community once, " \
                 "without changing which one you are working in."
        lines << selection_hint(memberships)
        lines.join("\n")
      end

      def whoami(memberships)
        name = operator_name(memberships)
        slugs = memberships.map(&:slug)
        return "You are #{name}. You operate no communities." if slugs.empty?

        "You are #{name}, operator of: #{slugs.join(", ")}."
      end

      def list_communities(memberships)
        rows = memberships.map do |membership|
          "  #{membership.community.slug}  (#{membership.community.name})  #{run_state(membership.community)}"
        end
        return "You operate no communities." if rows.empty?

        "Communities you run:\n#{rows.join("\n")}"
      end

      # Move the session's focus. Takes a slug or a position in the last list shown.
      def use_community(args, memberships, session)
        slug = args.first
        return "Which community? Try: use <slug>, or `communities` for the list." if slug.nil?

        match = if slug.to_s.match?(/\A\d+\z/)
                  index = slug.to_i
                  index.between?(1, memberships.size) ? memberships[index - 1] : nil
                else
                  find_membership(memberships, slug)
                end
        return unknown_community(slug) if match.nil?

        session["community_id"] = match.community.id
        "Now working in #{match.label}."
      end

      # The community's state, counted the way the dashboard's overview page does.
      # Every count carries community_id.
      def status(current)
        community = current.community
        open = @operator_flow.pending(community_id: community.id).size
        models = @operator_flow.models
        lines = [
          "#{current.label} is #{run_state(community)}. " \
            "#{open} open operator request#{open == 1 ? "" : "s"}."
        ]
        lines << "  platforms:        #{models.platform_connection.where(community_id: community.id).count}"
        lines << "  channels:         #{models.channel.where(community_id: community.id).count}"
        lines << "  operators:        #{models.operator.where(community_id: community.id).count}"
        lines << "  feature settings: #{models.feature_setting.where(community_id: community.id).count}"
        lines.join("\n")
      end

      # `config` in all its forms, over {FeatureControls}. A missing `in <room>`
      # means the community-wide default row.
      def configure(args, current)
        return "Feature settings are not available on this deployment." unless feature_controls?

        return list_features(current) if args.first.nil?

        feature = feature_key(args.first)
        rest = args[1..] || []
        verb = rest.first.to_s.downcase
        case verb
        when "" then show_feature(current, feature)
        when "on", "enable" then flip_feature(current, feature, rest[1..], on: true)
        when "off", "disable" then flip_feature(current, feature, rest[1..], on: false)
        when "set" then set_feature(current, feature, rest[1..])
        else "I do not know `config #{feature} #{verb}`. Try on, off or set, or `config #{feature}` to look."
        end
      rescue FeatureControls::Invalid => e
        # Caught here so a typo gets an answer; #handle_dm's rescue is silent.
        "That did not work: #{e.message}"
      end

      # Every feature and what it is doing community-wide, including ones with no
      # row: those run at their code default, off except the always-on bridge.
      def list_features(current)
        configured = @feature_controls.list(current.community, selector: COMMUNITY_SCOPE)
                                      .each_with_object({}) { |entry, memo| memo[entry[:feature]] = entry }
        lines = ["Features in #{current.label}, community-wide:"]
        Features::Catalog.names.each do |feature|
          entry = configured[feature]
          if always_on?(feature)
            lines << "  #{on_off(true)}  #{feature}  (always on)"
          else
            enabled = entry ? entry[:enabled] : feature == "bridge"
            lines << "  #{on_off(enabled)}  #{feature}#{entry ? "" : "  (default)"}"
          end
        end
        lines << ""
        lines << "`config <feature>` for one feature's rooms and config."
        lines.join("\n")
      end

      # One feature across every scope it is set at, community default first.
      def show_feature(current, name)
        unless Features::Catalog.known?(name)
          return "There is no feature called #{name.inspect}. Known: #{Features::Catalog.names.join(", ")}."
        end

        rows = @feature_controls.list(current.community).select { |entry| entry[:feature] == name }
        return default_feature_notice(name, current) if rows.empty?

        lines = ["#{name} in #{current.label}:"]
        rows.sort_by { |row| row[:scope] == :community ? "" : row[:room_key].to_s }.each do |row|
          lines << "  #{on_off(row[:enabled])}  #{scope_label(row)}"
          row[:config].each { |key, value| lines << "      #{key} = #{render_value(value)}" }
        end
        lines.join("\n")
      end

      def default_feature_notice(name, current)
        return "#{name} runs unconditionally in #{current.label} and has no toggle." if always_on?(name)

        state = name == "bridge" ? "on" : "off"
        "#{name} has no settings in #{current.label}, so it runs at its default: #{state}."
      end

      # identify_topic and disabled_command_notice ignore feature_settings
      # entirely, the same reason {ControlPlane::FeatureControls#known!}
      # refuses a write against either one.
      def always_on?(feature)
        Features::Catalog.class_for(feature)&.always_enabled? == true
      end

      def flip_feature(current, feature, args, on:)
        selector, = extract_room(args)
        rows = if on
                 @feature_controls.enable(community: current.community, selector: selector, feature: feature)
               else
                 @feature_controls.disable(community: current.community, selector: selector, feature: feature)
               end
        row = rows.first
        "Turned #{row[:feature]} #{on ? "on" : "off"} for #{scope_label(row)} in #{current.label}."
      end

      # Set one key under a feature's config blob. The value is everything after
      # the key, space-joined, so a comma list survives the word split.
      def set_feature(current, feature, args)
        selector, rest = extract_room(args)
        key = rest.first
        return "Which key? Try: config #{feature} set <key> <value>." if key.nil?

        value = (rest[1..] || []).join(" ")
        return "Which value? Try: config #{feature} set #{key} <value>." if value.strip.empty?

        rows = @feature_controls.set(community: current.community, selector: selector,
                                     feature: feature, key: key, value: value)
        row = rows.first
        "Set #{row[:feature]}.#{key} to #{render_value(row[:config][key.to_s])} " \
          "for #{scope_label(row)} in #{current.label}."
      end

      # Pull a trailing `in <room>` clause off a config command, returning
      # [selector, remaining args]. Only the last two words, so a value containing
      # the word "in" is untouched.
      def extract_room(args)
        args = Array(args)
        return [COMMUNITY_SCOPE, args] if args.length < 2
        return [COMMUNITY_SCOPE, args] unless args[-2].to_s.casecmp?("in")

        [args[-1].to_s, args[0...-2]]
      end

      # Feature keys are underscored, so a typed hyphen reads as the same word.
      def feature_key(word)
        word.to_s.strip.downcase.tr("-", "_")
      end

      def scope_label(row)
        row[:scope] == :community ? "community-wide" : "room #{row[:room_key]}"
      end

      # Padded to a fixed width so the feature list reads as two columns.
      def on_off(enabled) = enabled ? "on " : "off"

      # A list or hash goes back as JSON so it round-trips through `config ... set`.
      def render_value(value)
        case value
        when nil then "(unset)"
        when Array, Hash then JSON.generate(value)
        else value.to_s
        end
      end

      # The community's numbers from {Analytics#overview}, same call and window
      # normalisation as the dashboard's analytics route.
      def analytics_report(args, current)
        return "Analytics are not available on this deployment." unless analytics?

        window = Analytics.window_key(args.first)
        report = @analytics.overview(community: current.community, window: window)
        render_analytics(report, current, window)
      end

      def render_analytics(report, current, window)
        lines = ["#{current.label}, last #{window}:"]
        lines.concat(analytics_lines(report))
        if derived_window_capped?(window)
          lines << ""
          lines << "Message and reaction volume only ever look back " \
                   "#{Analytics::RETENTION_SECONDS / 3600}h, whatever window you pick."
        end
        lines.join("\n")
      end

      # One line per panel the dashboard renders, in its order. A panel whose table
      # is absent reports itself unavailable instead of reporting a zero.
      def analytics_lines(report)
        [
          panel_line("members", report[:members]) do |m|
            "#{m[:total]} known, #{m[:active]} active, #{m[:new_in_window]} new"
          end,
          panel_line("messages", report[:messages]) { |m| "#{m[:total]} relayed (last #{m[:retention_hours]}h)" },
          panel_line("moderation", report[:moderation]) { |m| "#{m[:total]} actions" },
          panel_line("reactions", report[:reactions]) { |r| "#{r[:total]} (last #{r[:retention_hours]}h)" },
          panel_line("guests", report[:guests]) { |g| "#{g[:active]} active, #{g[:issued_in_window]} issued" },
          panel_line("warnings", report[:warnings]) { |w| "#{w[:total]} issued, #{w[:active]} active" },
          panel_line("sanctions", report[:sanctions]) { |s| "#{s[:active]} active" },
          panel_line("events", report[:events]) { |e| "#{e[:created]} created, #{e[:upcoming]} upcoming" },
          panel_line("onboarding", report[:onboarding]) { |o| "#{o[:pending]} spaces pending" },
          panel_line("requests", report[:operator_requests]) { |o| "#{o[:pending]} pending, #{o[:decided]} decided" }
        ]
      end

      # {Analytics} flags a missing table with available:false, and an always-present
      # panel carries no such key, so only an explicit false counts.
      def panel_line(label, panel)
        return "  #{label.ljust(12)} not recorded on this deployment" if panel.nil? || panel[:available] == false

        "  #{label.ljust(12)} #{yield(panel)}"
      end

      # Whether the window is wider than the derived tables can answer, so the
      # reply owes a note that the volume panels stop short.
      def derived_window_capped?(window)
        Analytics::WINDOWS.fetch(window, 0) > Analytics::RETENTION_SECONDS
      end

      def list_requests(current)
        pending = @operator_flow.pending(community_id: current.community.id)
        return "No open operator requests in #{current.label}." if pending.empty?

        lines = pending.map { |request| "  ##{request.id}  #{requester_label(request)}" }
        "Open operator requests in #{current.label}:\n#{lines.join("\n")}\n" \
          "Approve with `approve <id>`, deny with `deny <id>`."
      end

      # Two things answer to approve and reject: an operator request, named by
      # its numeric id, and a topic move proposal, named by the same shape of
      # code the alerts carry. Nothing has to be renamed, because the two can
      # never be confused: a request id is digits and a code never is.
      def approve(args, current, adapter, author, quoted = nil)
        code = proposal_code(args, quoted)
        return decide(args, current, grant: true) if code.nil?

        settle(code, current, adapter, author, approve: true, reason: args[1..].to_a.join(" "))
      end

      def reject(args, current, adapter, author, quoted = nil)
        code = proposal_code(args, quoted)
        return decide(args, current, grant: false) if code.nil?

        settle(code, current, adapter, author, approve: false, reason: args[1..].to_a.join(" "))
      end

      # A code typed on the line, or the one carried by the proposal this DM
      # replied to. Nil means the words were about an operator request, which
      # is what the older reading of these verbs is for.
      def proposal_code(args, quoted)
        return nil unless proposals?

        typed = presence(args.first)
        return typed.downcase.delete_prefix("#") if typed && code_like?(typed)
        return nil if typed&.match?(/\A\d+\z/)

        code_in(quoted, PROPOSAL_VERBS)
      end

      def settle(code, current, adapter, author, approve:, reason:)
        outcome = @proposals.settle(
          community: current.community, code: code, operator: acting_label(adapter, author),
          approve: approve, reason: reason
        )
        proposal_reply(outcome, code, current, approve: approve)
      end

      def proposal_reply(outcome, code, current, approve:)
        case outcome.status
        when :unknown then "No move proposal #{code} in #{current.label}. #{open_proposals(current)}"
        when :settled then "#{code} in #{current.label} was already answered (#{outcome.state})."
        when :lapsed then "#{code} in #{current.label} went unanswered too long and has lapsed."
        else settled_reply(outcome, code, current, approve: approve)
        end
      end

      def settled_reply(outcome, code, current, approve:)
        who = presence(outcome.author) || "somebody"
        where = "#{outcome.from_room} to #{outcome.to_room}"
        return "Rejected #{code} in #{current.label}: #{who}'s message stays in #{outcome.from_room}." unless approve

        moved = outcome.moved ? "moving it now" : "but the move could not be started"
        "Approved #{code} in #{current.label}: #{who}'s message, #{where}, #{moved}."
      end

      # Listed rather than left as a dead end, the same way a bare vindicate is.
      def open_proposals(current)
        rows = @proposals.pending(community_id: current.community.id)
        return "Nothing is waiting on an answer here." if rows.empty?

        (["Waiting on an answer:"] + rows.map do |row|
          "  #{row.code}  #{row.from_room} to #{row.to_room}, #{presence(row.author_name) || "somebody"}"
        end).join("\n")
      end

      def proposals? = !@proposals.nil?

      def decide(args, current, grant:)
        community = current.community
        id = args.first
        return "Which request? Try: #{grant ? "approve" : "deny"} <id>." unless id.to_s.match?(/\A\d+\z/)

        request = @operator_flow.find_request(community_id: community.id, id: id)
        return "No request ##{id} in #{current.label}." if request.nil?
        return "Request ##{id} in #{current.label} is not open (it is #{request.state})." unless request.state == "pending"

        result = grant ? @operator_flow.approve(request: request, approver: current.operator)
                       : @operator_flow.deny(request: request, approver: current.operator)
        acknowledge(result, request, grant: grant, current: current)
      end

      def acknowledge(result, request, grant:, current:)
        case result.status
        when :approved
          "Approved ##{request.id} in #{current.label}: " \
            "#{requester_label(request)} is now an operator of #{current.community.slug}."
        when :denied
          "Denied ##{request.id} in #{current.label}, from #{requester_label(request)}."
        when :forbidden
          "You are not allowed to #{grant ? "approve" : "deny"} requests in #{current.label}."
        else
          "Could not #{grant ? "approve" : "deny"} ##{request.id} in #{current.label} (#{result.status})."
        end
      end

      # `vindicate <code> <why>`: the answer to a content policy alert, which
      # carries the code in its own text. Everything after the code is the
      # operator's own words, shown to the author verbatim, so it is taken
      # whole rather than parsed.
      def vindicate(args, current, adapter, author, quoted = nil)
        return "Reversing a content policy action is not available here." unless vindication?

        code, statement = vindicate_target(args, quoted)
        return no_code_reply(current) if code.nil?

        outcome = @vindication.vindicate(
          community: current.community, code: code, operator: acting_label(adapter, author),
          statement: statement
        )
        vindication_reply(outcome, code, current)
      end

      # Where the code comes from, in the order an operator would expect. A code
      # typed on the line wins; otherwise the alert this DM replied to is read
      # for the one it advertised, which is what makes a bare `/vindicate` in
      # reply to an alert do the obvious thing.
      def vindicate_target(args, quoted)
        typed = presence(args.first)
        return [typed, args[1..].to_a.join(" ")] if typed && code_like?(typed)

        quoted_code = code_in(quoted, VINDICATION_VERBS)
        return [quoted_code, args.join(" ")] if quoted_code

        # A first word that is not a code, with no alert behind it, is still the
        # operator's own words rather than a mistyped handle.
        [typed, args[1..].to_a.join(" ")]
      end

      # Every alert advertises the verb its code is answered with, and that verb
      # is what tells a code apart from a word of the operator's own that
      # happens to fit. Only the asking alert's own verbs are read, so replying
      # to the wrong one asks which code rather than searching the wrong table.
      def code_in(quoted, verbs)
        text = quoted.to_s
        return nil if text.empty?

        match = text.match(/(?:#{verbs})\s+([#{ControlPlane::ContentPolicyActions::CODE_ALPHABET}]{#{ControlPlane::ContentPolicyActions::CODE_LENGTH}})\b/i)
        match && match[1].downcase
      end

      def code_like?(word)
        word.to_s.downcase.delete_prefix("#")
            .match?(/\A[#{ControlPlane::ContentPolicyActions::CODE_ALPHABET}]{#{ControlPlane::ContentPolicyActions::CODE_LENGTH}}\z/)
      end

      # A dead end helped nobody, so the answer is the list of what could be
      # reversed, with the code beside each.
      def no_code_reply(current)
        rows = @vindication.recent(community_id: current.community.id)
        return "Which action? Reply to one of my alerts with `vindicate <why>`, or type " \
               "`vindicate <code> <why>`." if rows.empty?

        lines = ["Which action? Reply to one of my alerts with `vindicate <why>`, or name one of these:"]
        rows.each { |row| lines << "  #{row.code}  #{vindicate_row_label(row)}" }
        lines.join("\n")
      end

      def vindicate_row_label(row)
        who = presence(row.author_name) || "someone"
        "#{row.action} on #{who}, \"#{presence(row.policy) || "a policy"}\""
      end

      def vindication_reply(outcome, code, current)
        case outcome.status
        when :unknown
          "No content policy action #{code} in #{current.label}. A code lapses once its action does."
        # Distinct from :unknown on purpose. A reversal that breaks part way
        # has already taken the code's claim, so telling an operator the code
        # does not exist sends them looking for the wrong thing entirely.
        when :failed
          "Something broke while reversing #{code} in #{current.label}, and the code is spent either way. " \
            "The reason is in the log."
        when :already then "#{code} in #{current.label} has already been reversed."
        else vindicated_reply(outcome, code, current)
        end
      end

      # Says what actually landed, since every step of a reversal is best
      # effort: an operator who reads that the author could not be told knows
      # to go and tell them.
      def vindicated_reply(outcome, code, current)
        who = presence(outcome.author) || "the author"
        policy = presence(outcome.policy) || "a community policy"
        parts = ["Reversed #{code} in #{current.label}: #{who} was moderated for \"#{policy}\"."]
        if outcome.silent
          parts << "Nothing had been placed on the message, so there was nothing to undo."
        else
          parts << restoration_line(outcome)
          parts << (outcome.told_author ? "They have been told." : "They could not be told.")
        end
        parts.join(" ")
      end

      # A flag never took the message down, so a reversal of one has nothing to
      # put back and no failure to report either. Saying otherwise read as an
      # error against an action that had worked exactly as configured.
      def restoration_line(outcome)
        return "The mark is off it, and the message itself was never taken down." unless outcome.removed

        outcome.restored ? "Their message is back in the room." : "Their message could not be put back."
      end

      # How the operator is named in the audit trail and on the reversed row.
      def acting_label(adapter, author)
        handle = presence(author.username) || presence(author.native_id) || "unknown"
        "#{adapter}:#{handle}"
      end

      # A word the client owns, with no `@<slug>` alongside it to say the
      # lifecycle verb was the one meant.
      def reserved?(command, override) = RESERVED_WORDS.include?(command) && override.nil?

      def reserved_reply(command, memberships)
        command == "start" ? welcome(memberships) : quiet_reply
      end

      # What pressing Start should get: what the bot is, and where the help is.
      # An operator is told this chat is their console, since being told to open
      # it is why most of them are here; anybody else is told only that it is
      # where the bot reaches them, so a welcome never implies a standing they
      # do not hold.
      def welcome(memberships)
        ["Hello, and welcome. #{ControlLane::DESCRIPTION}", "", welcome_standing(memberships)].join("\n")
      end

      def welcome_standing(memberships)
        return "This is where I reach you privately. Type `help` to see what you can do here." if memberships.empty?

        "You operate #{memberships.map(&:slug).join(", ")}, so this chat is also your console: " \
          "it is where operator notices reach you, and where you can run things. " \
          "Type `help` for the list."
      end

      # `stop` on its own, answered as the leave-me-alone word the client means
      # by it. The lifecycle verb is named only where there is one to name.
      def quiet_reply
        return ControlLane::QUIET_NOTICE unless lifecycle?

        "#{ControlLane::QUIET_NOTICE} To take a community offline, use `suspend @<slug>`."
      end

      def lifecycle_change(current, start:)
        return "Resume and suspend are not available on this deployment." unless lifecycle?

        # Act on a fresh row: the session-held Snapshot community is a projection.
        row = @lifecycle.find_by_slug(current.community.slug)
        return "Could not find #{current.label} to change." if row.nil?

        result = start ? @lifecycle.start(community: row) : @lifecycle.stop(community: row)
        describe_lifecycle(result, current.label, start: start)
      end

      def describe_lifecycle(result, label, start:)
        case result.status
        when :started then "Started the bot in #{label}."
        when :stopped then "Stopped the bot in #{label}. It stays in the space but goes quiet."
        when :already_active then "#{label} is already running."
        when :already_suspended then "#{label} is already stopped."
        else "Could not #{start ? "start" : "stop"} #{label} (#{result.status})."
        end
      end

      def unknown(command)
        "Unknown command #{command.inspect}. Type `help` for the list."
      end

      # Mint a short-lived dashboard sign-in link for the DM sender, scoped to the
      # same +memberships+ list, so a token never grants more than the DM proved.
      # The viewer and administrator dimensions ride along on the same token when
      # the rosters name this handle, so one link carries the whole standing.
      def web_login(memberships, author, adapter, account)
        return "Web sign-in is not available on this deployment." if @web_login.nil?

        communities = memberships.map do |membership|
          { id: membership.community.id, slug: membership.community.slug, name: membership.community.name }
        end
        viewer = viewer?(adapter, author)
        administrator = administrator?(adapter, author)
        # The communities they read without operating them, minus the ones they
        # do: an operator already reads those, and saying it twice would read as
        # two different grants.
        viewed = viewed_community_ids(adapter, author) - memberships.map { |m| m.community.id }
        operator = {
          adapter: adapter.to_s, account: account.to_s, native_id: author.native_id.to_s,
          # The handle the rosters are keyed on, so the dashboard can ask them
          # again when the link is redeemed rather than trust what it carries.
          username: presence(author.username),
          label: operator_name(memberships, administrator: administrator)
        }
        outcome = @web_login.issue(
          identity_key: "#{adapter}:#{account}:#{author.native_id}", operator: operator,
          communities: communities, viewer: viewer, viewer_communities: viewed,
          administrator: administrator
        )
        case outcome.status
        when :issued
          "Sign in to the dashboard: #{login_url(outcome.token)}\n" \
            "This link is valid for about #{minutes_until(outcome.expires_at)}, use it as many times as " \
            "you need to. #{login_grant(memberships, viewer, viewed, administrator)}"
        when :rate_limited
          "You already have an active sign-in link outstanding. Use it, or wait for it to expire " \
            "(about an hour) and ask again."
        else
          "Could not create a sign-in link right now."
        end
      end

      # What the link just handed over, in one sentence: the communities it can
      # change things in, whether it also reads the whole deployment, and any
      # community it reads without operating. Administrator is said first and
      # alone, since it already covers everything the rest of it would list.
      def login_grant(memberships, viewer, viewed = [], administrator = false)
        slugs = memberships.map(&:slug)
        reads = viewed_slugs(viewed)
        if administrator
          return "It signs you in as an administrator, which is every community and every setting on " \
                 "this deployment. It is a short link on purpose, so use it now."
        end
        return deployment_viewer_grant(slugs) if viewer
        return community_viewer_grant(slugs, reads) unless reads.nil?
        return "It signs you in, though there is nothing on it to read or change." if slugs.empty?

        "It signs you in to: #{slugs.join(", ")}."
      end

      def deployment_viewer_grant(slugs)
        return "It signs you in as a viewer: you can read every community and change nothing." if slugs.empty?

        "It signs you in as a viewer of every community, and lets you change things in: #{slugs.join(", ")}."
      end

      def community_viewer_grant(slugs, reads)
        return "It signs you in to read #{reads}, and change nothing there." if slugs.empty?

        "It signs you in to read #{reads}, and to change things in: #{slugs.join(", ")}."
      end

      # The slugs behind a list of community ids, or nil when there are none.
      def viewed_slugs(ids)
        return nil if ids.empty?

        slugs = ids.filter_map { |id| @operator_flow.models.community[id]&.slug }
        slugs.empty? ? nil : slugs.join(", ")
      end

      # `auth <token>`: present a token and be granted what it carries. Not
      # scoped to a community, because the token names its own.
      def redeem_token(args, adapter, account, author)
        return "Redeeming a token is not available on this deployment." unless auth?

        @auth.redeem(adapter: adapter, account: account, author: author, token: args.first)
      end

      # `role <name>`: one verb for asking about a role, with the role as its
      # argument, so a role added later mints no new command word.
      def ask_for_role(args, current, adapter, author)
        case args.first.to_s.downcase
        when "operator" then ask_for_operator(current, adapter, author)
        when "viewer" then ask_for_viewer(current, adapter, author)
        else role_help
        end
      end

      def role_help
        [
          "Which role? Two of them:",
          "  role operator        change things in a community",
          "  role viewer          read one community and change nothing in it",
          "",
          "Reading EVERY community is a separate, deployment-wide role an administrator hands out, " \
            "and it is not something to ask for here."
        ].join("\n")
      end

      def role?(command) = %w[role roles].include?(command)

      def ask_for_operator(current, adapter, author)
        return "There is no community here for you to ask to operate." if current.nil?

        result = @operator_flow.request(
          community_id: current.community.id, adapter: adapter, native_id: author&.native_id,
          username: author&.username, display: author&.any_name
        )
        case result.status
        when :created then "Filed. An operator of #{current.label} will review it."
        when :duplicate then "You already have a pending operator request in #{current.label}."
        when :already_operator then "You are already an operator of #{current.label}."
        else "I could not file that request right now."
        end
      end

      # Ask to read one community and change nothing in it. An operator of that
      # community already reads it, so there is nothing there to ask for.
      def ask_for_viewer(current, adapter, author)
        return "Viewer requests are not available on this deployment." if @community_viewers.nil?
        return viewer_standing(adapter, author) if current.nil?
        return "You already operate #{current.label}, so you already read it." if current.operator

        result = @community_viewers.request(
          community_id: current.community.id, adapter: adapter, native_id: author&.native_id,
          username: author&.username, display: author&.any_name
        )
        case result.status
        when :created
          "Filed. An operator of #{current.label} will decide whether you read it. " \
            "It changes nothing there, in chat or in the dashboard."
        when :duplicate then "You already have a pending viewer request in #{current.label}."
        when :already_viewer then "You already read #{current.label}."
        else "I could not file that request right now."
        end
      end

      # What somebody who operates nothing already reads, since there is no
      # community in focus for them to ask about.
      def viewer_standing(adapter, author)
        return "You already read every community, and change nothing anywhere." if viewer?(adapter, author)

        slugs = viewed_slugs(viewed_community_ids(adapter, author))
        return "You already read #{slugs}, and change nothing there." if slugs

        "There is no community here for you to ask to read."
      end

      # Whether this sender holds the deployment-wide viewer dimension. Matched
      # on the stable handle, never the display name, which anyone can set to
      # anything.
      def viewer?(adapter, author)
        return false if author.nil?

        @viewers&.viewer?(adapter: adapter, username: author.username, native_id: author.native_id) || false
      end

      # Whether this sender administers the deployment. Matched on the same
      # stable handle, since administrator is the largest thing here to get wrong.
      def administrator?(adapter, author)
        return false if author.nil?

        @administrators&.administrator?(adapter: adapter, username: author.username,
                                        native_id: author.native_id) || false
      end

      # The communities this sender reads without operating them.
      def viewed_community_ids(adapter, author)
        return [] if author.nil? || @community_viewers.nil?

        @community_viewers.communities_for(
          adapter: adapter, username: author.username, native_id: author.native_id
        )
      end

      def login_url(token)
        base = presence(@dashboard_url).to_s.sub(%r{/+\z}, "")
        "#{base}/operator-login?token=#{token}"
      end

      def minutes_until(time)
        minutes = ((time - Time.now) / 60.0).round
        minutes = 1 if minutes < 1
        "#{minutes} minute#{minutes == 1 ? "" : "s"}"
      end

      # Show unmapped channels as one numbered list per platform and wait for a
      # reply of pairs, or single numbers for channels that get their own room.
      def start_map_wizard(current, session)
        return "Channel mapping is not available on this deployment." unless mapper?

        community = current.community
        unmapped = @mapper.unmapped_by_platform(community)
        platforms = unmapped.keys
        return "Every channel in #{current.label} is already mapped." if platforms.empty?

        lists = platforms.to_h { |platform| [platform, unmapped[platform].map { |c| c[:endpoint_key] }] }
        session["wizard"] = "map"
        session["map_community_id"] = community.id
        session["map_platforms"] = platforms
        session["map_lists"] = lists
        render_map_prompt(community, platforms, unmapped)
      end

      # Consume the numbered reply, map each selection into a room, end the wizard.
      def continue_wizard(session, memberships, text)
        return finish_map_wizard(session, memberships, text) if session["wizard"] == "map"

        # An unknown wizard state is stale; clear it and fall back to help.
        clear_wizard(session)
        "That step expired. Type `help` for the list."
      end

      # Maps into the community `map` was STARTED in, read back from the session,
      # never the one in focus when the reply lands. Re-resolving it against the
      # memberships re-authorizes, so an operator who lost it maps nothing.
      def finish_map_wizard(session, memberships, text)
        platforms = session["map_platforms"]
        lists = session["map_lists"]
        current = memberships.find { |membership| membership.community.id == session["map_community_id"] }
        clear_wizard(session)
        return "That mapping is no longer yours to make. Type `map` again to start over." if current.nil?

        selections = parse_selections(text)
        # One platform means no second list to pair against, so every number is
        # its own single-channel room.
        selections = selections.flatten.map { |number| [number] } if platforms.size < 2
        return "I did not read any channel numbers. #{retry_hint(platforms)}" if selections.empty?

        outcomes = selections.map { |numbers| apply_selection(current.community, platforms, lists, numbers) }
        summarise(outcomes, current.label)
      end

      # Returns :pair / :solo on success or an error string.
      def apply_selection(community, platforms, lists, numbers)
        return apply_solo(community, platforms, lists, numbers[0]) if platforms.size < 2 || numbers.size < 2

        apply_pair(community, platforms, lists, numbers[0], numbers[1])
      end

      # Map one (first-platform index, second-platform index) pair, returning :pair
      # or an error string. The range check is about the wizard's numbered lists.
      def apply_pair(community, platforms, lists, a, b)
        first_key = lists.dig(platforms[0], a - 1)
        second_key = lists.dig(platforms[1], b - 1)
        if first_key.nil? || second_key.nil?
          return "Pair #{a} #{b}: out of range."
        end

        @mapper.resolve_selection(community: community, channel: first_key, partner: second_key)
        :pair
      rescue StandardError => e
        "Pair #{a} #{b}: #{e.message}"
      end

      # Map one first-platform channel into a room of its own; another platform's
      # channel can join that room later. Returns :solo or an error string.
      def apply_solo(community, platforms, lists, index)
        key = lists.dig(platforms[0], index - 1)
        return "Channel #{index}: out of range." if key.nil?

        @mapper.resolve_selection(community: community, channel: key, solo: true)
        :solo
      rescue StandardError => e
        "Channel #{index}: #{e.message}"
      end

      def summarise(outcomes, label)
        pairs = outcomes.count { |outcome| outcome == :pair }
        solos = outcomes.count { |outcome| outcome == :solo }
        errors = outcomes.grep(String)
        parts = []
        parts << "#{pairs} pair#{pairs == 1 ? "" : "s"}" if pairs.positive?
        parts << "#{solos} single channel#{solos == 1 ? "" : "s"}" if solos.positive?
        parts << "nothing" if parts.empty?
        summary = "Mapped #{parts.join(" and ")} into rooms in #{label}."
        errors.empty? ? summary : "#{summary}\n#{errors.join("\n")}"
      end

      def retry_hint(platforms)
        example = platforms.size > 1 ? "`1 2` (a pair) or `1` (its own room)" : "`1`"
        "Try `map` again, then reply like #{example}."
      end

      def cancel_wizard(session)
        return "Nothing to cancel." unless session["wizard"]

        clear_wizard(session)
        "Cancelled."
      end

      def clear_wizard(session)
        session.delete("wizard")
        session.delete("map_community_id")
        session.delete("map_platforms")
        session.delete("map_lists")
      end

      def render_map_prompt(community, platforms, unmapped)
        lines = ["Unmapped channels in #{community.slug}:"]
        platforms.each do |platform|
          lines << "#{platform}:"
          unmapped[platform].each_with_index do |channel, index|
            lines << "  #{index + 1}. #{channel[:label]} (#{channel[:route_key]})"
          end
        end
        lines << ""
        lines << map_reply_hint(platforms)
        lines.join("\n")
      end

      # Pairs when two platforms are listed, plain numbers when one is.
      def map_reply_hint(platforms)
        if platforms.size > 1
          "Reply with pairs mapping #{platforms[0]} to #{platforms[1]}, like `1 1` (one per line or comma " \
            "separated), or a single number like `1` to give that #{platforms[0]} channel a room of its own. " \
            "Type `cancel` to stop."
        else
          "Reply with the numbers of the #{platforms[0]} channels to map, like `1` or `1, 2`. Each gets a room " \
            "of its own, which another platform's channel can join later. Type `cancel` to stop."
        end
      end

      # Each comma or newline separated chunk gives its first two integers as a
      # pair, or a single integer as a one-channel selection.
      def parse_selections(text)
        text.to_s.split(/[,\n]+/).filter_map do |chunk|
          numbers = chunk.scan(/\d+/).map(&:to_i)
          numbers.empty? ? nil : numbers.first(2)
        end
      end

      # Whether a command acts on one community, and so may not run without one.
      # A command the deployment does not offer reports itself unavailable
      # instead of first asking where.
      def community_scoped?(command, args = [])
        case command
        when "status", "requests", "pending", "approve", "deny", "reject" then true
        # A code is only unique inside its own community, so guessing which one
        # was meant would reverse a stranger's moderation.
        when "vindicate", "innocent" then vindication?
        # Only once it names a role: `role` on its own is the list of them, and
        # every role there is asked for in one community.
        when "role", "roles" then %w[operator viewer].include?(args.first.to_s.downcase)
        when "resume", "suspend", "start", "stop" then lifecycle?
        when "map" then mapper?
        # Both touch one community's rows, so guessing would silently mis-mutate
        # or leak one community's numbers to an operator who meant another.
        when "config", "feature", "features" then feature_controls?
        when "analytics", "stats" then analytics?
        else false
        end
      end

      # The session's focus when it is still one they operate, else the sole
      # community they operate, else nil. Never falls back to the first one.
      def current_membership(memberships, session)
        selected = session["community_id"]
        if selected
          match = memberships.find { |membership| membership.community.id == selected }
          return match if match
        end
        memberships.size == 1 ? memberships.first : nil
      end

      def find_membership(memberships, slug)
        wanted = slug.to_s.sub(/\A@/, "")
        memberships.find { |membership| membership.community.slug.to_s.casecmp?(wanted) }
      end

      def unknown_community(slug)
        "You do not run a community with slug #{slug.to_s.sub(/\A@/, "").inspect}. " \
          "Type `communities` for the ones you do."
      end

      # Pull a one-off `@<slug>` community override out of a command's
      # arguments, returning [slug, remaining args]. Only the last word counts,
      # which is where the help says to put it: `vindicate` carries free prose
      # an operator writes for somebody else to read, and a handle they mention
      # part way through it is their own words rather than a community.
      def extract_override(args)
        last = args.last.to_s
        return [nil, args] unless last.start_with?("@") && last.length > 1

        [last.sub(/\A@/, ""), args[0...-1]]
      end

      # A reply to one of rubotty's own alerts already says which community it
      # is about, so asking is a question the message answered before it was
      # sent. The code decides it and not the name the alert opens with: a
      # code resolving in exactly one of this operator's communities can only
      # have come from that one, while a name is prose and a collision across
      # two of them would reverse the wrong action.
      def inferred_membership(command, args, memberships, quoted)
        return nil if memberships.size < 2

        membership_for_code(command, args, memberships, quoted) || named_membership(memberships, quoted)
      end

      def membership_for_code(command, args, memberships, quoted)
        code = answering_code(command, args, quoted)
        return nil if code.nil?

        found = memberships.select { |membership| holds_code?(command, membership, code) }
        found.size == 1 ? found.first : nil
      end

      # Every alert opens with the community it is about, so a reply to one
      # that carries no code still says which. Read ONLY the leading name, and
      # only against this operator's own communities: a quoted alert embeds a
      # member's message, and one mentioning another community by name must not
      # get to decide anything. One match resolves, anything else goes on to
      # ask, the same rule the code holds to.
      def named_membership(memberships, quoted)
        opening = quoted.to_s[/\A\s*([^\n:]{1,120}):\s/, 1]
        return nil if opening.nil?

        wanted = opening.strip.downcase
        return nil if wanted.empty?

        found = memberships.select { |membership| names?(membership.community, wanted) }
        found.size == 1 ? found.first : nil
      end

      def names?(community, wanted)
        [community.name, community.slug].any? { |value| value.to_s.strip.downcase == wanted }
      end

      # The code this line is answering, typed or quoted. A code on the line
      # wins, the way it does everywhere else these verbs read one; a run of
      # digits is a request id rather than a code, so it is not read as one.
      def answering_code(command, args, quoted)
        typed = presence(args.first)
        return typed.downcase.delete_prefix("#") if typed && !typed.match?(/\A\d+\z/) && code_like?(typed)

        quoted_code(command, quoted)
      end

      # Read the quoted alert for the code the verb being answered advertises.
      def quoted_code(command, quoted)
        case command
        when "vindicate", "innocent" then code_in(quoted, VINDICATION_VERBS)
        when "approve", "reject" then code_in(quoted, PROPOSAL_VERBS)
        end
      end

      def holds_code?(command, membership, code)
        id = membership.community.id
        case command
        when "vindicate", "innocent"
          !@vindication.nil? && @vindication.holds?(community_id: id, code: code)
        when "approve", "reject"
          proposals? && @proposals.holds?(community_id: id, code: code)
        else false
        end
      rescue StandardError => e
        @logger&.warn { "console: could not look for #{code} in #{membership.community.slug}: #{e.message}" }
        false
      end

      # Refuse to guess: list the communities, hold the command, and ask.
      def ask_which_community(memberships, session, text)
        # Nothing to hold the command for, so it is answered rather than parked.
        return "You operate no communities, so there is nothing to run that in." if memberships.empty?

        session["held"] = text.to_s
        lines = ["You operate #{memberships.size} communities, so I will not guess which one that is about:"]
        memberships.each_with_index do |membership, index|
          lines << "  #{index + 1}. #{membership.community.slug} (#{membership.community.name})"
        end
        lines << ""
        lines << "Reply with a number or a slug to run it there, `use <slug>` to work in one " \
                 "from now on, or add `@<slug>` to the command."
        lines.join("\n")
      end

      # Run the held command in the picked community without moving the focus,
      # which is what `use` is for.
      def held_command(adapter, account, author, memberships, session, text)
        held = presence(session["held"])
        return nil if held.nil?

        token = text.to_s.strip.sub(/\A#/, "")
        return nil unless token.match?(/\A[a-z0-9][a-z0-9_-]*\z/i)

        if token.match?(/\A\d+\z/)
          index = token.to_i
          # A number can only be an answer attempt, so correct it and keep asking.
          unless index.between?(1, memberships.size)
            return "There is no #{index} in that list. Reply with a number from 1 to #{memberships.size}."
          end

          picked = memberships[index - 1]
        else
          picked = find_membership(memberships, token)
        end
        return nil if picked.nil?

        session.delete("held")
        command, args = parse(held)
        _, args = extract_override(args)
        dispatch(command, args, memberships: memberships, current: picked, session: session,
                 author: author, adapter: adapter, account: account)
      end

      def selection_hint(memberships)
        case memberships.size
        when 0 then "You operate no communities, so there is nothing here to work in."
        when 1 then "Working in #{memberships.first.label}."
        else "You run #{memberships.size} communities. Select one with `use <slug>`."
        end
      end

      def run_state(community)
        active_row?(community) ? "running" : "stopped"
      end

      # Membership communities are OperatorFlow's Sequel rows, so they carry status.
      def active_row?(community)
        community.status.to_s == "active"
      end

      # A viewer who operates nothing has no operators row to be named by, so the
      # dimension itself is the label. An administrator is named for the larger
      # of the two.
      def operator_name(memberships, administrator: false)
        operator = memberships.first&.operator
        return "administrator" if operator.nil? && administrator
        return "viewer" if operator.nil?
        # A floor owner has no person behind them, and their stand-in id is a
        # "floor:adapter:handle" string that reads as noise in a reply.
        return "owner" if operator.is_a?(ControlPlane::OperatorFlow::FloorOperator)

        person = @operator_flow.models.person[operator.person_id]
        presence(person&.name) || "operator ##{operator.id}"
      end

      def requester_label(request)
        return "someone" if request.nil?

        handle = presence(request.requester_username)
        display = presence(request.requester_display)
        base = display || (handle && "@#{handle}") || request.requester_native_id.to_s
        handle && display ? "#{display} (@#{handle})" : base
      end

      def lifecycle? = !@lifecycle.nil?

      def mapper? = !@mapper.nil?

      def web_login? = !@web_login.nil?

      def auth? = !@auth.nil?

      def feature_controls? = !@feature_controls.nil?

      def analytics? = !@analytics.nil?

      def vindication? = !@vindication.nil? && @vindication.available?

      def session_key(adapter, account, author)
        "#{SESSION_PREFIX}:#{adapter}:#{account}:#{author.native_id}"
      end

      def presence(value)
        return nil if value.nil?

        string = value.to_s.strip
        string.empty? ? nil : string
      end
    end
  end
end
