# frozen_string_literal: true

require "json"
require "stringio"

module Rubotty
  module GuestPortal
    # Read-only token checks before Rack can parse a protected POST body.
    # Valid invites are checked again by the route; only the route claims a ticket.
    class RequestGuard
      DENIAL_KEY = "rubotty.guest.request_denial"
      LIMIT_KEY = "rubotty.guest.body_limit"
      # Use the same path parser as Sinatra, without asking Rack for body params.
      GUEST_POSTS = %w[messages upload].to_h { |action| [action, Mustermann.new("/g/:token/#{action}")] }.freeze
      TICKET_POST = Mustermann.new("/u/:token")

      def initialize(app, deps:, marker:, text_limit:, upload_limit:, envelope_bytes:)
        @app, @deps, @marker = app, deps, marker
        @text_limit, @upload_limit, @envelope_bytes = text_limit, upload_limit, envelope_bytes
      end

      def call(env)
        env.delete(DENIAL_KEY)
        env[LIMIT_KEY] = @text_limit
        return @app.call(env) unless env["REQUEST_METHOD"] == "POST"

        path = env["PATH_INFO"].to_s
        guest = GUEST_POSTS.filter_map { |action, pattern| params = pattern.params(path); [action, params] if params }.first
        if guest
          token = guest[1]["token"]
          if @deps.invites.authenticate(token: token).nil?
            body = JSON.generate(ended: true, error: "This guest session has ended.")
            return [410, { "content-type" => "application/json", "content-length" => body.bytesize.to_s,
                           "connection" => "close" }, [body]]
          end
          env[LIMIT_KEY] = @upload_limit if guest[0] == "upload"
        elsif (upload = TICKET_POST.params(path))
          return denied_ticket(env, :not_found) if @deps.upload_tickets.nil? || @deps.rehosted_files.nil?

          ticket = @deps.upload_tickets.authenticate(token: upload["token"])
          return denied_ticket(env, :ended) if ticket.nil?

          policy = @deps.rehosted_files.policy_for(community_id: ticket.community_id, room_key: ticket.room_key)
          env[LIMIT_KEY] = policy[:max_batch_bytes].to_i + policy[:max_batch_files].to_i * @envelope_bytes
        end
        @app.call(env)
      end

      private

      # Keep the existing HTML renderer, but give Sinatra empty input instead
      # of the rejected caller's original stream.
      def denied_ticket(env, reason)
        empty = env.merge("rack.input" => StringIO.new("".b), "CONTENT_LENGTH" => "0", "CONTENT_TYPE" => nil,
                          DENIAL_KEY => { marker: @marker, reason: reason })
        %w[rack.request.form_hash rack.request.form_input rack.request.form_pairs].each { |key| empty.delete(key) }
        result = @app.call(empty)
        result[1]["connection"] = "close"
        result
      end
    end
  end
end
