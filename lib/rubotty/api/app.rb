# frozen_string_literal: true

require "sinatra/base"
require "json"
require "yamlcamel"
require_relative "request_guard"

module Rubotty
  # REST admin API, authenticated per request via a bearer API key scoped
  # to one community ("developer") or globally ("administrator"). A
  # route-class scope failure (a developer key hitting `/admin/...`) is
  # 403; a resource-level one (a developer key naming a community it
  # can't touch) is 404, never 403, so as not to leak that the resource
  # exists. Responses use YAML; request bodies accept YAML, JSON or form encoding.
  module Api
    # Built per deployment through {.assemble}, mirroring {Dashboard::App}
    # and {GuestPortal::App}: an anonymous subclass per call, so a test can
    # stand up an isolated app over an in-memory control plane.
    class App < Sinatra::Base
      # Seconds between passes of the live stream's buffer read, matching
      # the guest portal's stream and the bot's receive loops.
      SSE_INTERVAL = 1

      # Includes room for JSON escaping of a maximum-size script and its fields.
      TEXT_BODY_BYTES = 4 * 1024 * 1024
      UPLOAD_ENVELOPE_BYTES = 64 * 1024

      # Build a configured app over a set of dependencies.
      #
      # @param deps [Deps]
      # @param env [Hash]
      # @param logger [#warn, nil]
      # @return [Class] a ready-to-serve Sinatra app subclass
      def self.assemble(deps:, env: ENV, logger: nil)
        marker = Object.new
        Class.new(self) do
          set :deps, deps
          set :api_env, env
          set :api_logger, logger
          set :request_guard_marker, marker
          use RequestGuard, deps: deps, marker: marker, text_limit: TEXT_BODY_BYTES,
                            envelope_bytes: UPLOAD_ENVELOPE_BYTES
          use Util::BodyLimit,
              max: ->(request_env) { request_env.fetch(RequestGuard::LIMIT_KEY, TEXT_BODY_BYTES) },
              response: lambda { |status, message, request_env|
                claim = request_env[RequestGuard::CLAIM_KEY]
                RequestGuard.response(status, message, authenticated: claim.is_a?(Hash) && claim[:marker].equal?(marker))
              }
        end
      end

      disable :show_exceptions
      enable :raise_errors
      disable :dump_errors
      # A bearer token in the Authorization header is the whole credential;
      # there is nothing to keep in a cookie and nothing for a CSRF check to
      # protect, matching {GuestPortal::App}'s identical reasoning.
      disable :sessions
      # Served behind the same reverse proxy as every other surface
      # (rubotty.example.org), which terminates the public hostname, so
      # Sinatra's Host whitelist is disabled and the proxy is the trust
      # boundary.
      set :host_authorization, permitted_hosts: []

      # The build this process is actually running, so "has the fix deployed
      # yet" is one request rather than a guess. A header, not a route: it
      # documents nothing and drifts against nothing. Kept off /healthz, the
      # one unauthenticated path, since a liveness probe should not hand an
      # anonymous caller the exact release this deployment is on (#1918).
      VERSION_HEADER = "X-Rubotty-Version"

      # Every response defaults to YAML; {#healthz} is the one exception,
      # overriding it to text/plain for a liveness probe. Set here, in a
      # +before+ filter rather than per-route, so a route that forgets to
      # set it explicitly still cannot emit Sinatra's default text/html.
      before do
        content_type "application/yaml"
        next if request.path_info == "/healthz"

        authenticate!
        headers VERSION_HEADER => Rubotty::VERSION.to_s
      end

      get "/healthz" do
        content_type "text/plain"
        "ok\n"
      end

      # A developer key reads only its own community; an administrator key
      # reads any.
      get "/communities/:slug" do
        community = community!(params[:slug])
        yaml_body(community_payload(community))
      end

      # Admin-only: every community, regardless of which one a developer key
      # might be scoped to. A developer key naming this route is a
      # route-class failure (403), since the route itself is not part of a
      # developer key's addressable world.
      get "/admin/communities" do
        require_admin!
        yaml_body("communities" => deps.communities.map { |row| community_payload(row) })
      end

      # The deployment's credentialed gateway accounts (migration 026):
      # global, no community concept at all (see ControlPlane::Accounts'
      # own class comment on why adding one would be a modelling error), so
      # this lives under /admin/... rather than any /communities/:slug path.
      get "/admin/accounts" do
        require_admin!
        yaml_body("accounts" => deps.accounts.list.map { |row| account_payload(row) })
      end

      get "/admin/accounts/:adapter/:name" do
        require_admin!
        account = account!(params[:adapter], params[:name])
        yaml_body(account_payload(account))
      end

      # Every issued API key, dashboard-listing parity: public_id, scope,
      # label and usage, never the token itself (only its digest is ever
      # stored, see ControlPlane::ApiKeys' own class comment).
      get "/admin/api-keys" do
        require_admin!
        yaml_body("api_keys" => deps.api_keys.list.map { |row| api_key_payload(row) })
      end

      # Deployment-wide, no community concept, same reasoning as /admin/accounts
      # above. PATCH below writes the same row the dashboard's Integrations
      # page saves, through the same {ControlPlane::Integrations#save}.
      get "/admin/integrations" do
        require_admin!
        yaml_body("integrations" => deps.integrations.list.map { |row| integration_payload(row) })
      end

      get "/admin/integrations/:name" do
        require_admin!
        yaml_body(integration_payload(integration!(params[:name])))
      end

      # A blank or omitted api_key leaves whatever key is stored untouched;
      # url and config fall back to what's already stored the same way
      # {#endpoint_attributes} and {#irc_network_attributes} do.
      patch "/admin/integrations/:name" do
        require_admin!
        existing = integration!(params[:name])
        row = with_control_plane_error { deps.integrations.save(**integration_attributes(existing)) }
        yaml_body(integration_payload(row))
      end

      # ----------------------------------------------------------------
      # onboarding: a space the bot was added to that no community owns
      # ----------------------------------------------------------------

      # The API half of the dashboard's Onboarding queue, over
      # {ControlPlane::PendingSpaces}. No slug, since a pending space
      # belongs to no community yet, and approving one decides whether
      # the bot is even present somewhere.
      get "/admin/pending-spaces" do
        require_admin!
        yaml_body("pending_spaces" => pending_spaces_in_state.map { |row| pending_space_payload(row) })
      end

      get "/admin/pending-spaces/:id" do
        require_admin!
        yaml_body(pending_space_payload(pending_space!(params[:id])))
      end

      # Accept a space onto an existing community (`community` slug) or a new
      # one (`new_community_name`). Writes only the platform connection, so
      # the community stays dormant exactly as it does when the dashboard
      # approves one.
      post "/admin/pending-spaces/:id/approve" do
        require_admin!
        pending = pending_space!(params[:id])
        result = approve_pending_space(pending)
        halt 422, yaml_body("error" => pending_space_refusal(result)) unless result.approved?

        yaml_body(
          "pending_space" => pending_space_payload(result.row),
          "community" => community_payload(result.community)
        )
      end

      # Refuse a space. This process holds no adapters, so the departure is
      # scheduled for whichever bot process is running, matching a dashboard
      # deny; the row stays a soft blacklist entry until cleared below.
      post "/admin/pending-spaces/:id/reject" do
        require_admin!
        pending = pending_space!(params[:id])
        result = deps.pending_spaces.deny(id: pending.id, admin: actor_label)
        halt 422, yaml_body("error" => pending_space_refusal(result)) unless result.denied?

        yaml_body(pending_space_payload(result.row))
      end

      # Drop a denied row, so a later join for that space starts a fresh
      # review instead of being silently refused again. Only a denied row can
      # be cleared: a pending one is decided through approve or reject.
      delete "/admin/pending-spaces/:id" do
        require_admin!
        pending = pending_space!(params[:id])
        unless deps.pending_spaces.clear(id: pending.id)
          halt 422, yaml_body("error" => "only a denied space can be cleared")
        end

        status 204
      end

      # Who reads every community and changes nothing. Administrator-only
      # since the dimension spans the deployment; "baked_in" is the shipped
      # floor, listed separately because no call here can revoke it.
      get "/admin/viewers" do
        require_admin!
        yaml_body(
          "viewers" => deps.dashboard_viewers.granted.map { |row| viewer_payload(row) },
          "baked_in" => deps.dashboard_viewers.baked_in.map { |entry| baked_in_viewer_payload(entry) }
        )
      end

      post "/admin/viewers" do
        require_admin!
        body = write_body_params
        row = deps.dashboard_viewers.grant(
          adapter: body["adapter"].to_s, handle: body["handle"].to_s,
          native_id: body["native_id"], label: body["label"], granted_by: actor_label
        )
        status 201
        yaml_body(viewer_payload(row))
      end

      # Refuses a handle the shipped list also names: deleting the row would
      # read as a revocation while the floor kept handing that person every
      # community.
      delete "/admin/viewers/:id" do
        require_admin!
        result = deps.dashboard_viewers.revoke(id: params[:id], revoked_by: actor_label)
        halt 404, yaml_body("error" => "not found") if result.status == :not_found
        if result.protected?
          halt 422, yaml_body("error" => "that handle ships with the deployment and cannot be revoked")
        end

        status 204
        body ""
      end

      get "/admin/viewer-requests" do
        require_admin!
        yaml_body("viewer_requests" => deps.dashboard_viewers.pending.map { |row| viewer_request_payload(row) })
      end

      post "/admin/viewer-requests/:id/approve" do
        require_admin!
        request_row = viewer_request!(params[:id])
        result = deps.dashboard_viewers.approve(request: request_row, decided_by: actor_label)
        halt 422, yaml_body("error" => "that request has already been decided") unless result.approved?

        yaml_body("request" => viewer_request_payload(result.request), "viewer" => viewer_payload(result.viewer))
      end

      post "/admin/viewer-requests/:id/deny" do
        require_admin!
        request_row = viewer_request!(params[:id])
        result = deps.dashboard_viewers.deny(request: request_row, decided_by: actor_label)
        halt 422, yaml_body("error" => "that request has already been decided") unless result.denied?

        yaml_body("request" => viewer_request_payload(result.request))
      end

      # Who administers every community. The roster has the same shipped floor
      # as viewers, but no request queue: handing out the highest role is an
      # explicit administrator action.
      get "/admin/administrators" do
        require_admin!
        yaml_body(
          "administrators" => deps.dashboard_administrators.granted.map { |row| administrator_payload(row) },
          "baked_in" => deps.dashboard_administrators.baked_in.map { |entry| baked_in_administrator_payload(entry) }
        )
      end

      post "/admin/administrators" do
        require_admin!
        body = write_body_params
        row = deps.dashboard_administrators.grant(
          adapter: body["adapter"].to_s, handle: body["handle"].to_s,
          native_id: body["native_id"], label: body["label"], granted_by: actor_label
        )
        status 201
        yaml_body(administrator_payload(row))
      end

      # A shipped administrator stays in force under the granted roster, so a
      # delete would make a false promise and is refused by the same service.
      delete "/admin/administrators/:id" do
        require_admin!
        result = deps.dashboard_administrators.revoke(id: params[:id], revoked_by: actor_label)
        halt 404, yaml_body("error" => "not found") if result.not_found?
        if result.protected?
          halt 422, yaml_body("error" => "that handle ships with the deployment and cannot be revoked")
        end

        status 204
        body ""
      end

      # The deployment-wide ceiling on what ANY operator may change,
      # governing every community identically. An individual operator's
      # own grant (see /communities/:slug/operators) narrows within
      # whatever this allows, but can never widen past it.
      get "/admin/action-permissions" do
        require_admin!
        yaml_body("permissions" => deps.action_permissions.rows.map { |row| action_permission_payload(row) })
      end

      # Full replace: this body sets every action in the catalog, writable
      # only when its value is truthy. Omitted and explicit `false` both
      # land as not writable, since {Dashboard::ActionPermissions#update}
      # is presence-only and would otherwise grant an explicit `false`.
      patch "/admin/action-permissions" do
        require_admin!
        body = write_body_params
        permissions = body["permissions"]
        unless permissions.is_a?(Hash)
          halt 400, yaml_body("error" => "body must set permissions as a mapping of action name to a boolean")
        end
        granted = permissions.select { |_action, value| truthy_param?(value) }
        deps.action_permissions.update(granted)
        yaml_body("permissions" => deps.action_permissions.rows.map { |row| action_permission_payload(row) })
      end

      # Administrator-only: a token minted here carries the deployment-wide
      # viewer grant itself, so a developer key minting one would bypass the
      # check by handing that dimension over directly. Community-scoped
      # tokens live on the community path below.
      get "/admin/auth-tokens" do
        require_admin!
        yaml_body("auth_tokens" => deps.auth_tokens.list(every: true).map { |row| auth_token_payload(row) })
      end

      # The one place the raw token is ever readable, and it is readable once:
      # only its digest is stored, so it cannot be shown again afterwards.
      post "/admin/auth-tokens" do
        require_admin!
        body = write_body_params
        issued = deps.auth_tokens.mint(
          minter: admin_minter, community_id: nil, viewer: true,
          ttl_seconds: token_ttl(body), label: body["label"]
        )
        status 201
        yaml_body(auth_token_payload(issued.row).merge("token" => issued.token))
      end

      delete "/admin/auth-tokens/:public_id" do
        require_admin!
        revoke_auth_token(params[:public_id], every: true)
      end

      # Structural changes reach the same durable request queue as the
      # dashboard. They are administrator-only: a developer key is trusted to
      # work with a community's content, not to create or remove platform
      # channels beneath it.
      post "/admin/communities/:slug/rooms" do
        require_admin!
        community = community!(params[:slug])
        given = write_body_params
        platforms = given["platforms"]
        unless platforms.is_a?(Array) && platforms.all? { |entry| entry.is_a?(Hash) }
          halt 422, yaml_body("error" => "platforms must be a list of platform connections")
        end

        result = with_control_plane_error do
          deps.room_provisioning.request_create(
            community: community, name: given["name"], platforms: platforms,
            template_channel: presence(given["template_channel"]), requested_by: actor_label
          )
        end
        status 202
        yaml_body(room_provisioning_payload(result))
      end

      delete "/admin/communities/:slug/rooms/:room_key" do
        require_admin!
        community = community!(params[:slug])
        room = room!(community, params[:room_key])
        given = write_body_params
        requested = Array(given["force_endpoint_keys"])
        unless requested.all? { |key| key.is_a?(String) }
          halt 422, yaml_body("error" => "force_endpoint_keys must be a list of endpoint keys")
        end

        force_channels = room.channels.select { |channel| requested.include?(channel.endpoint_key) }
        if force_channels.length != requested.uniq.length
          halt 422, yaml_body("error" => "every forced endpoint key must belong to this room")
        end

        result = with_control_plane_error do
          deps.room_provisioning.request_delete(
            community: community, room: room, confirmed_name: given["confirmed_name"],
            requested_by: actor_label, delete_platform_channels: truthy_param("delete_platform_channels", false),
            force_channel_ids: force_channels.map(&:id)
          )
        end
        status 202
        yaml_body(room_provisioning_payload(result))
      end

      # A community is either actively bridged or suspended. PUT keeps the
      # desired state idempotent, whether the request changes it or confirms
      # that it was already there.
      put "/admin/communities/:slug/status" do
        require_admin!
        community = community!(params[:slug])
        desired = write_body_params["status"].to_s
        result = case desired
                 when ControlPlane::CommunityLifecycle::ACTIVE then deps.lifecycle.start(community: community)
                 when ControlPlane::CommunityLifecycle::SUSPENDED then deps.lifecycle.stop(community: community)
                 else
                   halt 422, yaml_body("error" => "status must be active or suspended")
                 end
        yaml_body(community_payload(result.community))
      end

      get "/admin/communities/:slug/mutes" do
        require_admin!
        community = community!(params[:slug])
        yaml_body("mutes" => deps.moderation.active_mutes(community: community).map { |row| sanction_payload(row) })
      end

      post "/admin/communities/:slug/mutes" do
        require_admin!
        community = community!(params[:slug])
        given = write_body_params
        sanction = with_control_plane_error do
          deps.moderation.mute(
            community: community, adapter: given["adapter"], native_id: given["native_id"],
            username: presence(given["username"]), display: presence(given["display"]),
            duration: presence(given["duration"]), reason: presence(given["reason"]), issued_by: actor_label
          )
        end
        halt 503, yaml_body("error" => "could not record the mute") if sanction.nil?

        status 201
        yaml_body(sanction_payload(sanction))
      end

      delete "/admin/communities/:slug/mutes/:id" do
        require_admin!
        community = community!(params[:slug])
        sanction = deps.moderation.unmute(community: community, id: params[:id])
        halt 404, yaml_body("error" => "not found") if sanction.nil?

        yaml_body(sanction_payload(sanction, active: false))
      end

      # A developer key sees only its own community's rooms, an administrator
      # any. Each room lists the endpoint_keys of the channels bridged into
      # it, the same merge {ControlPlane::ChannelMapper} produces.
      get "/communities/:slug/rooms" do
        community = community!(params[:slug])
        yaml_body("rooms" => community.rooms.map { |row| room_payload(row) })
      end

      get "/communities/:slug/rooms/:room_key" do
        community = community!(params[:slug])
        room = room!(community, params[:room_key])
        yaml_body(room_payload(room))
      end

      # Queues into the moderation pipeline: the bot's own adapter emits it
      # as an ordinary inbound message, subject to the same word, link and
      # anti-spam filters as a member's post. Answers 201 "queued" rather
      # than 200 "sent", since a filtered post is simply dropped silently.
      post "/communities/:slug/rooms/:room_key/messages" do
        community = community!(params[:slug])
        room = room!(community, params[:room_key])
        reject_yaml_boolean!(write_body_params["body"])
        text = write_body_params["body"].to_s.strip
        halt 422, yaml_body("error" => "body cannot be empty") if text.empty?
        if text.length > ControlPlane::ApiMessages::MAX_BODY
          halt 422, yaml_body("error" => "body is longer than #{ControlPlane::ApiMessages::MAX_BODY} characters")
        end

        row = deps.api_messages.enqueue(community: community, room: room, key: current_key, body: text)
        status 201
        yaml_body("status" => "queued", "id" => row.id, "room_key" => room.room_key)
      end

      # ------------------------------------------------------------------
      # meta-level message actions: react, edit and delete a message the
      # room-level POST above minted, by that same "id", never a channel_id.
      # ------------------------------------------------------------------

      # Every route here re-resolves the id against the message map through
      # {#meta_message!}, so a made up, another room's, or expired id 404s
      # rather than queuing an action that could only ever do nothing.

      put "/communities/:slug/rooms/:room_key/messages/:message_id/reactions" do
        community = community!(params[:slug])
        room = room!(community, params[:room_key])
        message = meta_message!(room, params[:message_id])
        reaction = bridge_reaction(write_body_params)
        if reaction.values_at(:emoji, :custom_id).all?(&:nil?)
          halt 422, yaml_body("error" => "reaction.emoji or reaction.custom_id is required")
        end

        deps.api_message_actions.enqueue_reaction_add(
          community: community, room: room, message: message, key: current_key, reaction: reaction
        )
        status 202
        yaml_body("status" => "queued")
      end

      delete "/communities/:slug/rooms/:room_key/messages/:message_id/reactions" do
        community = community!(params[:slug])
        room = room!(community, params[:room_key])
        message = meta_message!(room, params[:message_id])
        reaction = bridge_reaction(write_body_params)
        if reaction.values_at(:emoji, :custom_id).all?(&:nil?)
          halt 422, yaml_body("error" => "reaction.emoji or reaction.custom_id is required")
        end

        deps.api_message_actions.enqueue_reaction_remove(
          community: community, room: room, message: message, key: current_key, reaction: reaction
        )
        status 202
        yaml_body("status" => "queued")
      end

      patch "/communities/:slug/rooms/:room_key/messages/:message_id" do
        community = community!(params[:slug])
        room = room!(community, params[:room_key])
        message = meta_message!(room, params[:message_id])
        reject_yaml_boolean!(write_body_params["body"])
        text = write_body_params["body"].to_s
        halt 422, yaml_body("error" => "body cannot be empty") if text.strip.empty?
        if text.length > ControlPlane::ApiMessageActions::MAX_BODY
          halt 422, yaml_body("error" => "body is longer than #{ControlPlane::ApiMessageActions::MAX_BODY} characters")
        end

        deps.api_message_actions.enqueue_edit(
          community: community, room: room, message: message, key: current_key, body: text
        )
        status 202
        yaml_body("status" => "queued")
      end

      delete "/communities/:slug/rooms/:room_key/messages/:message_id" do
        community = community!(params[:slug])
        room = room!(community, params[:room_key])
        message = meta_message!(room, params[:message_id])

        deps.api_message_actions.enqueue_delete(
          community: community, room: room, message: message, key: current_key
        )
        status 202
        yaml_body("status" => "queued")
      end

      # ------------------------------------------------------------------
      # bridge: the api_wrapper platform adapter's own inbound surface.
      # ------------------------------------------------------------------

      # Unlike POST .../rooms/:room_key/messages above, a call here names
      # the real remote person who acted; +channel_id+ is the remote
      # system's own identifier for the conversation, mapped to a room
      # once during provisioning.

      post "/communities/:slug/bridge/channels/:channel_id/messages" do
        community = community!(params[:slug])
        channel = bridge_channel!(community, params[:channel_id])
        given = write_body_params
        reject_yaml_boolean!(given["body"])
        body = given["body"].to_s
        attachments = bridge_attachments(given)
        halt 422, yaml_body("error" => "body cannot be empty") if body.strip.empty? && attachments.empty?
        if body.length > ControlPlane::ApiWrapperEvents::MAX_BODY
          halt 422, yaml_body("error" => "body is longer than #{ControlPlane::ApiWrapperEvents::MAX_BODY} characters")
        end

        row = deps.api_wrapper_events.enqueue_message(
          account: current_key.platform_account, channel_id: channel.route_key, body: body,
          author: bridge_author(given), reply_to: presence(given["reply_to"]), attachments: attachments
        )
        status 201
        yaml_body("status" => "queued", "message_id" => row.id.to_s)
      end

      patch "/communities/:slug/bridge/channels/:channel_id/messages/:message_id" do
        community = community!(params[:slug])
        channel = bridge_channel!(community, params[:channel_id])
        given = write_body_params
        reject_yaml_boolean!(given["body"])
        body = given["body"].to_s
        halt 422, yaml_body("error" => "body cannot be empty") if body.strip.empty?

        deps.api_wrapper_events.enqueue_edit(
          account: current_key.platform_account, channel_id: channel.route_key,
          target_native_id: params[:message_id], body: body, author: bridge_author(given)
        )
        status 202
        yaml_body("status" => "queued")
      end

      delete "/communities/:slug/bridge/channels/:channel_id/messages/:message_id" do
        community = community!(params[:slug])
        channel = bridge_channel!(community, params[:channel_id])
        given = write_body_params

        deps.api_wrapper_events.enqueue_delete(
          account: current_key.platform_account, channel_id: channel.route_key,
          target_native_id: params[:message_id], author: bridge_author(given)
        )
        status 202
        yaml_body("status" => "queued")
      end

      put "/communities/:slug/bridge/channels/:channel_id/messages/:message_id/reactions" do
        community = community!(params[:slug])
        channel = bridge_channel!(community, params[:channel_id])
        given = write_body_params
        reaction = bridge_reaction(given)
        if reaction.values_at(:emoji, :custom_id).all?(&:nil?)
          halt 422, yaml_body("error" => "reaction.emoji or reaction.custom_id is required")
        end

        deps.api_wrapper_events.enqueue_reaction_add(
          account: current_key.platform_account, channel_id: channel.route_key,
          target_native_id: params[:message_id], author: bridge_author(given), reaction: reaction
        )
        status 202
        yaml_body("status" => "queued")
      end

      delete "/communities/:slug/bridge/channels/:channel_id/messages/:message_id/reactions" do
        community = community!(params[:slug])
        channel = bridge_channel!(community, params[:channel_id])
        given = write_body_params
        reaction = bridge_reaction(given)
        if reaction.values_at(:emoji, :custom_id).all?(&:nil?)
          halt 422, yaml_body("error" => "reaction.emoji or reaction.custom_id is required")
        end

        deps.api_wrapper_events.enqueue_reaction_remove(
          account: current_key.platform_account, channel_id: channel.route_key,
          target_native_id: params[:message_id], author: bridge_author(given), reaction: reaction
        )
        status 202
        yaml_body("status" => "queued")
      end

      # A member arriving in, or going from, a channel. The member rides in the
      # body rather than the path, the same as the reaction pair above. A game
      # server's stream is mostly this, which is why it is a kind of its own
      # rather than a chat line saying somebody joined.

      post "/communities/:slug/bridge/channels/:channel_id/members" do
        community = community!(params[:slug])
        channel = bridge_channel!(community, params[:channel_id])
        author = bridge_member!(write_body_params)

        deps.api_wrapper_events.enqueue_join(
          account: current_key.platform_account, channel_id: channel.route_key, author: author
        )
        status 202
        yaml_body("status" => "queued")
      end

      delete "/communities/:slug/bridge/channels/:channel_id/members" do
        community = community!(params[:slug])
        channel = bridge_channel!(community, params[:channel_id])
        author = bridge_member!(write_body_params)

        deps.api_wrapper_events.enqueue_leave(
          account: current_key.platform_account, channel_id: channel.route_key, author: author
        )
        status 202
        yaml_body("status" => "queued")
      end

      # A live stream of what is passing through a room, as server-sent
      # events over the buffer {ControlPlane::LiveRoomFeed} writes at
      # fan-out. A subscriber with no cursor starts at the current head,
      # new messages only: an edit, delete or reaction never reaches it.
      get "/communities/:slug/rooms/:room_key/stream" do
        community = community!(params[:slug])
        room = room!(community, params[:room_key])
        community_id = community.id
        room_key = room.room_key

        content_type "text/event-stream"
        headers "Cache-Control" => "no-cache", "X-Accel-Buffering" => "no"

        cursor = opening_cursor(community_id: community_id, room_key: room_key)
        max_passes = sse_max_passes
        # Captured before the stream block, which runs after the request scope
        # is gone.
        token = bearer_token
        key = @api_key
        meter_every = sse_meter_seconds
        stream(:keep_open) do |out|
          # An opening frame so the client confirms the stream is live and pins
          # its cursor, even on a room where nothing is being said.
          out << sse_event({ "room_key" => room_key, "cursor" => cursor, "messages" => [] }, id: cursor)
          last_sent_at = Time.now
          last_metered_at = Time.now
          passes = 0
          loop do
            break if out.respond_to?(:closed?) && out.closed?

            begin
              entries = deps.live_room_feed.since(community_id: community_id, room_key: room_key, since: cursor)
              unless entries.empty?
                cursor = entries.last.id
                out << sse_event(
                  { "room_key" => room_key, "cursor" => cursor,
                    "messages" => entries.map { |entry| stream_message_payload(entry) } },
                  id: cursor
                )
                last_sent_at = Time.now
              end
              if Time.now - last_sent_at >= sse_heartbeat_interval
                out << sse_heartbeat
                last_sent_at = Time.now
              end
            rescue StandardError
              # A transient read must not end the stream loudly. Close it
              # cleanly and let the client reconnect, which is what an SSE
              # client does by itself.
              break
            end

            # One unit per limiter window, for as long as held. Charged
            # rather than checked, so a stream already inside the limit
            # when it opened is never killed retroactively; concurrent
            # streams are capped near a key's per-window allowance.
            if Time.now - last_metered_at >= meter_every
              meter_stream(key)
              last_metered_at = Time.now
            end

            passes += 1
            break if max_passes && passes >= max_passes
            # authenticate! runs once, in the before filter, so revocation
            # would otherwise never reach a stream already open. Re-checked
            # every pass: one indexed lookup beside the buffer scan this loop
            # already does each second.
            break unless stream_key_live?(token)

            sleep(SSE_INTERVAL)
          end
          out.close
        end
      end

      get "/communities/:slug/channels" do
        community = community!(params[:slug])
        yaml_body("channels" => community.channels.map { |row| channel_payload(row) })
      end

      # endpoint_key is globally unique (it is the message map's own join
      # key), but the lookup is still scoped to +community+ so a developer
      # key cannot address a channel outside its own community by guessing
      # its key, matching {#room!} and {#platform_connection!}'s reasoning.
      get "/communities/:slug/channels/:endpoint_key" do
        community = community!(params[:slug])
        channel = channel!(community, params[:endpoint_key])
        yaml_body(channel_payload(channel))
      end

      # The passively-observed cross-platform identity directory. No POST:
      # a person row is only ever created by observing them talk (see Seed
      # and the bot's own identity recording), never authored from
      # nothing.
      get "/communities/:slug/people" do
        community = community!(params[:slug])
        # One query for the whole community's nicknames rather than one per
        # person, the same call the Snapshot builder makes for the same reason.
        held = deps.bridged_nicknames.by_person(community_id: community.id)
        yaml_body("people" => community.people.map { |row| person_payload(row, held[row.id] || {}) })
      end

      get "/communities/:slug/people/:id" do
        community = community!(params[:slug])
        person = person!(community, params[:id])
        yaml_body(person_payload(person, nicknames_of(community, person)))
      end

      # Set the name this person is bridged as on one platform: the
      # platform in the path is where the name is SHOWN, never where the
      # person was observed, matching the `/nickname <platform> <name>`
      # command.
      put "/communities/:slug/people/:id/nicknames/:adapter" do
        community = community!(params[:slug])
        person = person!(community, params[:id])
        refuse_when_nicknames_are_off!(community)
        nickname = presence(write_body_params["nickname"])
        halt 400, yaml_body("error" => "nickname is required") if nickname.nil?

        result = deps.bridged_nicknames.set(
          community_id: community.id, person_id: person.id, adapter: params[:adapter],
          nickname: nickname, set_by: actor_label
        )
        if result.status == :taken
          halt 422, yaml_body("error" => "#{result.nickname} is already taken on #{result.adapter}")
        end

        yaml_body(person_payload(person, nicknames_of(community, person)))
      end

      # Drop one, so they are shown under whatever the sender label would
      # otherwise build. Deliberately NOT behind the who_can_set gate the set
      # above honours: clearing a name that has become a problem is the lever an
      # operator keeps whatever the policy is.
      delete "/communities/:slug/people/:id/nicknames/:adapter" do
        community = community!(params[:slug])
        person = person!(community, params[:id])
        result = deps.bridged_nicknames.clear(
          community_id: community.id, person_id: person.id, adapter: params[:adapter]
        )
        halt 404, yaml_body("error" => "not found") if result.status == :missing

        status 204
        body ""
      end

      # Everyone who may moderate here, from both the database rows and the
      # shipped "always operators" floor, which is code-owned and applies in
      # every community. The floor is listed first; every entry says which
      # source it came from and whether the revoke below can touch it.
      get "/communities/:slug/operators" do
        community = community!(params[:slug])
        baked_in = Security::ProtectedOperators.default.entries.map { |entry| baked_in_operator_payload(entry) }
        yaml_body("operators" => baked_in + community.operators.map { |row| operator_payload(row) })
      end

      # Who reads one community and changes nothing in it. On the ordinary
      # community path, since a developer key confined to this community
      # may hand this out without reaching further. "baked_in" is the
      # shipped floor, listed separately since no call here can revoke it.
      get "/communities/:slug/viewers" do
        community = community!(params[:slug])
        yaml_body(
          "viewers" => deps.community_viewers.granted(community_id: community.id)
                           .map { |row| community_viewer_payload(row) },
          "baked_in" => deps.community_viewers.baked_in.map { |entry| baked_in_viewer_payload(entry) }
        )
      end

      post "/communities/:slug/viewers" do
        community = community!(params[:slug])
        body = write_body_params
        row = deps.community_viewers.grant(
          community_id: community.id, adapter: body["adapter"].to_s, handle: body["handle"].to_s,
          native_id: body["native_id"], label: body["label"], granted_by: actor_label
        )
        status 201
        yaml_body(community_viewer_payload(row))
      end

      # Refuses a handle the shipped list also names: deleting the row would
      # read as a revocation while the floor kept handing that person every
      # community.
      delete "/communities/:slug/viewers/:id" do
        community = community!(params[:slug])
        result = deps.community_viewers.revoke(
          community_id: community.id, id: params[:id], revoked_by: actor_label
        )
        halt 404, yaml_body("error" => "not found") if result.status == :not_found
        if result.protected?
          halt 422, yaml_body("error" => "that handle ships with the deployment and cannot be revoked")
        end

        status 204
        body ""
      end

      get "/communities/:slug/viewer-requests" do
        community = community!(params[:slug])
        yaml_body(
          "viewer_requests" => deps.community_viewers.pending(community_id: community.id)
                                   .map { |row| community_viewer_request_payload(row) }
        )
      end

      post "/communities/:slug/viewer-requests/:id/approve" do
        community = community!(params[:slug])
        request_row = community_viewer_request!(community, params[:id])
        result = deps.community_viewers.approve(request: request_row, decided_by: actor_label)
        halt 422, yaml_body("error" => "that request has already been decided") unless result.approved?

        yaml_body("request" => community_viewer_request_payload(result.request),
                  "viewer" => community_viewer_payload(result.viewer))
      end

      post "/communities/:slug/viewer-requests/:id/deny" do
        community = community!(params[:slug])
        request_row = community_viewer_request!(community, params[:id])
        result = deps.community_viewers.deny(request: request_row, decided_by: actor_label)
        halt 422, yaml_body("error" => "that request has already been decided") unless result.denied?

        yaml_body("request" => community_viewer_request_payload(result.request))
      end

      # Tokens scoped to one community: operator there, viewer there, or both.
      # On the ordinary community path, same reasoning as the community
      # viewer routes; the scope is the path's, never the body's, so nothing
      # sent here can widen into the deployment-wide token above.
      get "/communities/:slug/auth-tokens" do
        community = community!(params[:slug])
        yaml_body(
          "auth_tokens" => deps.auth_tokens.list(community_id: community.id)
                               .map { |row| auth_token_payload(row) }
        )
      end

      post "/communities/:slug/auth-tokens" do
        community = community!(params[:slug])
        body = write_body_params
        issued = deps.auth_tokens.mint(
          minter: community_minter(community), community_id: community.id,
          operator: truthy_param?(body["operator"]), viewer: truthy_param?(body["viewer"]),
          ttl_seconds: token_ttl(body), label: body["label"]
        )
        status 201
        yaml_body(auth_token_payload(issued.row).merge("token" => issued.token))
      end

      delete "/communities/:slug/auth-tokens/:public_id" do
        community = community!(params[:slug])
        revoke_auth_token(params[:public_id], community_id: community.id)
      end

      get "/communities/:slug/operator-requests" do
        community = community!(params[:slug])
        yaml_body("operator_requests" => community.operator_requests.map { |row| operator_request_payload(row) })
      end

      get "/communities/:slug/operator-requests/:id" do
        community = community!(params[:slug])
        request = operator_request!(community, params[:id])
        yaml_body(operator_request_payload(request))
      end

      # Handing somebody moderation of a community is administrator
      # territory, so both writes sit under /admin/ while the read above
      # stays on the ordinary path. Named by platform account, since the
      # person being promoted may have no row yet; one is created for them.
      post "/admin/communities/:slug/operators" do
        require_admin!
        community = community!(params[:slug])
        body = write_body_params
        adapter = presence(body["adapter"])
        native_id = presence(body["native_id"])
        halt 400, yaml_body("error" => "adapter and native_id are both required") if adapter.nil? || native_id.nil?

        operator = deps.operators.promote(
          community_id: community.id, adapter: adapter, native_id: native_id,
          username: presence(body["username"]), display: presence(body["display"]),
          granted_by: actor_label
        )
        status 201
        yaml_body(operator_payload(operator))
      end

      # Refused with 422 for somebody the shipped floor also names: the row
      # would go while the floor kept handing them owner-level access here and
      # everywhere else, so the call would read as a revocation and not be one.
      delete "/admin/communities/:slug/operators/:id" do
        require_admin!
        community = community!(params[:slug])
        result = deps.operators.remove(community_id: community.id, id: params[:id])
        halt 404, yaml_body("error" => "not found") if result.status == :not_found
        if result.protected?
          halt 422, yaml_body("error" => "that person is a deployment-configured owner here and cannot be revoked")
        end

        status 204
        body ""
      end

      # The same todo list the dashboard's Discovered-channels page shows,
      # read from {ControlPlane::ChannelDiscovery#unmapped} rather than a
      # duplicated query, so the two can never disagree. Read-only here;
      # approve/reject land with the other write endpoints.
      get "/communities/:slug/discovered-channels" do
        community = community!(params[:slug])
        yaml_body("discovered_channels" => deps.channel_discovery.unmapped(community).map { |row| channel_payload(row) })
      end

      # The API half of the dashboard's button. Two steps on purpose: this
      # one only proposes and writes nothing, so a client can show the
      # proposals to a human before anything happens.
      get "/communities/:slug/discovered-channels/mapping-proposals" do
        community = community!(params[:slug])
        channels = deps.channel_discovery.unmapped(community)
        rooms = models.room.where(community_id: community.id).order(:room_key).all
        proposals = deps.auto_mapper.propose(channels: channels, rooms: rooms)
        yaml_body("proposals" => proposals.map { |proposal| mapping_proposal_payload(proposal) })
      end

      # Apply an approved subset: the body names endpoint_keys and the
      # room each should land in, so a client can drop or edit any
      # proposal instead of taking the lot. Goes through the same
      # ChannelMapper#resolve_selection call the dashboard and DM console use.
      post "/communities/:slug/discovered-channels/mapping-proposals/apply" do
        community = community!(params[:slug])
        mappings = write_body_params["mappings"]
        halt 400, yaml_body("error" => "mappings must be a list") unless mappings.is_a?(Array)

        eligible = deps.channel_discovery.unmapped(community).to_h { |c| [c.endpoint_key, c] }
        applied = mappings.count { |entry| apply_one_mapping(community, entry, eligible) }
        yaml_body("applied" => applied, "requested" => mappings.size)
      end

      # Map one discovered channel to a destination: `room_key` (existing
      # or new room), `partner` (seed with another discovered channel) or
      # `solo`. Mapping enables no feature; the channel simply joins the
      # room's topology exactly as dormant as it was.
      post "/communities/:slug/discovered-channels/:endpoint_key/map" do
        community = community!(params[:slug])
        channel = discovered_channel!(community, params[:endpoint_key])
        body = write_body_params
        result = deps.channel_mapper.resolve_selection(
          community: community, channel: channel, room_key: presence(body["room_key"]),
          partner: presence(body["partner"]), solo: truthy_param?(body["solo"]),
          label: presence(body["label"])
        )
        yaml_body(
          "room" => room_payload(result.room),
          "channels" => result.channels.map { |row| channel_payload(row) }
        )
      end

      # What a non-operator's /identify-topic named, waiting on a decision. A
      # suggestion is an ordinary channel row flagged as one, so it reads
      # like any other channel plus the id the two decisions below are
      # addressed by.
      get "/communities/:slug/suggested-channels" do
        community = community!(params[:slug])
        yaml_body(
          "suggested_channels" => suggested_channels(community).map { |row| suggested_channel_payload(row) }
        )
      end

      # Keep it: the row stops being flagged and nothing else about it changes.
      post "/communities/:slug/suggested-channels/:id/approve" do
        community = community!(params[:slug])
        channel = suggested_channel!(community, params[:id])
        yaml_body(suggested_channel_payload(deps.channel_discovery.approve_suggestion(channel.id)))
      end

      # Reject its name: the channel remains, with its label blank and suggestion
      # flag cleared. Only a row still flagged as a suggestion is ever reached
      # here, so this cannot alter a real channel by guessing an id.
      post "/communities/:slug/suggested-channels/:id/reject" do
        community = community!(params[:slug])
        channel = suggested_channel!(community, params[:id])
        deps.channel_discovery.reject_suggestion(channel.id)
        status 204
        body ""
      end

      # Which still-pending spaces look, by name, like they belong to this
      # community. Guesses only, nothing writes; admin-only, since a guess
      # about a space nobody owns is still a look at somebody else's.
      get "/admin/communities/:slug/space-suggestions" do
        require_admin!
        community = community!(params[:slug])
        suggestions = deps.space_suggestions.for_community(
          community: community, spaces: deps.pending_spaces.pending
        )
        yaml_body("suggestions" => suggestions.map { |row| space_suggestion_payload(row) })
      end

      # The community-wide feature defaults ("all" scope): every feature row
      # with no room override.
      get "/communities/:slug/features" do
        community = community!(params[:slug])
        yaml_body("features" => deps.feature_controls.list(community, selector: "all").map { |e| feature_payload(e) })
      end

      get "/communities/:slug/features/:feature" do
        community = community!(params[:slug])
        yaml_body(feature_payload(feature_entry!(community, selector: "all", feature: params[:feature])))
      end

      # A room's OWN feature rows: only what has actually been set for
      # this room, not the community default it would otherwise inherit
      # (see {ControlPlane::FeatureControls#inherited_enabled}). A room
      # missing a row here has simply never had that feature configured.
      get "/communities/:slug/rooms/:room_key/features" do
        community = community!(params[:slug])
        room!(community, params[:room_key])
        yaml_body(
          "features" => deps.feature_controls.list(community, selector: params[:room_key]).map { |e| feature_payload(e) }
        )
      end

      # What a feature ACTUALLY resolves to for one room: its own override
      # when it has one, otherwise the community-wide default, and
      # `inherited` says which answered. The list route above reports
      # what's been set; this reports what's in force.
      get "/communities/:slug/rooms/:room_key/features/:feature" do
        community = community!(params[:slug])
        room = room!(community, params[:room_key])
        yaml_body(room_feature_payload(community, room, params[:feature]))
      end

      # PATCH sets `enabled` and/or merges `config` for a scope: the FIRST
      # write endpoint in this app, establishing the request-body
      # convention (see {#write_body_params}) every later write endpoint
      # reuses, each config key coerced the same way a CLI or dashboard save is.
      patch "/communities/:slug/features/:feature" do
        community = community!(params[:slug])
        yaml_body(apply_feature_write(community: community, selector: "all", feature: params[:feature]))
      end

      patch "/communities/:slug/rooms/:room_key/features/:feature" do
        community = community!(params[:slug])
        room!(community, params[:room_key])
        yaml_body(apply_feature_write(community: community, selector: params[:room_key], feature: params[:feature]))
      end

      # Resets a room's OWN override back to inheriting the community
      # default (see {ControlPlane::FeatureControls#reset}). 404 when
      # there was no override to remove, matching ordinary
      # DELETE-on-a-missing-resource semantics rather than a silent 204.
      delete "/communities/:slug/rooms/:room_key/features/:feature" do
        community = community!(params[:slug])
        room!(community, params[:room_key])
        removed = deps.feature_controls.reset(community: community, selector: params[:room_key], feature: params[:feature])
        halt 404, yaml_body("error" => "not found") unless removed

        status 204
      end

      # Every feature's declared config shape: the same {Config::Schema}
      # the dashboard reads to build its config form, restated as data so
      # a client can learn what `config` accepts without reading source.
      # Deployment-wide: the shape is identical for every community.
      get "/features/schema" do
        yaml_body("features" => feature_catalog_payload)
      end

      # The corpus /vindicate builds: one row per content policy action an
      # operator reversed, carrying the judged text, the model's reasoning and
      # confidence, and why the operator disagreed. Read only, and deliberately
      # without an author: the samples are for rewriting a description.
      get "/communities/:slug/content-policy/misfires" do
        community = community!(params[:slug])
        rows = deps.content_policy_misfires.recent(community_id: community.id, limit: params[:limit] || 100)
        yaml_body("misfires" => rows.map { |row| content_policy_misfire_payload(row) })
      end

      delete "/communities/:slug/content-policy/misfires/:id" do
        community = community!(params[:slug])
        removed = deps.content_policy_misfires.delete(community_id: community.id, id: params[:id].to_i)
        halt 404, yaml_body("error" => "not found") unless removed
        status 204
      end

      # The word filter's custom word/phrase list and the FAQ's entries:
      # both composed over feature_controls (see {Deps}), so `all` and a
      # room_key resolve exactly as {#feature_entry!} above does. Spelled
      # out as its own route so a client need not know this is internally a feature.
      get "/communities/:slug/word-filter/entries" do
        community = community!(params[:slug])
        yaml_body("entries" => deps.word_filter_entries.list(community: community, selector: "all"))
      end

      # Whole-list replace, the one write {ControlPlane::WordFilterEntries}
      # offers for the list itself: a caller adding one word still sends the
      # complete list back, exactly as the dashboard's textarea save does.
      put "/communities/:slug/word-filter/entries" do
        community = community!(params[:slug])
        yaml_body("entries" => replace_word_filter_entries(community: community, selector: "all"))
      end

      # Addressed by the word or phrase's own value, matching
      # {ControlPlane::WordFilterEntries#remove}: there is no second id
      # scheme for these entries.
      delete "/communities/:slug/word-filter/entries" do
        community = community!(params[:slug])
        yaml_body("entries" => remove_word_filter_entry(community: community, selector: "all"))
      end

      get "/communities/:slug/rooms/:room_key/word-filter/entries" do
        community = community!(params[:slug])
        room!(community, params[:room_key])
        yaml_body("entries" => deps.word_filter_entries.list(community: community, selector: params[:room_key]))
      end

      put "/communities/:slug/rooms/:room_key/word-filter/entries" do
        community = community!(params[:slug])
        room!(community, params[:room_key])
        yaml_body("entries" => replace_word_filter_entries(community: community, selector: params[:room_key]))
      end

      delete "/communities/:slug/rooms/:room_key/word-filter/entries" do
        community = community!(params[:slug])
        room!(community, params[:room_key])
        yaml_body("entries" => remove_word_filter_entry(community: community, selector: params[:room_key]))
      end

      get "/communities/:slug/faq/entries" do
        community = community!(params[:slug])
        yaml_body("entries" => deps.faq_entries.list(community: community, selector: "all"))
      end

      # {ControlPlane::FaqEntries#add} mints the entry's stable id; this is
      # the exact call the dashboard's own "add" form drives.
      post "/communities/:slug/faq/entries" do
        community = community!(params[:slug])
        status 201
        yaml_body(add_faq_entry(community: community, selector: "all"))
      end

      # Addressed by the id {ControlPlane::FaqEntries#add} minted, never by
      # array position, matching {ControlPlane::FaqEntries#remove}.
      delete "/communities/:slug/faq/entries/:id" do
        community = community!(params[:slug])
        yaml_body("entries" => deps.faq_entries.remove(community: community, selector: "all", id: params[:id]))
      end

      get "/communities/:slug/rooms/:room_key/faq/entries" do
        community = community!(params[:slug])
        room!(community, params[:room_key])
        yaml_body("entries" => deps.faq_entries.list(community: community, selector: params[:room_key]))
      end

      post "/communities/:slug/rooms/:room_key/faq/entries" do
        community = community!(params[:slug])
        room!(community, params[:room_key])
        status 201
        yaml_body(add_faq_entry(community: community, selector: params[:room_key]))
      end

      delete "/communities/:slug/rooms/:room_key/faq/entries/:id" do
        community = community!(params[:slug])
        room!(community, params[:room_key])
        yaml_body(
          "entries" => deps.faq_entries.remove(community: community, selector: params[:room_key], id: params[:id])
        )
      end

      # The /platforms page's public join-link editor.
      get "/communities/:slug/join-links" do
        community = community!(params[:slug])
        yaml_body("join_links" => deps.platform_links.list(community: community, selector: "all"))
      end

      # Whole-list replace, the one write {ControlPlane::PlatformLinks}
      # offers: a normalized copy of whatever the caller sends, exactly the
      # dashboard's own platform[]/label[]/url[] form save.
      put "/communities/:slug/join-links" do
        community = community!(params[:slug])
        yaml_body("join_links" => replace_platform_links(community: community, selector: "all"))
      end

      get "/communities/:slug/rooms/:room_key/join-links" do
        community = community!(params[:slug])
        room!(community, params[:room_key])
        yaml_body("join_links" => deps.platform_links.list(community: community, selector: params[:room_key]))
      end

      put "/communities/:slug/rooms/:room_key/join-links" do
        community = community!(params[:slug])
        room!(community, params[:room_key])
        yaml_body("join_links" => replace_platform_links(community: community, selector: params[:room_key]))
      end

      # A developer key may read these three, but every write verb lives
      # under /admin/... instead, since creating, editing or removing a
      # platform connection, an IRC network or a Fluxer instance is closer
      # to provisioning than to day-to-day moderation.
      get "/communities/:slug/platform-connections" do
        community = community!(params[:slug])
        yaml_body("platform_connections" => deps.platform_connections.list(community: community).map { |row| platform_connection_payload(row) })
      end

      get "/communities/:slug/irc-networks" do
        community = community!(params[:slug])
        yaml_body("irc_networks" => deps.irc_networks.list(community: community).map { |row| irc_network_payload(row) })
      end

      get "/communities/:slug/irc-networks/:name" do
        community = community!(params[:slug])
        network = irc_network!(community, params[:name])
        yaml_body(irc_network_payload(network))
      end

      # Admin-only, matching the comment above: creating, editing or removing
      # an IRC network is provisioning, not a developer key's day-to-day
      # moderation.
      post "/admin/communities/:slug/irc-networks" do
        require_admin!
        community = community!(params[:slug])
        network = with_control_plane_error { deps.irc_networks.create(community: community, **irc_network_attributes) }
        status 201
        yaml_body(irc_network_payload(network))
      end

      patch "/admin/communities/:slug/irc-networks/:name" do
        require_admin!
        community = community!(params[:slug])
        existing = irc_network!(community, params[:name])
        network = with_control_plane_error do
          deps.irc_networks.update(network: existing, **irc_network_attributes(existing))
        end
        yaml_body(irc_network_payload(network))
      end

      delete "/admin/communities/:slug/irc-networks/:name" do
        require_admin!
        community = community!(params[:slug])
        network = irc_network!(community, params[:name])
        deps.irc_networks.remove(community: community, id: network.id)
        status 204
      end

      get "/communities/:slug/fluxer-instances" do
        community = community!(params[:slug])
        yaml_body("fluxer_instances" => deps.fluxer_instances.list(community: community).map { |row| fluxer_instance_payload(row) })
      end

      get "/communities/:slug/fluxer-instances/:label" do
        community = community!(params[:slug])
        instance = fluxer_instance!(community, params[:label])
        yaml_body(fluxer_instance_payload(instance))
      end

      get "/communities/:slug/guest-invites" do
        community = community!(params[:slug])
        yaml_body("guest_invites" => deps.guest_invites.list(community: community).map { |row| guest_invite_payload(row) })
      end

      get "/communities/:slug/guest-invites/:id" do
        community = community!(params[:slug])
        invite = guest_invite!(community, params[:id])
        yaml_body(guest_invite_payload(invite))
      end

      # Events are the community's own authored content, not admin
      # territory, so full CRUD stays developer-reachable; this is the
      # read half. Only upcoming, scheduled events, the same "what's
      # coming up" view the dashboard's events page reads, not the full history.
      get "/communities/:slug/rooms/:room_key/events" do
        community = community!(params[:slug])
        room = room!(community, params[:room_key])
        events = deps.event_scheduling.upcoming(community: community).select { |event| event.room_id == room.id }
        yaml_body("events" => events.map { |event| event_payload(event) })
      end

      # An API key scoped to a community may manage that community's authored
      # events. The scheduling service still checks the room's event feature;
      # the key is the trusted author for that surface, so it takes the same
      # operator path as the dashboard form.
      post "/communities/:slug/rooms/:room_key/events" do
        community = community!(params[:slug])
        room = room!(community, params[:room_key])
        given = write_body_params
        event = with_control_plane_error do
          deps.event_scheduling.create(
            community: community, room: room, as: :operator, title: given["title"],
            starts_at: given["starts_at"], ends_at: given["ends_at"], timezone: given["timezone"],
            kind: given["kind"], game_title: given["game_title"], server_address: given["server_address"],
            url: given["url"], description: given["description"],
            rsvp_mode: given.fetch("rsvp_mode", Events::Event::RSVP_NONE), created_by: actor_label,
            reminder_intervals: given["reminder_intervals"], recurrence_interval: given["recurrence_interval"]
          )
        end
        status 201
        yaml_body(event_payload(event))
      end

      get "/communities/:slug/events/:id" do
        community = community!(params[:slug])
        event = deps.event_scheduling.find(community: community, id: params[:id].to_i)
        halt 404, yaml_body("error" => "not found") if event.nil?

        yaml_body(event_payload(event))
      end

      patch "/communities/:slug/events/:id" do
        community = community!(params[:slug])
        event = deps.event_scheduling.find(community: community, id: params[:id].to_i)
        halt 404, yaml_body("error" => "not found") if event.nil?

        yaml_body(event_payload(with_control_plane_error { deps.event_scheduling.update(event: event, **event_updates) }))
      end

      delete "/communities/:slug/events/:id" do
        community = community!(params[:slug])
        event = deps.event_scheduling.cancel_by_id(community: community, id: params[:id].to_i)
        halt 404, yaml_body("error" => "not found") if event.nil?

        yaml_body(event_payload(event))
      end

      # ------------------------------------------------------------------
      # alerts
      # ------------------------------------------------------------------

      # What this community's scripts raised for its operators.
      # DEVELOPER REACHABLE, unlike everything else that touches
      # scripting: an alert holds only a sentence about this community's
      # own traffic and the raiser's name, never the script's source, hosts or credentials.

      # Newest first, never past the retention: an alert older than the
      # window is gone whether or not a sweep has run. +unseen+ rides
      # along because a monitor's real question is "is there anything to
      # look at", not something answered by re-scanning the list itself.
      get "/communities/:slug/alerts" do
        community = community!(params[:slug])
        rows = deps.alerts.recent(community_id: community.id, limit: alert_limit)
        yaml_body(
          "alerts" => rows.map { |row| alert_payload(row) },
          "unseen" => deps.alerts.unseen_count(community_id: community.id)
        )
      end

      # Mark one seen, and answer with the row so a client sees the
      # marker it just set without a second call. The lookup is scoped,
      # so an id belonging to another community 404s exactly as a
      # nonexistent one does; marking an already-seen alert is a 200 no-op.
      post "/communities/:slug/alerts/:id/seen" do
        community = community!(params[:slug])
        row = alert!(community, params[:id])
        deps.alerts.mark_seen(id: row.id, community_id: community.id)
        yaml_body(alert_payload(row.refresh))
      end

      # The whole outstanding backlog at once, for the client coming back to one
      # it has already dealt with somewhere else.
      post "/communities/:slug/alerts/seen" do
        community = community!(params[:slug])
        yaml_body("marked" => deps.alerts.mark_all_seen(community_id: community.id))
      end

      # ------------------------------------------------------------------
      # room games
      # ------------------------------------------------------------------

      # DEVELOPER REACHABLE, same reasoning as alerts above: a session
      # holds only the name of what a script called it and its open
      # round, never the script's source. The harness itself keeps no
      # scoreboard beyond that.
      get "/communities/:slug/rooms/:room_key/participation" do
        community = community!(params[:slug])
        room = room!(community, params[:room_key])
        yaml_body(
          "session" => deps.participation.session(community: community, room_key: room.room_key),
          "round" => deps.participation.round(community: community, room_key: room.room_key)
        )
      end

      # Closes the session and whatever round is open inside it. A room with
      # nothing running answers the same refusal a script's own
      # close_session call gets.
      post "/communities/:slug/rooms/:room_key/participation/close" do
        community = community!(params[:slug])
        room = room!(community, params[:room_key])
        result = deps.participation.close_session(community: community, room_key: room.room_key)
        halt 422, yaml_body("error" => result[1]) unless result == true

        yaml_body("closed" => true)
      end

      # The same aggregate view ControlPlane::Analytics already computes for
      # the dashboard's overview page, read straight off it so the two can
      # never disagree. Admin-only: this spans moderation, membership and
      # guest activity a developer key has no business seeing in aggregate.

      # ------------------------------------------------------------------
      # scripts, the endpoints they call, and the numbers they record
      # ------------------------------------------------------------------

      # Admin only, all of it, matching the dashboard: a script is code this
      # deployment runs and an endpoint decides which hosts it reaches, so
      # neither is a developer key's business even within its own community.

      get "/admin/communities/:slug/scripts" do
        require_admin!
        community = community!(params[:slug])
        yaml_body("scripts" => deps.scripts.list(community).map { |row| script_row(row, community) })
      end

      get "/admin/communities/:slug/scripts/archived" do
        require_admin!
        community = community!(params[:slug])
        yaml_body("scripts" => deps.scripts.list(community, archived: true)
                                           .map { |row| script_row(row, community) })
      end

      get "/admin/communities/:slug/scripts/:id" do
        require_admin!
        community = community!(params[:slug])
        yaml_body(script_row(script!(community, params[:id]), community))
      end

      post "/admin/communities/:slug/scripts" do
        require_admin!
        community = community!(params[:slug])
        row = with_script_error do
          deps.scripts.save(community: community, **script_attributes, created_by: "api")
        end
        status 201
        yaml_body(script_row(row, community))
      end

      patch "/admin/communities/:slug/scripts/:id" do
        require_admin!
        community = community!(params[:slug])
        existing = script!(community, params[:id])
        row = with_script_error do
          deps.scripts.save(community: community, id: existing.id, **script_attributes(existing))
        end
        yaml_body(script_row(row, community))
      end

      delete "/admin/communities/:slug/scripts/:id" do
        require_admin!
        community = community!(params[:slug])
        deps.scripts.archive(community, script!(community, params[:id]).id)
        status 204
      end

      post "/admin/communities/:slug/scripts/:id/restore" do
        require_admin!
        community = community!(params[:slug])
        yaml_body(script_row(deps.scripts.restore(community, script!(community, params[:id]).id), community))
      end

      post "/admin/communities/:slug/scripts/:id/verify" do
        require_admin!
        community = community!(params[:slug])
        result = with_script_error { deps.scripts.verify(community, script!(community, params[:id]).id) }
        yaml_body("ok" => result.ok?, "problems" => result.ok? ? [] : result.to_s)
      end

      post "/admin/communities/:slug/scripts/:id/enable" do
        require_admin!
        community = community!(params[:slug])
        row = with_script_error { deps.scripts.enable(community, script!(community, params[:id]).id) }
        yaml_body(script_row(row, community))
      end

      post "/admin/communities/:slug/scripts/:id/disable" do
        require_admin!
        community = community!(params[:slug])
        yaml_body(script_row(deps.scripts.disable(community, script!(community, params[:id]).id), community))
      end

      # What went wrong when this script last ran, and what went wrong
      # before that: the error counter and circuit breaker state come
      # back with the history. Text is truncated at the source, since a
      # script is free to build an error out of a message it was handed.
      get "/admin/communities/:slug/scripts/:id/errors" do
        require_admin!
        community = community!(params[:slug])
        yaml_body(script_errors(script!(community, params[:id])))
      end

      # What a script may be: the kinds, the conditions and the dialects this
      # deployment can actually compile, so a client does not hardcode a list
      # that depends on which transpilers are installed.
      get "/admin/scripting/capabilities" do
        require_admin!
        yaml_body(
          "kinds" => ControlPlane::Scripts::KINDS.map { |k| { "kind" => k, "label" => ControlPlane::Scripts::KIND_LABELS[k] } },
          "conditions" => Scripting::Triggers::TYPES.map do |type|
            { "condition" => type.type_name, "summary" => type.summary,
              "fields" => type.fields, "hands_over" => type.hands_over }
          end,
          "languages" => Scripting::Dialects.available_names,
          "limits" => { "scripts_per_community" => ControlPlane::Scripts::MAX_SCRIPTS,
                        "host_calls_per_invocation" => Scripting::Registry::DEFAULT_MAX_CALLS,
                        "yaml_data_bytes" => ControlPlane::Scripts::MAX_YAML_BYTES }
        )
      end

      get "/admin/communities/:slug/endpoints" do
        require_admin!
        community = community!(params[:slug])
        yaml_body("endpoints" => deps.script_endpoints.list(community).map { |row| endpoint_row(row) })
      end

      get "/admin/communities/:slug/endpoints/:id" do
        require_admin!
        community = community!(params[:slug])
        yaml_body(endpoint_row(endpoint!(community, params[:id])))
      end

      post "/admin/communities/:slug/endpoints" do
        require_admin!
        community = community!(params[:slug])
        row = with_script_error { deps.script_endpoints.save(community: community, **endpoint_attributes) }
        status 201
        yaml_body(endpoint_row(row))
      end

      patch "/admin/communities/:slug/endpoints/:id" do
        require_admin!
        community = community!(params[:slug])
        existing = endpoint!(community, params[:id])
        row = with_script_error do
          deps.script_endpoints.save(community: community, id: existing.id, **endpoint_attributes(existing))
        end
        yaml_body(endpoint_row(row))
      end

      delete "/admin/communities/:slug/endpoints/:id" do
        require_admin!
        community = community!(params[:slug])
        deps.script_endpoints.delete(community, endpoint!(community, params[:id]).id)
        status 204
      end

      # Where a community wants its events sent, and what happened to
      # every attempt at sending one. Admin only, all of it: a
      # subscription forwards a community's rooms to an address outside
      # the deployment and carries a signing secret, like issuing an API key.
      get "/admin/communities/:slug/webhooks" do
        require_admin!
        community = community!(params[:slug])
        yaml_body("webhooks" => deps.webhooks.list(community_id: community.id)
                                    .map { |row| webhook_payload(row) })
      end

      get "/admin/communities/:slug/webhooks/:public_id" do
        require_admin!
        community = community!(params[:slug])
        yaml_body(webhook_payload(webhook!(community, params[:public_id])))
      end

      # The one response that carries the signing secret, along with
      # rotate below. The secret is recoverable by construction (the HMAC
      # is computed from it, so it cannot be hashed like an API key);
      # returning it only here keeps it out of every routine listing.
      post "/admin/communities/:slug/webhooks" do
        require_admin!
        community = community!(params[:slug])
        given = write_body_params
        created = with_webhook_error do
          deps.webhooks.create(
            community_id: community.id, url: given["url"],
            event_types: given["event_types"], room_key: given["room_key"].to_s,
            label: given["label"].to_s
          )
        end
        status 201
        yaml_body(webhook_payload(created.row).merge("secret" => created.secret))
      end

      # Mint a new signing secret, keeping the old one valid for a while:
      # until it lapses, a delivery carries both signatures, so the
      # subscriber can deploy the new one on their own schedule. An
      # overlap of 0 retires the old secret at once, for a leaked one.
      post "/admin/communities/:slug/webhooks/:public_id/rotate" do
        require_admin!
        community = community!(params[:slug])
        webhook!(community, params[:public_id])
        given = write_body_params
        overlap = given.key?("overlap") ? given["overlap"].to_i : ControlPlane::Webhooks::DEFAULT_OVERLAP
        rotated = with_webhook_error do
          deps.webhooks.rotate(community_id: community.id, public_id: params[:public_id], overlap: overlap)
        end
        yaml_body(webhook_payload(rotated.row.refresh).merge("secret" => rotated.secret))
      end

      delete "/admin/communities/:slug/webhooks/:public_id" do
        require_admin!
        community = community!(params[:slug])
        webhook!(community, params[:public_id])
        deps.webhooks.delete(community_id: community.id, public_id: params[:public_id])
        status 204
      end

      # What actually happened, which is the half of this feature that did not
      # exist before: a durable job failing said so in a log nobody reads, and
      # never said which subscriber missed which event.
      get "/admin/communities/:slug/webhook-deliveries" do
        require_admin!
        community = community!(params[:slug])
        subscription = params[:webhook] && webhook!(community, params[:webhook])
        rows = deps.webhooks.deliveries(
          community_id: community.id, status: params[:status],
          subscription_id: subscription&.id, limit: (params[:limit] || 200)
        )
        yaml_body("deliveries" => rows.map { |row| webhook_delivery_payload(row) })
      end

      # ------------------------------------------------------------------
      # files
      # ------------------------------------------------------------------

      # Files this deployment holds on a community's behalf: listing,
      # uploading, rotating a link, and marking for deletion, admin only
      # throughout. The UUID that names a file is never stored (only its
      # digest is), so losing it loses read access, though DELETE still works.

      get "/admin/communities/:slug/files" do
        require_admin!
        community = community!(params[:slug])
        yaml_body("files" => file_store!.list(community_id: community.id).map { |row| file_payload(row) })
      end

      get "/admin/communities/:slug/files/:id" do
        require_admin!
        community = community!(params[:slug])
        yaml_body(file_payload(rehosted_file!(community, params[:id])))
      end

      # Put a file into the store and answer with the UUID that names it:
      # the one route in this app that takes a multipart body, since
      # bytes riding YAML would blow up memory at both ends. The UUID
      # comes back once, here, never stored and never askable for again.
      post "/admin/communities/:slug/files" do
        require_admin!
        community = community!(params[:slug])
        files = file_store!
        upload = params[:file]
        halt 422, yaml_body("error" => "no file was sent") unless upload.is_a?(Hash) && upload[:tempfile]

        policy = files.policy_for(community_id: community.id, room_key: params[:room_key])
        unless policy[:enabled]
          halt 422, yaml_body("error" => "this community is not accepting files")
        end

        stored = with_file_error do
          files.store_file(
            community_id: community.id, room_key: params[:room_key], source: upload[:tempfile],
            filename: upload[:filename], content_type: upload[:type],
            ttl_days: policy[:retention_days], limit: policy[:max_bytes],
            origin: "upload", created_by: "api:#{current_key.public_id}"
          )
        end
        status 201
        yaml_body(stored_file_payload(stored))
      end

      # Mint a new link for a file, which means genuinely re-encrypting
      # it: unsealed with the old secret and streamed back out under a
      # new one, so the old link stops working the moment this answers.
      # Slow, in proportion to the file; only who can reach it changes.
      post "/admin/communities/:slug/files/rotate" do
        require_admin!
        community = community!(params[:slug])
        secret = file_secret!
        rotated = with_file_error do
          file_store!.rotate(secret: secret, community_id: community.id)
        end
        # A UUID that names nothing live, and one naming another community's
        # file, answer identically. Anything else would turn this into an oracle
        # for whether a guessed link is real.
        halt 404, yaml_body("error" => "not found") if rotated.nil?

        yaml_body(stored_file_payload(rotated))
      end

      # Mark a file for deletion on the next reclaim sweep. Needs no key
      # material, unlike rotation: the digest of the supplied UUID finds
      # the row. The link stops working immediately, since a download
      # only resolves a file whose expiry is still ahead; bytes go later.
      post "/admin/communities/:slug/files/expire" do
        require_admin!
        community = community!(params[:slug])
        secret = file_secret!
        row = file_store!.mark_expired(secret: secret, community_id: community.id)
        halt 404, yaml_body("error" => "not found") if row.nil?

        yaml_body(file_payload(row))
      end

      # The same thing for a file whose UUID nobody has any more: a
      # listing hands back row ids and no links, so this is the only way
      # to act once the UUID is gone. Safe by id since expiry touches no
      # key material; rotation has no id twin, since that needs the secret.
      delete "/admin/communities/:slug/files/:id" do
        require_admin!
        community = community!(params[:slug])
        row = file_store!.expire_by_id(community_id: community.id, id: params[:id])
        halt 404, yaml_body("error" => "not found") if row.nil?

        yaml_body(file_payload(row))
      end

      # The numbers scripts recorded. Read only over the API: writing one is
      # something a script does, not something a client does on its behalf.
      get "/admin/communities/:slug/script-stats" do
        require_admin!
        community = community!(params[:slug])
        yaml_body("stats" => deps.script_stats.report(community))
      end

      get "/admin/communities/:slug/stats" do
        require_admin!
        community = community!(params[:slug])
        yaml_body(deps.analytics.overview(community: community))
      end

      # source is "web" (default), "bot", or "all". info covers version,
      # build commit and platform, over Core::BuildInfo; a bot source
      # only reports reachability (fetching one log entry over the same
      # hop #debug_logs uses), since both processes share one image.
      get "/admin/debug/info" do
        require_admin!
        source = debug_source!
        info = {}
        info["web"] = web_process_info if %w[web all].include?(source)
        info["bot"] = bot_process_info if %w[bot all].include?(source)
        yaml_body(info)
      end

      # source=all merges both processes' entries into ONE
      # timestamp-sorted list, each tagged its own "source", so a caller
      # sees what happened in order without merging itself. An
      # unreachable bot is reported under "errors", never silently as "nothing happened".
      get "/admin/debug/logs" do
        require_admin!
        source = debug_source!
        level = params[:level]
        limit = params[:limit]
        entries = []
        errors = {}

        if %w[web all].include?(source)
          if deps.log_buffer.nil?
            errors["web"] = "this process has no log buffer configured"
          else
            entries.concat(deps.log_buffer.entries(level: level, limit: limit).map { |e| debug_log_entry(e, "web") })
          end
        end

        if %w[bot all].include?(source)
          result = deps.bot_logs.fetch(level: level, limit: limit)
          if result.ok?
            entries.concat(result.entries.map { |e| debug_log_entry(e, "bot") })
          else
            errors["bot"] = result.error
          end
        end

        entries.sort_by! { |e| e["time"] || "" }
        entries = entries.last(limit.to_i) if limit && source == "all"

        body = { "entries" => entries }
        body["errors"] = errors unless errors.empty?
        yaml_body(body)
      end

      # The read-only backfill-gap sweep, run on the bot process (the
      # only one holding adapters) and relayed here over the same
      # internal hop debug/logs uses. An unreachable bot is reported
      # under "errors", never as an empty list misread as "no gaps".
      get "/admin/debug/backfill-gaps" do
        require_admin!
        yaml_body(backfill_gaps_payload)
      end

      # ----------------------------------------------------------------
      # backfill proposals: what a sweep held back, waiting on a person
      # ----------------------------------------------------------------

      # The API half of the dashboard's Backfill proposals page, over
      # {ControlPlane::BackfillProposals}. Administrator only throughout:
      # a proposal names channels across a community, and accepting one
      # posts real messages into a live room.

      # Every proposal in one state, freshest first, with the counts the
      # sweep recorded. `ours` rides the list for a reason: it is how
      # many fetched messages the sweep recognised as this bridge's own
      # and skipped, so a zero on a months-old channel flags a broken check.
      get "/admin/backfill-proposals" do
        require_admin!
        rows = backfill_proposals_in_state
        communities = communities_by_id(rows)
        yaml_body("backfill_proposals" => rows.map { |row| backfill_proposal_payload(row, communities) })
      end

      # One proposal and the messages it would send. The previews live only
      # while the proposal still needs them, so a decided or expired one reads
      # as pruned rather than as an empty list, which would look like the
      # sweep had been about to send nothing.
      get "/admin/backfill-proposals/:id" do
        require_admin!
        yaml_body(backfill_proposal_detail(backfill_proposal!(params[:id])))
      end

      # Accept one channel's list: the service stamps it approved and
      # hands back the stored items, nothing here recomputes what to
      # send. This process holds no adapters, so the same push the
      # dashboard's Accept button sends is what makes it go out.
      post "/admin/backfill-proposals/:id/approve" do
        require_admin!
        row = backfill_proposal!(params[:id])
        community = backfill_proposal_community!(row)
        items = deps.backfill_proposals.approve(community: community, proposal_id: row[:id],
                                                decided_by: actor_label)
        yaml_body(backfill_approval_payload(community, row[:id], items.length))
      end

      # Refuse one channel's list. The previews go with the decision, so
      # nothing of what would have been sent survives the call.
      post "/admin/backfill-proposals/:id/reject" do
        require_admin!
        row = backfill_proposal!(params[:id])
        community = backfill_proposal_community!(row)
        deps.backfill_proposals.reject(community: community, proposal_id: row[:id], decided_by: actor_label)
        decided = deps.backfill_proposals.find(community: community, proposal_id: row[:id])
        yaml_body("backfill_proposal" => backfill_proposal_payload(decided))
      end

      # One handler for every control-plane service's Invalid (they all
      # descend from Rubotty::Error), turning it into a YAML error body
      # instead of a 500. A machine client gets one predictable failure
      # shape, regardless of which resource raised it.
      error Rubotty::Error do
        content_type "application/yaml"
        status 422
        yaml_body("error" => env["sinatra.error"].message)
      end

      helpers do
        def deps = settings.deps

        def models = settings.deps.models

        def current_key = @api_key

        def administrator? = current_key.scope == ControlPlane::ApiKeys::SCOPE_ADMINISTRATOR

        # Resolve the bearer token into a live key, or halt. Runs on every
        # request but {#healthz}; stamps last_used_at and records against the
        # rate limiter on every successful authentication, so a key's
        # dashboard listing and budget both reflect this request even if the
        # route itself goes on to fail.
        def authenticate!
          return if revalidate_guarded_key!

          token = bearer_token
          halt 401, yaml_body("error" => "missing or malformed Authorization header") if token.nil?

          key = deps.api_keys.authenticate(token: token)
          halt 401, yaml_body("error" => "invalid or revoked API key") if key.nil?

          unless deps.rate_limiter.allow?(key)
            headers "Retry-After" => deps.rate_limiter.retry_after.to_s
            halt 429, yaml_body("error" => "rate limit exceeded")
          end

          deps.rate_limiter.record!(key)
          deps.api_keys.touch_last_used(key)
          @api_key = key
        end

        # Form parsing happens before the filter; JSON/YAML parsing happens in
        # write_body_params. Re-check after either phase without a second rate
        # charge or last-used write, so revocation during input is effective.
        def revalidate_guarded_key!
          claim = request.env[RequestGuard::CLAIM_KEY]
          return false unless claim.is_a?(Hash) && settings.respond_to?(:request_guard_marker) &&
                              claim[:marker].equal?(settings.request_guard_marker)

          key = deps.api_keys.authenticate(token: claim[:token])
          halt 401, yaml_body("error" => "invalid or revoked API key") if key.nil?

          @api_key = key
          true
        end

        # Charge one request against the key holding an open stream. Swallows
        # its own errors: losing a meter tick must not drop somebody's stream.
        def meter_stream(key)
          deps.rate_limiter.record!(key) if key
        rescue StandardError
          nil
        end

        # Whether the key an open stream was opened with is still good. Fails
        # closed: an error reading it ends the stream rather than extending it.
        def stream_key_live?(token)
          return false if token.nil?

          !deps.api_keys.authenticate(token: token).nil?
        rescue StandardError
          false
        end

        def bearer_token
          header = request.env["HTTP_AUTHORIZATION"].to_s
          match = header.match(/\ABearer\s+(.+)\z/i)
          match && match[1]
        end

        # Halt 403 unless the current key is an administrator, for routes
        # under /admin/... only. A route-class failure, never a
        # resource-level one, so it never depends on which slug (if any) the
        # route also names.
        def require_admin!
          halt 403, yaml_body("error" => "administrator scope required") unless administrator?
        end

        # The community row for a slug, scoped to what the current key may
        # see: an administrator key resolves any slug, a developer key only
        # its own. Both an unknown slug and one outside the key's scope halt
        # with the same 404, never a 403, so a developer key can never learn
        # that another community's slug exists.
        def community!(slug)
          row = deps.community(slug)
          halt 404, yaml_body("error" => "not found") if row.nil?
          halt 404, yaml_body("error" => "not found") if !administrator? && current_key.community_id != row.id

          row
        end

        # Who a write is recorded as having been made by. The key's public id
        # rather than its label, since a label is editable and two keys may
        # share one, and never the token.
        def actor_label = "api:#{current_key.public_id}"

        # A trimmed string, or nil when it was blank or absent. Halts on a
        # YAML boolean first (see {#reject_yaml_boolean!}), since every field
        # routed through here is documented as free text and none of them
        # means to accept true or false.
        def presence(value)
          reject_yaml_boolean!(value)
          string = value.to_s.strip
          string.empty? ? nil : string
        end

        # YAML 1.2 resolves only true and false, so a bare yes, no, on or off
        # arrives as the string it was written as; what reaches here is
        # therefore a client that really did send a boolean where the field
        # is documented as free text. Halts rather than stringifying it,
        # which would keep the literal text "true" or "false" with no record
        # that anything was wrong.
        def reject_yaml_boolean!(value)
          return unless value == true || value == false

          halt 400, yaml_body(
            "error" => "expected a string, got a YAML boolean; quote it to send the word instead"
          )
        end

        # The wire representation of a community row, string-keyed so it
        # reads the same whether a client decodes it with a YAML library's
        # default symbolize_names: false or true.
        def community_payload(community)
          {
            "slug" => community.slug,
            "name" => community.name,
            "status" => community.status,
            "created_at" => community.created_at.to_s
          }
        end

        # The room row for a room_key within +community+, or a clean 404.
        # Scoped to the community for the same reason {#community!} scopes a
        # slug: a room_key is unique only within one community (migration
        # 001's rooms_key_idx), never globally.
        def room!(community, room_key)
          row = community.rooms_dataset.where(room_key: room_key.to_s).first
          halt 404, yaml_body("error" => "not found") if row.nil?

          row
        end

        # The message-map ref a meta-level react/edit/delete addresses: the
        # room's own synthetic API endpoint plus the id POST .../messages
        # minted, already scoped to the caller's own community by {#room!}
        # so this can never be pointed at another community's message by
        # guessing an id. Halts 404 when the map holds no copy of it,
        # refusing to queue an action that would land nowhere, whether the
        # id is made up, belongs to a different room, or has aged out of the
        # map's TTL.
        def meta_message!(room, message_id)
          halt 404, yaml_body("error" => "not found") if deps.storage.nil?

          ref = Core::MessageRef.new(Adapters::Api.endpoint_key_for(room.id), message_id.to_s)
          halt 404, yaml_body("error" => "not found") if deps.storage.counterparts(ref).empty?

          ref
        end

        # The channel row for an endpoint_key within +community+, or a clean
        # 404. endpoint_key is globally unique on its own (it is the message
        # map's join key, see migration 001), but the lookup still scopes to
        # +community+ so a developer key cannot reach another community's
        # channel by guessing its key.
        def channel!(community, endpoint_key)
          row = community.channels_dataset.where(endpoint_key: endpoint_key.to_s).first
          halt 404, yaml_body("error" => "not found") if row.nil?

          row
        end

        # The channel row a /bridge route addresses: this key's own
        # platform_account, scoped to +community+, matched against the
        # REMOTE system's own channel_id (route_key, migration 001),
        # never rubotty's endpoint_key. An ordinary key with no
        # platform_account, a key naming another community's slug, an
        # unconfigured channel_id, and a channel on a different
        # api_wrapper account are all the SAME clean 404, never a 403,
        # matching {#community!}'s reasoning: none should leak why.
        def bridge_channel!(community, channel_id)
          account = current_key.platform_account
          halt 404, yaml_body("error" => "not found") if account.nil?

          row = community.channels_dataset.where(
            adapter: "api_wrapper", account: account, route_key: channel_id.to_s
          ).first
          halt 404, yaml_body("error" => "not found") if row.nil?

          row
        end

        # The real author identity a /bridge call carries: native id, display
        # name and avatar, the fields Author needs on inbound. Absence stays
        # nil, never "", matching {#presence}'s own reasoning throughout this
        # file.
        def bridge_author(given)
          author = given["author"].is_a?(Hash) ? given["author"] : {}
          { native_id: presence(author["id"]), display_name: presence(author["name"]),
            avatar_url: presence(author["avatar_url"]) }
        end

        # The member a join or leave is about. Unlike {#bridge_author}, which
        # tolerates an anonymous actor because the message itself is the point,
        # this refuses one: a membership event naming nobody says only that
        # somebody somewhere came or went, which no room can render.
        def bridge_member!(given)
          author = bridge_author(given)
          halt 422, yaml_body("error" => "author.id is required") if author[:native_id].nil?

          author
        end

        def bridge_attachments(given)
          hashes = Array(given["attachments"]).select { |a| a.is_a?(Hash) }
                                              .first(ControlPlane::ApiWrapperEvents::MAX_ATTACHMENTS)
          hashes.filter_map do |a|
            url = presence(a["url"])
            next nil if url.nil?

            { url: url, filename: presence(a["filename"]), mime_type: presence(a["mime_type"]),
              kind: presence(a["kind"]), caption: presence(a["caption"]) }
          end
        end

        def bridge_reaction(given)
          reaction = given["reaction"].is_a?(Hash) ? given["reaction"] : {}
          { emoji: presence(reaction["emoji"]), custom_id: presence(reaction["custom_id"]),
            custom_name: presence(reaction["custom_name"]) }
        end

        def room_payload(room)
          {
            "room_key" => room.room_key,
            "label" => room.label,
            "channels" => room.channels.map(&:endpoint_key)
          }
        end

        def channel_payload(channel)
          {
            "endpoint_key" => channel.endpoint_key,
            "adapter" => channel.adapter,
            "account" => channel.account,
            "label" => channel.label,
            "receives" => channel.receives,
            "sends" => channel.sends
          }
        end

        # The person row for an id within +community+, or a clean 404, the
        # same community-scoping reasoning as {#room!} and {#channel!}.
        def person!(community, id)
          row = community.people_dataset.where(id: id.to_i).first
          halt 404, yaml_body("error" => "not found") if row.nil?

          row
        end

        # The operator_request row for an id within +community+, or a clean
        # 404, the same reasoning as {#person!}.
        def operator_request!(community, id)
          row = community.operator_requests_dataset.where(id: id.to_i).first
          halt 404, yaml_body("error" => "not found") if row.nil?

          row
        end

        # @param nicknames [Hash] adapter => the name they are bridged as there
        def person_payload(person, nicknames)
          {
            "id" => person.id,
            "name" => person.name,
            "identities" => person.person_identities.map do |identity|
              { "adapter" => identity.adapter, "native_id" => identity.native_id, "username" => identity.username }
            end,
            "nicknames" => nicknames
          }
        end

        # What one person is bridged as, keyed by the platform it is shown on.
        def nicknames_of(community, person)
          deps.bridged_nicknames.for_person(community_id: community.id, person_id: person.id)
        end

        # Halt when this community hands out no nicknames at all, read through
        # the same fallback the chat command itself applies, so the API can
        # never set one the command would have refused.
        def refuse_when_nicknames_are_off!(community)
          row = deps.feature_controls.list(community, selector: "all").find { |entry| entry[:feature] == "nickname" }
          return unless Features::Nickname.who_can_set(row ? row[:config] : {}) == Features::Nickname::WHO_NOBODY

          halt 422, yaml_body("error" => "nicknames are not being handed out in this community")
        end

        # A granted row. "baked_in" and "removable" say out loud which source
        # this entry came from and what the revoke route will do with it, so a
        # client reading one list never has to infer either.
        def operator_payload(operator)
          {
            "id" => operator.id,
            "person" => operator.person.name,
            "actions" => operator.json_value(:actions),
            "scope" => operator.json_value(:scope),
            "granted_at" => operator.granted_at.to_s,
            "granted_by" => operator.granted_by,
            "baked_in" => false,
            "removable" => true
          }
        end

        # One entry from the floor the deployment ships with. It carries no id
        # and no grant record, because there is no row: it is owner-level here
        # and in every other community by virtue of the handle alone.
        def baked_in_operator_payload(entry)
          {
            "handle" => entry[:handle].to_s,
            "kind" => entry[:kind].to_s,
            "actions" => "all",
            "scope" => "all",
            "baked_in" => true,
            "removable" => false
          }
        end

        # The channels a non-operator's /identify-topic named here, oldest
        # first, still waiting on a decision.
        def suggested_channels(community)
          models.channel.where(community_id: community.id, suggested: true).order(:id).all
        end

        # One of them by id, or a clean 404. Scoped to the community and to the
        # suggested flag together, so neither another community's channel nor
        # an already-settled one is reachable by guessing an id.
        def suggested_channel!(community, id)
          row = models.channel.where(community_id: community.id, suggested: true, id: id.to_i).first
          halt 404, yaml_body("error" => "not found") if row.nil?

          row
        end

        # A suggestion reads as an ordinary channel plus the id the approve and
        # reject routes address it by.
        def suggested_channel_payload(channel)
          channel_payload(channel).merge("id" => channel.id)
        end

        # The write half of the wire-format promise (see the module comment):
        # a request body accepts form encoding, +application/yaml+ or JSON.
        # Rack parses form encoding into +params+; YAML and JSON bodies are
        # decoded here and memoised per request.
        #
        # @return [Hash] string-keyed
        def write_body_params
          return @write_body_params if defined?(@write_body_params)

          @write_body_params =
            if request.content_type.to_s.start_with?("application/json")
              # Parsed rather than ignored. Sinatra does not read a JSON body
              # into params, so this used to fall through to the branch below,
              # find nothing, write nothing, and answer 200 with the row it had
              # just re-read, which reads exactly like a confirmation (#1915).
              raw = begin
                JSON.parse(request.body.read.to_s)
              rescue JSON::ParserError => e
                halt 400, yaml_body("error" => "could not read the JSON body: #{e.message.lines.first.to_s.strip}")
              end
              halt 400, yaml_body("error" => "request body must be a JSON object") unless raw.nil? || raw.is_a?(Hash)
              (raw || {}).transform_keys(&:to_s)
            elsif request.content_type.to_s.start_with?("application/yaml")
              # Read once and hold the result rather than rewinding first: Rack
              # does not promise a rewindable input, and WEBrick's (the handler
              # this app actually ships on) has no #rewind at all.
              raw = begin
                YAMLCamel.load(request.body.read.to_s)
              rescue YAMLCamel::Error => e
                # A body carrying a Ruby specific type, or simply broken, is
                # the client's mistake and reads as one. It used to reach
                # Sinatra as an unhandled error and answer 500.
                halt 400, yaml_body("error" => "could not read the YAML body: #{e.message.lines.first.to_s.strip}")
              end
              halt 400, yaml_body("error" => "request body must be a YAML mapping") unless raw.nil? || raw.is_a?(Hash)
              (raw || {}).transform_keys(&:to_s)
            else
              skip = route_path_names + %w[splat captures]
              params.each_with_object({}) do |(key, value), acc|
                acc[key.to_s] = value unless skip.include?(key.to_s)
              end
            end
          # Rack did not read these formats into params before authenticate!.
          if request.content_type.to_s.start_with?("application/json", "application/yaml")
            revalidate_guarded_key!
          end
          @write_body_params
        end

        # The names THIS route takes from its own path, so a form field
        # cannot shadow a path segment. Read off the route rather than a
        # fixed list: the fixed list held room_key unconditionally, but the
        # webhook create route reads it as a real field, so over form
        # encoding it was always dropped and the subscription silently
        # widened to every room.
        FALLBACK_PATH_NAMES = %w[slug feature room_key].freeze

        def route_path_names
          route = request.env["sinatra.route"].to_s
          return FALLBACK_PATH_NAMES if route.empty?

          route.scan(/:([A-Za-z_][A-Za-z0-9_]*)/).flatten
        end

        # One misfire on the wire. `acted_at` is when the policy fired and
        # `created_at` when somebody called it wrong, which are different
        # moments and both worth having when reading a run of them.
        def content_policy_misfire_payload(row)
          {
            "id" => row.id, "kind" => row.kind, "policy" => row.policy, "action" => row.action,
            "adapter" => row.adapter, "endpoint_id" => row.endpoint_id,
            "body" => row.body, "reasoning" => row.reasoning,
            "confidence" => row.confidence, "statement" => row.statement,
            "context" => misfire_context(row),
            "reversed_by" => row.reversed_by,
            "acted_at" => row.acted_at, "created_at" => row.created_at
          }
        end

        # The room the message was judged in, as structure rather than as the
        # JSON string the column holds, since everything else here is read as
        # YAML. Older rows predate the column and simply have none.
        def misfire_context(row)
          raw = row.context.to_s
          return nil if raw.empty?

          JSON.parse(raw)
        rescue JSON::ParserError
          nil
        end

        # A body's `enabled` value read as a boolean, accepting both a form
        # body's string ("true"/"1") and a YAML body's native boolean.
        def truthy_param?(value)
          [true, "true", "1", 1].include?(value)
        end

        # Applies a PATCH body to one feature scope: `enabled` (if present)
        # via {ControlPlane::FeatureControls#enable}/`#disable`, then every
        # `config` key (if present) via {ControlPlane::FeatureControls#set},
        # one call per key, the exact same path a `rubotty feature set` call
        # takes for each. Returns the resulting {#feature_payload}, so a
        # client sees the row it just wrote without a second GET.
        def apply_feature_write(community:, selector:, feature:)
          body = write_body_params
          config = body["config"]
          halt 400, yaml_body("error" => "config must be a mapping") unless config.nil? || config.is_a?(Hash)
          # A refused config key must roll back every earlier key and the toggle.
          deps.db.transaction do
            if body.key?("enabled")
              if truthy_param?(body["enabled"])
                deps.feature_controls.enable(community: community, selector: selector, feature: feature)
              else
                deps.feature_controls.disable(community: community, selector: selector, feature: feature)
              end
            end
            (config || {}).each do |key, value|
              deps.feature_controls.set(community: community, selector: selector, feature: feature, key: key, value: value)
            end
          end
          feature_payload(feature_entry!(community, selector: selector, feature: feature))
        end

        # The wire representation of one entry in {#feature_catalog_payload},
        # every field {Features::Catalog} exposes for one feature name.
        def feature_schema_payload(name)
          schema = Features::Catalog.config_schema(name)
          {
            "name" => name,
            "description" => Features::Catalog.description(name),
            "retention_notice" => Features::Catalog.retention_notice(name),
            "config_schema" => schema ? schema.fields.values.map { |field| config_field_payload(field) } : []
          }
        end

        # Every known feature, restated as data for `GET /features/schema`.
        # +.uniq+ because a name may cover several classes
        # ({Features::Catalog}'s own comment on why); this catalog lists
        # each name once.
        def feature_catalog_payload
          Features::Catalog.names.uniq.sort.map { |name| feature_schema_payload(name) }
        end

        # One {Config::Schema::Field}, restated as a plain Hash. +default+ and
        # +one_of+ pass through {#plain_scalar} because a `:symbol`-typed
        # field's default and permitted values are real Ruby Symbols (see
        # Bridge's `reaction_notices`), and this app never puts a Ruby-specific
        # value on the wire.
        def config_field_payload(field)
          {
            "name" => field.name.to_s,
            "type" => field.type.to_s,
            "required" => !!field.required,
            "default" => plain_scalar(field.default),
            "one_of" => field.one_of&.map { |value| plain_scalar(value) },
            "description" => field.description
          }
        end

        def plain_scalar(value)
          value.is_a?(Symbol) ? value.to_s : value
        end

        # The body's `entries` for a word-filter whole-list PUT, or a 400: the
        # list itself is the entire body {ControlPlane::WordFilterEntries#replace}
        # takes, so there is nothing to merge and nothing partial to accept.
        def replace_word_filter_entries(community:, selector:)
          entries = write_body_params["entries"]
          halt 400, yaml_body("error" => "entries must be a list") unless entries.is_a?(Array)

          deps.word_filter_entries.replace(community: community, selector: selector, entries: entries)
        end

        # {ControlPlane::WordFilterEntries#remove} itself refuses a value that
        # is not in the list (see its own Invalid), so there is nothing to
        # check here beyond reading the body.
        def remove_word_filter_entry(community:, selector:)
          deps.word_filter_entries.remove(community: community, selector: selector, value: write_body_params["value"])
        end

        # The body's `trigger`/`response`/`trigger_type` for a FAQ add, handed
        # straight to {ControlPlane::FaqEntries#add}, which is the one place
        # that validates them and mints the entry's id.
        def add_faq_entry(community:, selector:)
          body = write_body_params
          deps.faq_entries.add(community: community, selector: selector, trigger: body["trigger"],
                               response: body["response"], trigger_type: body["trigger_type"])
        end

        # The body's `join_links` for a join-link whole-list PUT, or a 400.
        # {ControlPlane::PlatformLinks#replace} normalizes on the way in, so a
        # url-less row is dropped rather than refused; the only shape check
        # that belongs here is "was a list sent at all".
        def replace_platform_links(community:, selector:)
          entries = write_body_params["join_links"]
          halt 400, yaml_body("error" => "join_links must be a list") unless entries.is_a?(Array)

          deps.platform_links.replace(community: community, selector: selector, entries: entries)
        end

        # The single feature-settings row for a scope + feature name, or a
        # clean 404. Community-scoped implicitly through +community+, the
        # same list {ControlPlane::FeatureControls#list} already resolves.
        def feature_entry!(community, selector:, feature:)
          entry = deps.feature_controls.list(community, selector: selector).find { |row| row[:feature] == feature.to_s }
          halt 404, yaml_body("error" => "not found") if entry.nil?

          entry
        end

        # One room's effective answer for a feature, with +inherited+ saying
        # which scope gave it: a room row comes back as it stands, or the
        # community default with +room_key+ still naming the room asked
        # about. 404 only when neither scope has ever configured the
        # feature.
        def room_feature_payload(community, room, feature)
          own = deps.feature_controls.list(community, selector: room.room_key)
                    .find { |row| row[:feature] == feature.to_s }
          return feature_payload(own).merge("inherited" => false) if own

          default = feature_entry!(community, selector: "all", feature: feature)
          feature_payload(default).merge("room_key" => room.room_key, "inherited" => true)
        end

        # The wire representation of a {ControlPlane::FeatureControls#list}
        # entry (a Hash with symbol keys), restated with string keys so it
        # reads identically to every other payload this app emits.
        def feature_payload(entry)
          {
            "scope" => entry[:scope].to_s,
            "room_key" => entry[:room_key],
            "feature" => entry[:feature],
            "enabled" => entry[:enabled],
            "config" => entry[:config]
          }
        end

        # The viewer request row for an id, or a clean 404. Deployment-wide, so
        # there is no community to scope the lookup to.
        def viewer_request!(id)
          row = deps.dashboard_viewers.find_request(id: id)
          halt 404, yaml_body("error" => "not found") if row.nil?

          row
        end

        # A granted viewer row. "removable" says out loud what the revoke route
        # will do, so a client need not infer it from which list a handle is in.
        def viewer_payload(row)
          {
            "id" => row[:id],
            "adapter" => row[:adapter].to_s,
            "handle" => row[:handle].to_s,
            "native_id" => row[:native_id],
            "requires_regrant" => row[:native_id].nil?,
            "label" => row[:label].to_s,
            "granted_at" => row[:granted_at].to_s,
            "granted_by" => row[:granted_by].to_s,
            "removable" => true
          }
        end

        # One entry from the floor the deployment ships with. It carries no id,
        # because there is no row to address and nothing to revoke.
        def baked_in_viewer_payload(entry)
          { "handle" => entry[:handle].to_s, "kind" => entry[:kind].to_s, "removable" => false }
        end

        # A granted deployment administrator. It matches a viewer row so a
        # client can render either roster from the same general table shape.
        def administrator_payload(row)
          {
            "id" => row[:id],
            "adapter" => row[:adapter].to_s,
            "handle" => row[:handle].to_s,
            "native_id" => row[:native_id],
            "requires_regrant" => row[:native_id].nil?,
            "label" => row[:label].to_s,
            "granted_at" => row[:granted_at].to_s,
            "granted_by" => row[:granted_by].to_s,
            "removable" => true
          }
        end

        # The shipped floor has no database row to address, so it cannot carry
        # an id or be revoked through this API.
        def baked_in_administrator_payload(entry)
          { "handle" => entry[:handle].to_s, "kind" => entry[:kind].to_s, "removable" => false }
        end

        # The community viewer request row for an id, or a clean 404. Scoped to
        # the community, so an id from another one is simply not found here.
        def community_viewer_request!(community, id)
          row = deps.community_viewers.find_request(community_id: community.id, id: id)
          halt 404, yaml_body("error" => "not found") if row.nil?

          row
        end

        # A granted community viewer row. Same shape as the deployment-wide one
        # plus the community it reads, so a client reads both the same way.
        def community_viewer_payload(row)
          viewer_payload(row).merge("community_id" => row[:community_id])
        end

        def community_viewer_request_payload(row)
          viewer_request_payload(row).merge("community_id" => row[:community_id])
        end

        # What an administrator key may mint: anything, anywhere.
        def admin_minter
          ControlPlane::AuthTokens::Minter.new(administrator: true, community_ids: [], label: actor_label)
        end

        # What a key minting on a community path may mint, deliberately NOT
        # an administrator even when the key is one: the path already fixes
        # the scope to this community, so both kinds of key mint the same
        # thing here. A developer key may hand over viewer of its own
        # community, but not operator, since it is read-write without being
        # an operator itself and minting one would reach past what the key
        # itself holds.
        def community_minter(community)
          ControlPlane::AuthTokens::Minter.new(
            administrator: false, community_ids: [community.id],
            may_grant_operator: administrator?, label: actor_label
          )
        end

        # The lifetime a mint asked for, or the default when it named none.
        def token_ttl(body)
          value = presence(body["ttl_seconds"])
          value.nil? ? ControlPlane::AuthTokens::DEFAULT_TTL : value.to_i
        end

        # The 204/404/422 shape both revoke routes answer with. A spent token is
        # 422 rather than a silent success: the role it carried is already
        # granted, and revoking it would say otherwise.
        def revoke_auth_token(public_id, community_id: nil, every: false)
          result = deps.auth_tokens.revoke(
            public_id: public_id, community_id: community_id, every: every, revoked_by: actor_label
          )
          halt 404, yaml_body("error" => "not found") if result.status == :not_found
          halt 422, yaml_body("error" => "that token has already been redeemed") if result.status == :spent

          status 204
          body ""
        end

        # A minted token, without the token. The raw string is answered exactly
        # once, by the mint route, and only its digest is ever stored, so there
        # is nothing here to hand it back from.
        def auth_token_payload(row)
          {
            "public_id" => row[:public_id].to_s,
            "community" => row[:community_id] && models.community[row[:community_id]]&.slug,
            "grants" => deps.auth_tokens.grant_words(row),
            "label" => row[:label].to_s,
            "state" => deps.auth_tokens.state_of(row),
            "created_by" => row[:created_by].to_s,
            "created_at" => row[:created_at].to_s,
            "expires_at" => row[:expires_at].to_s,
            "redeemed_at" => row[:redeemed_at]&.to_s,
            "redeemed_by" => presence(row[:redeemed_username]) || presence(row[:redeemed_native_id]),
            "revoked_at" => row[:revoked_at]&.to_s
          }
        end

        def viewer_request_payload(row)
          {
            "id" => row[:id],
            "adapter" => row[:adapter].to_s,
            "requester_username" => row[:requester_username].to_s,
            "requester_display" => row[:requester_display].to_s,
            "state" => row[:state].to_s,
            "requested_at" => row[:requested_at].to_s,
            "decided_at" => row[:decided_at]&.to_s
          }
        end

        def operator_request_payload(request)
          {
            "id" => request.id,
            "adapter" => request.adapter,
            "requester_username" => request.requester_username,
            "requester_display" => request.requester_display,
            "state" => request.state,
            "requested_at" => request.requested_at.to_s,
            "decided_at" => request.decided_at&.to_s
          }
        end

        # The irc_network row for a +name+ within +community+, or a clean
        # 404, the same community-scoping reasoning as {#room!}.
        def irc_network!(community, name)
          row = community.irc_networks_dataset.where(name: name.to_s).first
          halt 404, yaml_body("error" => "not found") if row.nil?

          row
        end

        # The fluxer_instance row for a +label+ within +community+, or a
        # clean 404, the same reasoning as {#irc_network!}.
        def fluxer_instance!(community, label)
          row = community.fluxer_instances_dataset.where(label: label.to_s).first
          halt 404, yaml_body("error" => "not found") if row.nil?

          row
        end

        # The guest_invite row for an id within +community+, or a clean 404,
        # the same reasoning as {#person!}.
        def guest_invite!(community, id)
          row = community.guest_invites_dataset.where(id: id.to_i).first
          halt 404, yaml_body("error" => "not found") if row.nil?

          row
        end

        def platform_connection_payload(connection)
          {
            "id" => connection.id,
            "adapter" => connection.adapter,
            "account" => connection.account,
            "external_id" => connection.external_id,
            "label" => connection.label
          }
        end

        # env-var NAMES only, never a raw secret: sasl_password_env is the
        # NAME of the environment variable holding the SASL password, the
        # same value the dashboard's own Platforms page shows.
        def irc_network_payload(network)
          {
            "name" => network.name,
            "host" => network.host,
            "port" => network.port,
            "tls" => network.tls,
            "nick" => network.nick,
            "sasl_user" => network.sasl_user,
            "sasl_password_env" => network.sasl_password_env,
            "channels" => network.json_value(:channels),
            "mode" => network.mode,
            "hub_channel" => network.hub_channel,
            "channel_keys" => network.json_value(:channel_keys)
          }
        end

        # An IRC network's submitted fields, ready for
        # {ControlPlane::IrcNetworks#create} or {#update}: neither raises on a
        # bad shape, that is entirely the service's own
        # {ControlPlane::IrcNetworks::Invalid} to report. A field the caller
        # omits falls back to +existing+'s current value, PATCH semantics;
        # +existing+ is nil for create, where an omitted required field
        # simply fails the service's own required check.
        def irc_network_attributes(existing = nil)
          given = write_body_params
          {
            name: given["name"] || existing&.name,
            host: given["host"] || existing&.host,
            port: given["port"] || existing&.port,
            tls: truthy_param("tls", existing.nil? ? true : existing.tls),
            nick: given["nick"] || existing&.nick,
            sasl_user: given["sasl_user"] || existing&.sasl_user,
            sasl_password_env: given["sasl_password_env"] || existing&.sasl_password_env,
            channels: given["channels"] || (existing && existing.json_value(:channels)) || [],
            mode: given["mode"] || existing&.mode,
            hub_channel: given["hub_channel"] || existing&.hub_channel,
            channel_keys: given["channel_keys"] || (existing && existing.json_value(:channel_keys)) || {}
          }
        end

        # api_key_env is the NAME of the environment variable holding the API
        # key, never the raw key itself, the same value the dashboard shows.
        def fluxer_instance_payload(instance)
          {
            "label" => instance.label,
            "kind" => instance.kind,
            "endpoint_url" => instance.endpoint_url,
            "api_key_env" => instance.api_key_env
          }
        end

        # No token, ever: guest_invites stores only token_hash (see migration
        # 010), the raw token is shown to the inviter once, at issuance, and
        # never persisted anywhere this could read it back from.
        def guest_invite_payload(invite)
          {
            "id" => invite.id,
            "nickname" => invite.nickname,
            "room_key" => invite.room&.room_key,
            "created_by" => invite.created_by,
            "expires_at" => invite.expires_at.to_s,
            "revoked_at" => invite.revoked_at&.to_s,
            "joined_at" => invite.joined_at&.to_s
          }
        end

        # The accounts row for an (adapter, name) pair, or a clean 404. No
        # community scoping, unlike every other lookup helper here: an
        # account belongs to the deployment, not a tenant, so the pair is
        # the whole address, matching {ControlPlane::Accounts#find}'s own id
        # lookup one level down.
        def account!(adapter, name)
          row = deps.accounts.list.find { |acct| acct.adapter == adapter.to_s && acct.name == name.to_s }
          halt 404, yaml_body("error" => "not found") if row.nil?

          row
        end

        # settings holds token_env and per-adapter behaviour flags, JSON
        # encoded: environment variable NAMEs and plain config, never a raw
        # secret, the same shape {#irc_network_payload} and
        # {#fluxer_instance_payload} already document for their own env-var
        # fields.
        def account_payload(account)
          {
            "id" => account.id,
            "adapter" => account.adapter,
            "name" => account.name,
            "settings" => account.json_value(:settings),
            "source" => account.source
          }
        end

        def action_permission_payload(row)
          {
            "action" => row[:action].to_s,
            "label" => row[:label],
            "group" => row[:group],
            "operator_writable" => row[:operator_writable]
          }
        end

        def api_key_payload(key)
          {
            "public_id" => key.public_id,
            "scope" => key.scope,
            "community" => key.community_id && models.community[key.community_id]&.slug,
            "label" => key.label,
            "created_by" => key.created_by,
            "revoked_at" => key.revoked_at&.to_s,
            "last_used_at" => key.last_used_at&.to_s
          }
        end

        # 404 only for a name this deployment has never heard of; a KNOWN
        # integration nobody has configured yet answers with its unsaved
        # placeholder, the same "not yet configured" shape #list already
        # hands back for it.
        def integration!(name)
          halt 404, yaml_body("error" => "not found") unless ControlPlane::Integrations::KNOWN.include?(name.to_s)

          deps.integrations.find(name) || models.integration.new(name: name.to_s)
        end

        # Never api_key itself: api_key_set is all a client gets, the same
        # "present or not" the dashboard's own key field shows.
        def integration_payload(integration)
          {
            "name" => integration.name,
            "url" => integration.url,
            "api_key_set" => !integration.api_key.to_s.empty?,
            "config" => integration.json_value(:config),
            "updated_at" => integration.updated_at&.to_s
          }
        end

        # +existing+ supplies the fallback for url and config, matching
        # {#endpoint_attributes} and {#irc_network_attributes}. api_key gets
        # none: {ControlPlane::Integrations#save} already treats a blank or
        # absent one as "leave the stored key alone".
        def integration_attributes(existing)
          given = write_body_params
          config = given.key?("config") ? given["config"] : existing.json_value(:config)
          halt 400, yaml_body("error" => "config must be a mapping") unless config.is_a?(Hash)
          {
            name: existing.name,
            url: given.key?("url") ? given["url"] : existing.url,
            api_key: given["api_key"],
            config: config
          }
        end

        def event_payload(event)
          {
            "id" => event.id,
            "room_key" => models.room[event.room_id]&.room_key,
            "title" => event.title,
            "description" => event.description,
            "starts_at" => event.starts_at.to_s,
            "ends_at" => event.ends_at&.to_s,
            "timezone" => event.timezone,
            "kind" => event.kind,
            "game_title" => event.game_title,
            "server_address" => event.server_address,
            "url" => event.url,
            "rsvp_mode" => event.rsvp_mode,
            "status" => event.status,
            "reminder_intervals" => event.reminder_intervals,
            "recurrence_interval" => event.recurrence_interval
          }
        end

        # A provisioning request is deliberately distinct from a Room: a bot
        # process still has to create platform channels before there is a room
        # to read. The same acknowledgement shape covers create and delete.
        def room_provisioning_payload(result)
          {
            "status" => result.status.to_s,
            "room" => result.room && room_payload(result.room)
          }
        end

        # The active-mute list contains only operational details, never the
        # audit trail's optional display name or reason. Those belong to the
        # moderator's private log rather than an API response a client may keep.
        def sanction_payload(sanction, active: sanction.active)
          {
            "id" => sanction.id,
            "adapter" => sanction.adapter,
            "native_id" => sanction.subject_native_id,
            "username" => sanction.subject_username,
            "until_at" => sanction.until_at&.to_s,
            "active" => active
          }
        end

        # Only pass fields the scheduling service understands. An absent field
        # stays absent rather than becoming nil, which is the difference
        # between leaving an event alone and clearing one of its optional
        # values on PATCH.
        def event_updates
          given = write_body_params
          %w[title starts_at ends_at description timezone url reminder_intervals recurrence_interval].each_with_object({}) do |name, updates|
            updates[name.to_sym] = given[name] if given.key?(name)
          end
        end

        # These API surfaces deliberately share the exact validation the
        # dashboard invokes. A bad request is a client error, not an internal
        # exception, so every service refusal is one documented 422 response.
        def with_control_plane_error
          yield
        rescue ControlPlane::RoomProvisioning::Invalid, ControlPlane::ModerationActions::Invalid,
               ControlPlane::EventScheduling::Invalid, ControlPlane::IrcNetworks::Invalid,
               ControlPlane::Integrations::Invalid => e
          halt 422, yaml_body("error" => e.message)
        end

        # Serialise a Hash to the YAML response body. The one place this app
        # writes YAML, so every route and the shared error handler agree on
        # exactly one document shape.

        # --------------------------------------------------------------
        # scripts, endpoints and the numbers scripts record
        # --------------------------------------------------------------

        def script!(community, id)
          deps.scripts.find(community, id) || halt(404, yaml_body("error" => "not found"))
        end

        def endpoint!(community, id)
          deps.script_endpoints.find(community, id) || halt(404, yaml_body("error" => "not found"))
        end

        # Every refusal these services raise reaches the client as a 422 with
        # the service's own sentence, rather than a 500.
        def with_script_error
          yield
        rescue ControlPlane::Scripts::Invalid, ControlPlane::ScriptEndpoints::Invalid,
               Scripting::Error => e
          halt 422, yaml_body("error" => e.message)
        end

        # +existing+ supplies the fallback for a PATCH, so a partial update
        # does not blank whatever it left out.
        def script_attributes(existing = nil)
          given = write_body_params
          {
            name: given["name"] || existing&.name,
            kind: given["kind"] || existing&.kind || "processor",
            language: given["language"] || existing&.language || "lua",
            source: given["source"] || existing&.source,
            trigger_type: given["trigger_type"] || existing&.trigger_type || "always",
            trigger_config: script_trigger_config(existing),
            # Falls back to what is stored for the same reason every other field
            # here does: a PATCH that named only the source must not take the
            # script's data file away with it.
            yaml_data: given["yaml_data"] || existing&.yaml_data
          }
        end

        def script_trigger_config(existing)
          given = write_body_params["trigger_config"]
          return given if given.is_a?(Hash)
          return {} if existing.nil?

          deps.scripts.trigger_config(existing)
        end

        # The compiled Lua is deliberately absent: it is machine text nobody
        # should be asked to read, and the source is what was written.
        def script_row(row, community)
          {
            "id" => row.id, "name" => row.name.to_s, "kind" => row.kind.to_s,
            "language" => row.language.to_s, "source" => row.source.to_s,
            # The document as it was written rather than the parser's reading of
            # it, which is the same choice the editor makes.
            "yaml_data" => row.yaml_data.to_s,
            "condition" => row.trigger_type.to_s,
            "trigger_config" => deps.scripts.trigger_config(row),
            "enabled" => !!deps.scripts.runnable?(row),
            "checked" => !!deps.scripts.verified?(row),
            "archived" => !row.archived_at.nil?,
            "disabled_reason" => row.disabled_reason.to_s,
            "community" => community.slug.to_s
          }
        end

        def endpoint_attributes(existing = nil)
          given = write_body_params
          {
            name: given["name"] || existing&.name,
            url: given["url"] || existing&.url,
            http_method: given["http_method"] || existing&.http_method || "GET",
            description: given["description"] || existing&.description,
            # Decoded, not the raw column: save parses a String as header
            # lines, so passing the stored JSON through would rewrite every
            # header into one named after the JSON itself.
            headers: given["headers"] || (existing && ControlPlane::ScriptEndpoints.stored_hash(existing.headers)),
            query_params: given["query_params"] ||
                          (existing && ControlPlane::ScriptEndpoints.stored_hash(existing.query_params)),
            allow_sync: truthy_param("allow_sync", existing&.allow_sync),
            enabled: truthy_param("enabled", existing.nil? ? true : existing.enabled),
            timeout_seconds: given["timeout_seconds"] || existing&.timeout_seconds || 2,
            cache_seconds: given["cache_seconds"] || existing&.cache_seconds || 30
          }
        end

        def truthy_param(name, fallback)
          given = write_body_params
          return !!fallback unless given.key?(name)

          [true, "1", "true", "yes", "on"].include?(
            given[name].is_a?(String) ? given[name].downcase : given[name]
          )
        end

        # Headers are the one field never echoed back: an endpoint carries an
        # API key, and the point of putting it here is that it is not readable
        # from anywhere a script or a script author can reach.
        # Scoped, so a subscription belonging to another community answers the
        # same 404 as one that does not exist.
        def webhook!(community, public_id)
          deps.webhooks.find(community_id: community.id, public_id: public_id) ||
            halt(404, yaml_body("error" => "not found"))
        end

        def with_webhook_error
          yield
        rescue ControlPlane::Webhooks::Invalid => e
          halt 422, yaml_body("error" => e.message)
        end

        # Never carries `secret`. The create and rotate routes add it to their
        # own response deliberately; nothing that merely lists a subscription
        # should hand the signing key back out.
        def webhook_payload(row)
          {
            "public_id" => row.public_id.to_s,
            "url" => row.url.to_s,
            "label" => row.label.to_s,
            "event_types" => ControlPlane::Webhooks.event_types_of(row),
            "room_key" => row.room_key.to_s,
            "active" => !!row.active,
            # So a client can see a rotation is still in flight without being
            # told either secret.
            "rotating" => deps.webhooks.rotating?(row),
            "created_at" => row.created_at.to_s
          }
        end

        def webhook_delivery_payload(row)
          {
            "id" => row.id,
            "event_id" => row.event_id.to_s,
            "event_type" => row.event_type.to_s,
            "room_key" => row.room_key.to_s,
            "status" => row.status.to_s,
            "attempts" => row.attempts.to_i,
            "response_status" => row.response_status&.to_i,
            "last_error" => row.last_error.to_s,
            "created_at" => row.created_at.to_s,
            "delivered_at" => row.delivered_at&.to_s.to_s
          }
        end

        # --------------------------------------------------------------
        # alerts
        # --------------------------------------------------------------

        # One alert within +community+, or a clean 404. Scoped through the
        # community's own association, the same reasoning as {#person!}: an id
        # from another tenant is not found rather than refused.
        def alert!(community, id)
          row = community.alerts_dataset.where(id: id.to_i).first
          halt 404, yaml_body("error" => "not found") if row.nil?

          row
        end

        # How many alerts a listing returns. Bounded by the service itself, so a
        # caller asking for a million gets the ceiling rather than an error.
        def alert_limit = params[:limit] || 200

        def alert_payload(row)
          {
            "id" => row.id,
            "text" => row.text.to_s,
            # "quiet" was recorded and shown; "loud" also DMed the operators,
            # and delivered_to says how many it actually reached, which is the
            # honest answer to why nobody's phone went off.
            "mode" => row.mode.to_s,
            "delivered_to" => row.delivered_to.to_i,
            "room_key" => row.room_key.to_s,
            "script" => row.script.to_s,
            "seen_at" => row.seen_at&.to_s,
            "created_at" => row.created_at.to_s
          }
        end

        # A script's failure record: the last one, the ones before it, and the
        # circuit breaker's own state. The breaker's fields are here rather than
        # only on the script row so one request answers "is this working".
        def script_errors(row)
          {
            "id" => row.id,
            "name" => row.name.to_s,
            "consecutive_failures" => row.consecutive_failures.to_i,
            "disabled_at" => row.disabled_at&.to_s,
            "disabled_reason" => row.disabled_reason.to_s,
            "last_error" => row.last_error.to_s,
            "last_error_at" => row.last_error_at&.to_s,
            "errors" => deps.scripts.error_history(row).map do |entry|
              { "at" => entry["at"].to_s, "message" => entry["message"].to_s }
            end
          }
        end

        # --------------------------------------------------------------
        # files
        # --------------------------------------------------------------

        # The file service, or a 503 saying plainly that this deployment has no
        # usable store. A 404 would be the wrong answer: the route exists and the
        # community exists, and what is missing is a mounted disk, which is an
        # operator's problem and worth naming rather than disguising.
        def file_store!
          deps.rehosted_files ||
            halt(503, yaml_body("error" => "this deployment has no file store configured"))
        end

        def rehosted_file!(community, id)
          file_store!.find(community_id: community.id, id: id) ||
            halt(404, yaml_body("error" => "not found"))
        end

        # The UUID a rotate or expire request names. Required, and refused when
        # absent rather than treated as "no file", so a caller that forgot the
        # field is told so instead of reading a 404 as "already gone".
        def file_secret!
          given = write_body_params["uuid"].to_s.strip
          halt 422, yaml_body("error" => "uuid is required") if given.empty?

          given
        end

        def with_file_error
          yield
        rescue Storage::ObjectStore::TooLarge => e
          halt 413, yaml_body("error" => e.message)
        rescue ControlPlane::RehostedFiles::Invalid => e
          halt 422, yaml_body("error" => e.message)
        end

        # What a file looks like to somebody managing it. No UUID and no
        # download link: neither is recoverable from the row, which is the whole
        # security property (see the route comments above).
        def file_payload(row)
          {
            "id" => row.id,
            "filename" => row.filename.to_s,
            "content_type" => row.content_type.to_s,
            "byte_size" => row.byte_size.to_i,
            # What the disk is really carrying, after compressing and sealing.
            "sealed_bytes" => row.sealed_bytes.to_i,
            "room_key" => row.room_key.to_s,
            # "relay" for one the bridge could not deliver, "upload" for one
            # somebody handed over.
            "source" => row.source.to_s,
            "created_by" => row.created_by.to_s,
            "created_at" => row.created_at.to_s,
            "expires_at" => row.expires_at.to_s,
            "served_count" => row.served_count.to_i,
            "serve_limit" => row.serve_limit.to_i,
            "serves_remaining" => [row.serve_limit.to_i - row.served_count.to_i, 0].max
          }
        end

        # The two responses that carry a UUID, and the only two: the upload that
        # minted it and the rotation that replaced it.
        def stored_file_payload(stored)
          file_payload(stored.file).merge("uuid" => stored.secret, "url" => download_url(stored))
        end

        # The public download address for a stored file, built off
        # RUBOTTY_FILE_STORAGE_URL; with none set, what comes back is the
        # path alone. Ends in a real extension, the same way
        # {Core::AttachmentRehoster#download_url} picks its own, since
        # {FileStorage::App} checks a url's extension against that same row.
        def download_url(stored)
          base = settings.api_env["RUBOTTY_FILE_STORAGE_URL"].to_s.sub(%r{/+\z}, "")
          ext = Util::FileExtension.for(filename: stored.file.filename, content_type: stored.file.content_type)
          "#{base}/#{Core::AttachmentRehoster::PATH}/#{stored.secret}.#{ext}"
        end

        def endpoint_row(row)
          {
            "id" => row.id, "name" => row.name.to_s, "url" => row.url.to_s,
            "http_method" => row.http_method.to_s, "description" => row.description.to_s,
            # allow_sync and cache_seconds are deprecated and inert, kept on
            # the wire so an existing client does not break.
            "allow_sync" => !!row.allow_sync, "enabled" => !!row.enabled,
            "timeout_seconds" => row.timeout_seconds.to_i,
            "cache_seconds" => row.cache_seconds.to_i,
            "query_params" => ControlPlane::ScriptEndpoints.pairs_to_lines(row.query_params),
            "has_headers" => !ControlPlane::ScriptEndpoints.headers_to_lines(row.headers).empty?
          }
        end

        def yaml_body(value)
          YAMLCamel.dump(deep_stringify(value))
        end

        # --------------------------------------------------------------
        # the live stream
        # --------------------------------------------------------------

        # Where a stream starts reading. An explicit ?since, or a browser's
        # Last-Event-ID on a reconnect, is honoured as given, which is what
        # makes resume work; with neither, the stream starts at the room's
        # current head rather than at 0, so opening one hands over what
        # happens next instead of whatever the buffer still holds.
        def opening_cursor(community_id:, room_key:)
          given = params[:since] || request.env["HTTP_LAST_EVENT_ID"]
          return given.to_i unless given.nil?

          deps.live_room_feed.latest_id(community_id: community_id, room_key: room_key)
        end

        # One server-sent event carrying a YAML document: SSE joins
        # consecutive "data:" lines with a newline before the client sees
        # them, so a multi-line YAML document rides one line per frame line
        # and reassembles exactly. The blank line terminates the event; the
        # "id:" is what a browser echoes back as Last-Event-ID.
        def sse_event(payload, id: nil)
          document = YAMLCamel.dump(deep_stringify(payload))
          lines = document.lines.map { |line| "data: #{line.chomp}\n" }.join
          "#{"id: #{id}\n" if id}#{lines}\n"
        end

        # A comment frame. It carries nothing and exists only so a proxy or a
        # load balancer sees traffic on an idle stream and leaves the connection
        # alone.
        def sse_heartbeat = ": heartbeat\n\n"

        def sse_heartbeat_interval
          raw = settings.api_env["API_SSE_HEARTBEAT_INTERVAL"]
          raw.nil? || raw.to_s.empty? ? 20 : raw.to_f
        end

        # How many buffer passes a stream makes before closing, or nil for
        # unbounded (production). A test sets API_SSE_MAX_PASSES so the stream
        # terminates deterministically instead of holding the connection open,
        # the same knob the guest portal's stream uses under its own name.
        def sse_max_passes
          raw = settings.api_env["API_SSE_MAX_PASSES"]
          raw.nil? || raw.to_s.empty? ? nil : raw.to_i
        end

        # How often a held stream is charged against its key's budget: one
        # unit per limiter window by default, capping a key at roughly its
        # whole per-window allowance in concurrent streams. A test sets
        # API_SSE_METER_SECONDS so a few passes cross several intervals.
        def sse_meter_seconds
          raw = settings.api_env["API_SSE_METER_SECONDS"]
          return deps.rate_limiter.window_seconds if raw.nil? || raw.to_s.empty?

          raw.to_f
        end

        # One buffered message on the wire. No native platform id: the buffer
        # records what the room saw, and a per-platform id belongs to one copy of
        # it rather than to the message.
        def stream_message_payload(entry)
          {
            "id" => entry.id,
            "origin" => entry.origin_key,
            "author" => entry.author_label,
            "body" => entry.body,
            "kind" => entry.kind,
            "at" => entry.created_at.to_s
          }
        end

        # Recursively stringifies Hash keys and renders a Time as a plain
        # string, so every response, including a deeply-nested one like the
        # stats endpoint's {ControlPlane::Analytics#overview}, reads
        # identically regardless of whether the payload method that built it
        # remembered to call +.to_s+ on every Time itself.
        def deep_stringify(value)
          case value
          when Hash
            value.each_with_object({}) { |(key, val), acc| acc[key.to_s] = deep_stringify(val) }
          when Array
            value.map { |item| deep_stringify(item) }
          when Time
            value.to_s
          else
            value
          end
        end

        def mapping_proposal_payload(proposal)
          {
            "endpoint_key" => proposal.channel.endpoint_key,
            "channel_label" => proposal.channel.label,
            "action" => proposal.action.to_s,
            "room_key" => proposal.room_key,
            "room_label" => proposal.room_label,
            "reason" => proposal.reason
          }
        end

        # Apply one entry from an apply request. Skips silently, returning
        # false, for a channel that is no longer discovered-and-unmapped:
        # proposals are a snapshot, and something may have been mapped
        # between fetching them and submitting them, so a stale entry has to
        # be dropped rather than acted on.
        def apply_one_mapping(community, entry, eligible)
          return false unless entry.is_a?(Hash)

          channel = eligible[entry["endpoint_key"].to_s]
          return false if channel.nil?

          room_key = entry["room_key"].to_s
          return false if room_key.empty?

          deps.channel_mapper.resolve_selection(
            community: community, channel: channel, room_key: room_key, label: entry["room_label"]
          )
          true
        end

        # A still-discovered, still-unmapped channel within +community+, or a
        # clean 404. Read from the same unmapped list the discovery routes
        # report, so a channel somebody mapped a moment ago reads as gone
        # instead of being mapped a second time.
        def discovered_channel!(community, endpoint_key)
          row = deps.channel_discovery.unmapped(community)
                    .find { |candidate| candidate.endpoint_key == endpoint_key.to_s }
          halt 404, yaml_body("error" => "not found") if row.nil?

          row
        end

        # --------------------------------------------------------------
        # onboarding
        # --------------------------------------------------------------

        # The queue a ?state= names: awaiting a decision (the default), denied
        # and still refused, or both. Anything else 400s, matching {#debug_source!}.
        def pending_spaces_in_state
          case (params[:state] || "pending").to_s
          when "pending" then deps.pending_spaces.pending
          when "denied" then deps.pending_spaces.denied
          when "all" then deps.pending_spaces.pending + deps.pending_spaces.denied
          else halt 400, yaml_body("error" => "state must be pending, denied, or all")
          end
        end

        # The pending_spaces row for an id, or a clean 404. No community
        # scoping to apply: the row belongs to no community, which is why
        # every route reaching this is administrator-only.
        def pending_space!(id)
          row = deps.pending_spaces.find(id)
          halt 404, yaml_body("error" => "not found") if row.nil?

          row
        end

        # Run the approve the body asks for: onto the community whose slug is
        # named, else as a brand new community under the name given. Naming
        # neither is refused by the service itself, so it is not re-checked here.
        def approve_pending_space(pending)
          body = write_body_params
          slug = presence(body["community"])
          make_operator = truthy_param?(body["make_operator"])
          if slug
            deps.pending_spaces.approve(id: pending.id, admin: actor_label, make_operator: make_operator,
                                        community_id: community!(slug).id)
          else
            deps.pending_spaces.approve(id: pending.id, admin: actor_label, make_operator: make_operator,
                                        new_community_name: presence(body["new_community_name"]))
          end
        end

        # Why a decision did not land, as one sentence.
        def pending_space_refusal(result)
          case result.status
          when :not_pending then "that space has already been decided"
          else "name either an existing community's slug or a new community name"
          end
        end

        def pending_space_payload(row)
          {
            "id" => row.id,
            "adapter" => row.adapter,
            "account" => row.account,
            "external_id" => row.external_id,
            "name" => row.name,
            "state" => row.state,
            "inviter_username" => row.inviter_username,
            "inviter_display" => row.inviter_display,
            # Whether make_operator on an approve would actually do anything:
            # it needs the inviter's platform id, which a join event may never
            # have carried. The id itself stays off the wire.
            "can_make_operator" => !presence(row.inviter_native_id).nil?,
            "member_count" => row.member_count,
            "sample_channels" => row.json_value(:sample_channels),
            "community" => row.community_id && models.community[row.community_id]&.slug,
            "decided_by" => row.decided_by,
            "decided_at" => row.decided_at&.to_s,
            "expires_at" => row.expires_at.to_s,
            "created_at" => row.created_at.to_s
          }
        end

        def space_suggestion_payload(suggestion)
          {
            "matched" => suggestion.matched,
            "pending_space" => pending_space_payload(suggestion.space)
          }
        end

        # "web" (default), "bot", or "all"; anything else 400s rather than
        # silently falling back, since a typo'd source is a caller error
        # worth surfacing, not something to guess past.
        def debug_source!
          source = (params[:source] || "web").to_s
          return source if %w[web bot all].include?(source)

          halt 400, yaml_body("error" => "source must be web, bot, or all")
        end

        def web_process_info
          {
            "version" => Rubotty::VERSION,
            "commit" => Core::BuildInfo.commit,
            "hostname" => Core::BuildInfo.hostname,
            "runtime" => Core::BuildInfo.runtime,
            "platform" => Core::BuildInfo.platform,
            "pid" => Process.pid,
            "scripting" => scripting_info
          }
        end

        # What the Lua toolchain on this deployment actually looks like,
        # here because the alternative was reading a build transcript. A rock
        # that fails to install is simply not offered, so each dialect
        # reports the binary it wants and whether that binary is on PATH,
        # making "not offered" and "why" one request rather than a redeploy.
        def scripting_info
          dialects = Scripting::Dialects::ALL.to_h do |dialect|
            [dialect.name, dialect.native? ? "built in" : "#{dialect.binary}: #{found_or_missing(dialect)}"]
          end

          {
            "interpreter" => Scripting::Child.find_binary || "none on PATH",
            # The directories actually searched, PATH plus whatever luarocks
            # reports, rather than PATH alone. A transpiler that installed and
            # still cannot be found is a question about this list.
            "searched" => Scripting::Dialects.search_paths,
            "dialects" => dialects
          }
        end

        def found_or_missing(dialect)
          Scripting::Dialects.installed?(dialect.binary) ? "found" : "not on PATH"
        end

        # The bot process's OWN build facts, asked of it directly rather
        # than assumed from this process's. The two share a deployed image
        # in principle, but "in principle" is exactly what fails when a
        # container is still running an older build than the one main is
        # on, and that mismatch is invisible from anywhere else.
        def bot_process_info
          deps.bot_logs.fetch_info
        end

        # Normalises one log entry, whichever shape it arrived in, to the
        # wire shape every route in this app uses: string keys, a plain
        # ISO8601 time. +entry+ is either this process's OWN
        # {RingBuffer#entries} shape (symbol keys, a real Time) or a row
        # {BotLogsClient} already parsed out of the bot's YAML response
        # (string keys, an already-ISO8601 string); reading both shapes
        # off the same hash here is what lets #debug_logs merge them
        # into one list without caring which process it came from.
        def debug_log_entry(entry, source)
          {
            "source" => source,
            "time" => entry[:time] ? entry[:time].utc.iso8601 : entry["time"],
            "level" => entry[:level] || entry["level"],
            "text" => entry[:text] || entry["text"]
          }
        end

        # The backfill-gap sweep's body, fetched fresh from the bot process on
        # every request over {BotLogsClient#get}. An unreachable bot, or one
        # answering with a body that carries no "channels" key, reads as an
        # error rather than an empty report.
        def backfill_gaps_payload
          result = deps.bot_logs.get(Core::HealthServer::GAPS_PATH)
          channels = result.ok? && result.body.is_a?(Hash) ? result.body["channels"] : nil
          return { "channels" => channels } unless channels.nil?

          error = result.ok? ? "the bot process sent an unreadable body" : result.error
          { "channels" => [], "errors" => { "bot" => error } }
        end

        # --------------------------------------------------------------
        # backfill proposals
        # --------------------------------------------------------------

        # Which state to list. Defaults to the one somebody is nearly always
        # after: what is still waiting on a decision.
        def backfill_state!
          state = (params[:state] || "pending").to_s
          states = ControlPlane::BackfillProposals::STATUSES
          return state if state == "all" || states.include?(state)

          halt 400, yaml_body("error" => "state must be all, or one of: #{states.join(', ')}")
        end

        # The proposals in the state asked for, freshest first. "all" reads
        # every state and merges them into one ordering rather than five
        # lists, so a client sees what happened in order.
        def backfill_proposals_in_state
          state = backfill_state!
          every = ControlPlane::BackfillProposals::EVERY_COMMUNITY
          return deps.backfill_proposals.in_status(state, community: every) unless state == "all"

          rows = ControlPlane::BackfillProposals::STATUSES.flat_map do |name|
            deps.backfill_proposals.in_status(name, community: every)
          end
          rows.sort_by { |row| [row[:created_at].to_s, row[:id]] }.reverse
        end

        # The community row for each id a batch of proposals names, in one
        # query rather than one per row.
        def communities_by_id(rows)
          ids = rows.map { |row| row[:community_id] }.uniq
          return {} if ids.empty?

          models.community.where(id: ids).all.each_with_object({}) { |row, index| index[row.id] = row }
        end

        # This surface is administrator only and names no community of its
        # own, so the row is read across every tenant and the community that
        # owns it is resolved beside it for anything that then writes.
        def backfill_proposal!(id)
          row = deps.backfill_proposals.find_in_any_community(id.to_i)
          halt 404, yaml_body("error" => "not found") if row.nil?

          row
        end

        # The community owning a proposal, which every write below has to name.
        # A row whose community is gone answers 404 rather than being decided.
        def backfill_proposal_community!(row)
          community = models.community[row[:community_id]]
          halt 404, yaml_body("error" => "not found") if community.nil?

          community
        end

        # One proposal's row, counts included. The counts are the numbers the
        # sweep actually saw rather than a recount taken later, which is what
        # makes them safe to judge by.
        def backfill_proposal_payload(row, communities = communities_by_id([row]))
          {
            "id" => row[:id],
            "community" => communities[row[:community_id]]&.slug,
            "endpoint_id" => row[:endpoint_id],
            "status" => row[:status],
            "fetched" => row[:fetched].to_i,
            "gaps" => row[:gaps].to_i,
            "ours" => row[:ours].to_i,
            "claimed" => row[:claimed].to_i,
            "below_floor" => row[:below_floor].to_i,
            "swept_since" => row[:swept_since]&.to_s,
            "expires_at" => row[:expires_at].to_s,
            "decided_by" => row[:decided_by],
            "decided_at" => row[:decided_at]&.to_s,
            "created_at" => row[:created_at].to_s
          }
        end

        # One proposal with whatever previews it still holds. A row whose
        # previews are gone says so, since an empty list on its own would read
        # as "the sweep was going to send nothing".
        def backfill_proposal_detail(row)
          items = deps.backfill_proposals.items(community: backfill_proposal_community!(row),
                                                proposal_id: row[:id])
          pruned = items.empty? && row[:status] != "pending"
          body = {
            "backfill_proposal" => backfill_proposal_payload(row),
            "items" => items.map { |item| backfill_proposal_item_payload(item) },
            "items_pruned" => pruned
          }
          body["items_note"] = backfill_pruned_note(row[:status]) if pruned
          body
        end

        # Why there is nothing to read, in the words of what happened to it.
        def backfill_pruned_note(status)
          gone = case status
                 when "rejected" then "when it was rejected"
                 when "expired" then "when it ran out of time"
                 when "relayed" then "once the accepted list had gone out"
                 else "when it was decided"
                 end
          "The previews were deleted #{gone}, so there is nothing left to read. " \
            "The counts on the proposal are what the sweep found."
        end

        def backfill_proposal_item_payload(item)
          {
            "native_id" => item[:native_id],
            "author_label" => item[:author_label],
            "preview" => item[:preview],
            "sent_at" => item[:sent_at]&.to_s
          }
        end

        # The answer to an accept: the decided row, how many messages were
        # handed over, and whether the bot took the push. Only that process
        # holds the adapters, so one it could not reach is reported under
        # "errors" rather than left to read as sent.
        def backfill_approval_payload(community, proposal_id, item_count)
          relay = deps.bot_relay.relay_proposal(proposal_id)
          body = {
            "backfill_proposal" => backfill_proposal_payload(
              deps.backfill_proposals.find(community: community, proposal_id: proposal_id)
            ),
            "item_count" => item_count,
            "relaying" => relay.ok?
          }
          body["errors"] = { "bot" => relay.error } unless relay.ok?
          body
        end
      end
    end
  end
end
