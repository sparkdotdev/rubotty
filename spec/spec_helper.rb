# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "rubotty"

# The file-based backends refuse to boot as the LIVE backend unless this
# opts in, so they cannot silently lose data on an ephemeral container. The
# suite runs them on throwaway temp files, exactly the case the flag is for,
# so it sets it for the whole run.
ENV["ALLOW_EPHEMERAL_STORAGE"] ||= "1"

# The dashboard session cookie is Secure by default, and rack-test drives plain
# http, where a browser would not send one back: the suite is the plain-http
# deployment the opt-out exists for. Read at load time, so this has to be set
# before any spec requires rubotty/dashboard.
ENV["DASHBOARD_COOKIE_INSECURE"] ||= "1"

# Scripts run in an account of their own, and handing out an account needs
# root, which a developer's machine and a hosted CI runner both are not, so
# the suite opts out for the whole run the way an operator on such a machine
# would.
ENV["RUBOTTY_SCRIPT_ISOLATION"] ||= "optional"

# The same for the other two layers a deployment can be short of: macOS has
# no seccomp and refuses rlimit_as, and a container can be started with a
# profile that refuses a filter, so the suite says out loud it will run
# scripts either way; this does not turn the filter off where one exists.
ENV["RUBOTTY_SCRIPT_SECCOMP"] ||= "optional"
ENV["RUBOTTY_SCRIPT_LIMITS"] ||= "optional"

# The sealed object store needs its own throwaway directory each run so no
# run inherits another's blobs, and every deployment pins Sequel to UTC
# through Storage::Factory before opening a connection, so the suite does
# the same rather than leaving it to whichever spec migrates first.
Rubotty::Storage::Factory.use_utc!

require "tmpdir"
ENV["RUBOTTY_FILE_STORE"] ||= Dir.mktmpdir("rubotty-spec-object-store")
# mktmpdir creates the directory, and an existing empty directory is what an
# unmounted disk looks like, so the store will not claim one unasked. A
# throwaway directory the suite made itself is the one case where claiming it is
# exactly right.
ENV["RUBOTTY_FILE_STORE_INIT"] ||= "1"

Dir[File.expand_path("support/**/*.rb", __dir__)].sort.each { |file| require file }

# Reassigning a constant only warns by default, so one spec file's struct
# can silently replace another's and both keep running against mismatched
# fields. Scoped to spec files: a warning from a gem or from Ruby itself
# still only prints, the same as it always has.
module Warning
  def self.warn(message)
    if message.include?("already initialized constant") && message.include?("spec/")
      raise message
    end

    super
  end
end

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.mock_with(:rspec) { |c| c.verify_partial_doubles = true }
  config.disable_monkey_patching!
  config.order = :random
  config.filter_run_when_matching :focus
  Kernel.srand config.seed

  # No spec may touch the network. Anything that reaches for a socket is a bug
  # in the spec, not a flaky test, so it fails loudly rather than timing out.
  config.before do
    allow(Net::HTTP).to receive(:start) do
      raise "a spec attempted a real HTTP request. Inject a fake transport instead."
    end
  end
end
