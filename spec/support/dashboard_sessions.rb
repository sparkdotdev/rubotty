# frozen_string_literal: true

require "digest"

# Build the same server-side claims a real web-login produces. Route permission
# tests must not manufacture authority by putting a role into a cookie.
module DashboardSessionHelpers
  def dashboard_session(role: "operator", operator_communities: [], viewer: false, viewer_communities: [])
    raise ArgumentError, "use password login for administrator sessions" unless role == "operator"

    @dashboard_session_sequence = (@dashboard_session_sequence || 0) + 1
    handle = "dashboard-session-#{@dashboard_session_sequence}"
    native_id = dashboard_native_id(handle)
    operator_communities.each do |community_id|
      deps.operators.promote(community_id: community_id, adapter: "telegram", native_id: native_id,
                             username: handle, granted_by: "fixture")
    end
    if viewer == true
      deps.dashboard_viewers.grant(adapter: "telegram", handle: handle, native_id: native_id, granted_by: "fixture")
    end
    viewer_communities.each do |community_id|
      deps.community_viewers.grant(community_id: community_id, adapter: "telegram", handle: handle,
                                    native_id: native_id, granted_by: "fixture")
    end
    issued = deps.web_login.issue(
      identity_key: "telegram:fixture:#{native_id}",
      operator: { adapter: "telegram", native_id: native_id, username: handle },
      communities: operator_communities.map { |id| { id: id } },
      viewer: viewer, viewer_communities: viewer_communities
    )
    raise "dashboard fixture login could not be issued" unless issued.ok?

    claims = deps.web_login.redeem(token: issued.token)
    raise "dashboard fixture login could not be redeemed" unless claims.ok?

    {
      role: role, login_token_id: claims.token_id,
      operator_communities: operator_communities, viewer: viewer,
      viewer_communities: viewer_communities
    }
  end

  def dashboard_native_id(handle)
    Digest::SHA256.hexdigest(handle.to_s.downcase).to_i(16).modulo(10**14).to_s
  end

  # A handle-based grant form resolves an account the bot has already observed.
  # This observation supplies lookup data and does not grant any access itself.
  def observe_dashboard_identity(handle:, native_id: dashboard_native_id(handle), community_id: nil)
    community_id ||= deps.models.community.order(:id).get(:id)
    rows = deps.models.db[:observed_identities]
    existing = rows.where(community_id: community_id, adapter: "telegram", native_id: native_id).first
    return native_id if existing

    rows.insert(community_id: community_id, adapter: "telegram", native_id: native_id,
                username: handle.downcase, first_seen_at: Time.now, last_seen_at: Time.now)
    native_id
  end
end

RSpec.configure { |config| config.include DashboardSessionHelpers }
