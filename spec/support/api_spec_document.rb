# frozen_string_literal: true

# The published API contract lives in the docs/api submodule, which a plain clone
# and every new worktree leave empty, and the examples that read it then fail on a
# raw Errno::ENOENT that reads like a broken change. Tag a group or an example
# :api_spec_document and it fails with the cause and the command instead.
module ApiSpecDocument
  PATH = File.expand_path("../../docs/api/openapi.yaml", __dir__)

  # Raised in place of the Errno::ENOENT reading the file would have produced.
  class NotCheckedOut < StandardError; end

  ABSENT = <<~MESSAGE
    docs/api/openapi.yaml is not in this checkout, so this example never ran its
    real check. This failure is environmental and says nothing about the change
    you are testing.

    docs/api is a git submodule holding the published API contract. Neither a
    plain clone nor "git worktree add" populates one. Run this from the top of
    the checkout and the example will work:

      git submodule update --init --recursive

    CI checks the submodule out, so it cannot fail there for this reason.
  MESSAGE

  def self.checked_out? = File.exist?(PATH)
end

RSpec.configure do |config|
  config.before(:each, :api_spec_document) do
    raise ApiSpecDocument::NotCheckedOut, ApiSpecDocument::ABSENT unless ApiSpecDocument.checked_out?
  end
end
