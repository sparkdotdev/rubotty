# frozen_string_literal: true

# The rehosted-file download surface. Loaded on demand, NOT by
# `require "rubotty"`: only the file-storage entry points (`rubotty web`,
# `rubotty file-storage`, web.ru, filestorage.ru) require this file, so the
# bot's relay runtime never pulls Sinatra or Rack into its process.
require "rubotty"

require "rubotty/file_storage/app"
require "rubotty/file_storage/server"
require "rack/urlmap"

module Rubotty
  # See {FileStorage::App}. {.assemble} mounts it at the paths a download link
  # is always built under, whatever process ends up serving it.
  module FileStorage
    # Where a fresh link's token lives; carries its own extension.
    MOUNT = "/filestorage"

    # The bare-secret shape a link could have been minted under before {MOUNT}
    # carried its own extension. Kept working rather than removed: a rehosted
    # file can sit on disk for up to a year, so a link already posted into a
    # real room may still be live. Must agree with {Web::LEGACY_FILES_MOUNT}
    # and with Core::AttachmentRehoster's own PATH/LEGACY_PATH, which build
    # the link this mounts.
    LEGACY_MOUNT = "/f"

    module_function

    # Build the ready-to-serve Rack app: one {App} instance mounted at both
    # paths a download link can carry. The seam `rubotty file-storage` and
    # filestorage.ru build the standalone surface through; the unified
    # {Web.assemble} mounts {App} itself at the same two paths instead.
    #
    # @param rehosted_files [ControlPlane::RehostedFiles, nil] nil when the
    #   deployment has no store configured, which 404s every request here
    # @return [#call] a Rack app ready to serve
    def assemble(rehosted_files:, logger: nil)
      app = App.assemble(rehosted_files: rehosted_files, logger: logger)
      Rack::URLMap.new(MOUNT => app, LEGACY_MOUNT => app)
    end
  end
end
