# frozen_string_literal: true

require "sinatra/base"

module Rubotty
  # A rehosted file's download route, with no relationship to the guest portal
  # or any other surface: the link is the whole capability, nothing here needs
  # a session, an invite or a room. Mounted twice by {Web.assemble}: once
  # where a token carries its own extension, once at the bare-secret shape a
  # link could have been minted under before the extension existed. One
  # route serves both, since a token {Util::FileExtension.split} can't read
  # as "<secret>.<ext>" is just treated as the secret itself.
  module FileStorage
    class App < Sinatra::Base
      # Up to this size a file is read twice, once to check its authentication
      # tag and once to serve it, so a 200 means something. Past this a bad
      # tag is caught only once the stream is already open, and the response
      # is cut short instead.
      VERIFY_BEFORE_SERVE_BYTES = 8 * 1024 * 1024

      # Never trusted by the reverse proxy to preview or execute what it
      # serves: this puts the response in an opaque origin.
      SERVED_BYTES_HEADERS = {
        "Content-Security-Policy" => "default-src 'none'; sandbox",
        "X-Content-Type-Options" => "nosniff"
      }.freeze

      # @param rehosted_files [ControlPlane::RehostedFiles, nil] nil when the
      #   deployment has no store configured, which 404s every request here
      # @param logger [#warn, nil]
      # @return [Class] a ready-to-serve Sinatra app subclass
      def self.assemble(rehosted_files:, logger: nil)
        Class.new(self) do
          set :rehosted_files, rehosted_files
          set :file_logger, logger
        end
      end

      disable :show_exceptions
      enable :raise_errors
      disable :dump_errors
      disable :sessions
      # The reverse proxy terminates the public hostname and is the trust
      # boundary, so Sinatra's own Host whitelist is disabled.
      set :host_authorization, permitted_hosts: []

      get "/healthz" do
        content_type "text/plain"
        "ok\n"
      end

      get "/:token" do
        halt 404 if rehosted_files.nil?

        secret, ext = Util::FileExtension.split(params[:token])
        if secret
          file = rehosted_files.fetch(secret: secret)
          halt 404 if file.nil?
          halt 404 unless Util::FileExtension.for(filename: file.filename, content_type: file.content_type) == ext
        else
          secret = params[:token]
          file = rehosted_files.fetch(secret: secret)
          halt 404 if file.nil?
        end
        # An exhausted link refuses here, before anything about the file is
        # touched, so it reveals nothing more than an unknown secret does.
        halt 404 if rehosted_files.exhausted?(file)

        serve(file, secret)
      end

      private

      def rehosted_files = settings.rehosted_files

      def file_logger = settings.file_logger

      # The bytes back. Streamed, decompressing as it goes, so a file larger
      # than memory is served without being held.
      def serve(file, secret)
        halt 500, unreadable_body unless verified?(file) { rehosted_files.intact?(file, secret: secret) }

        # A HEAD carries no body and a preview-window request is a platform
        # building a link preview, so neither spends a serve; both are still
        # gated by the route's #exhausted? check. Anything else spends one
        # atomically here, before any header naming the file goes out.
        head = request.request_method == "HEAD"
        unless head || rehosted_files.preview_window?(file)
          halt 404 unless rehosted_files.record_serve(file)
        end

        content_type Security::ServedTypes.allowed(file.content_type)
        headers "Content-Disposition" => %(attachment; filename="#{header_filename(file.filename)}"),
                "Content-Length" => file.byte_size.to_s,
                # A link is a bearer capability, so a shared cache must not hold it.
                "Cache-Control" => "private, max-age=300",
                **SERVED_BYTES_HEADERS
        return if head

        stream do |out|
          rehosted_files.stream(file, secret: secret) { |chunk| out << chunk }
        rescue Rubotty::Storage::ObjectStore::Unreadable => e
          # Status and headers are already sent, so ending short is the only signal left.
          file_logger&.warn { "rehosted download failed part way: #{e.message}" }
        end
      end

      # Whether the row's bytes still authenticate, handing none of them out,
      # so a 200 here means what it says. The tag is checked at the end of
      # the stream, so a row small enough to read twice is read once to
      # verify and once to serve; past that the second pass costs more than
      # the wrong status does, and the stream's short body remains the signal.
      def verified?(row)
        return true if row.byte_size.to_i > VERIFY_BEFORE_SERVE_BYTES
        return true if yield

        file_logger&.warn { "refused to serve an object that no longer authenticates: #{row.object_key}" }
        false
      end

      def unreadable_body
        content_type "text/plain"
        "That file could not be read.\n"
      end

      # Strips characters that could break or inject a Content-Disposition header.
      def header_filename(name)
        name.to_s.gsub(/[^\w.\- ]/, "_")[0, 255]
      end
    end
  end
end
