# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# Core::Moderation::Directory#resolve matches the deployment-configured owner floor on
# USERNAME, so a call site passing only the native id resolves the owner to
# nobody and silently treats them as a regular member. That shipped on
# eighteen of twenty call sites at once, so it is checked at the source level.
RSpec.describe "operator lookups pass the username" do
  let(:lib_root) { File.expand_path("../../lib", __dir__) }

  # Directory#resolve and Directory#authorise are the only lookups in the codebase taking
  # both an adapter name and a native id, which is what tells them apart from the unrelated
  # Snapshot#resolve and GuildResolver.resolve.
  let(:methods) { %w[resolve authorise] }

  # Every call to one of {methods} in +path+ as [line number, argument source], found by
  # walking the balanced parentheses so a call split over several lines is read whole.
  def calls(source, path)
    found = []
    offset = 0
    while (match = source.match(/\.(#{methods.join("|")})\(/, offset))
      open_index = match.end(0) - 1
      arguments = balanced(source, open_index)
      if arguments
        found << [source[0...match.begin(0)].count("\n") + 1, arguments, path]
        offset = open_index + arguments.length
      else
        offset = match.end(0)
      end
    end
    found
  end

  # The text between the parenthesis at +open_index+ and its partner, or nil when the
  # source has no partner for it. Quotes are skipped so a bracket inside a string cannot
  # close the call.
  def balanced(source, open_index)
    depth = 0
    quote = nil
    index = open_index
    while index < source.length
      char = source[index]
      if quote
        index += 1 if char == "\\"
        quote = nil if char == quote
      elsif ['"', "'"].include?(char)
        quote = char
      elsif char == "("
        depth += 1
      elsif char == ")"
        depth -= 1
        return source[(open_index + 1)...index] if depth.zero?
      end
      index += 1
    end
    nil
  end

  # Comments are dropped first, so prose about a call cannot register as one and a
  # commented-out example cannot fail the guard.
  def uncommented(path)
    File.readlines(path, encoding: "UTF-8").map { |line| line.sub(/(?<![\\$'"#])#(?!\{).*$/, "") }.join
  end

  # A call takes an adapter name and a native id, so it is an operator lookup rather than
  # one of the unrelated methods sharing the name.
  def operator_lookup?(arguments)
    arguments.include?("adapter_name") && arguments.include?("native_id")
  end

  # The username reaches the floor: passed, and not passed as a hardcoded nil.
  def threads_username?(arguments)
    arguments.match?(/\busername:/) && !arguments.match?(/\busername:\s*nil\s*[,)]?\s*\z/)
  end

  let(:offences) do
    Dir.glob(File.join(lib_root, "**", "*.rb")).sort.flat_map do |path|
      calls(uncommented(path), path).filter_map do |line, arguments, source_path|
        next unless operator_lookup?(arguments)
        next if threads_username?(arguments)

        "#{source_path.delete_prefix("#{lib_root}/")}:#{line}: #{arguments.gsub(/\s+/, " ").strip}"
      end
    end
  end

  def guidance(found)
    <<~MESSAGE
      An operator lookup is being made without the asker's username:

      #{found.join("\n")}

      Core::Moderation::Directory#resolve asks Security::ProtectedOperators first,
      and that floor matches on the username. Passing only the native id skips it,
      so on a deployment whose operators are all baked in the lookup returns nil
      and the owner of the deployment is treated as a regular member. Nothing is
      logged and nothing is said back, so it reads as an ordinary permissions
      refusal.

      Pass the handle the adapter gave you, never the display name:

        directory.resolve(message.origin.adapter_name, author.native_id,
                          username: author.username)

      Core::Author#username is already nil when the platform supplied nothing, so
      there is no need to guard it, and there is no need to spell out
      "username: nil" either.
    MESSAGE
  end

  it "passes the username at every call site under lib/" do
    expect(offences).to be_empty, -> { guidance(offences) }
  end

  describe "the guard itself" do
    it "reads a call split across lines" do
      source = "directory.resolve(\n  adapter_name, native_id\n)\n"
      expect(calls(source, "x.rb").first[0]).to eq(1)
      expect(operator_lookup?(calls(source, "x.rb").first[1])).to be(true)
    end

    it "flags a lookup with no username" do
      source = "directory.resolve(adapter_name, author.native_id)\n"
      expect(calls(source, "x.rb").none? { |_, arguments, _| threads_username?(arguments) }).to be(true)
    end

    it "flags a username hardcoded to nil" do
      expect(threads_username?("adapter_name, native_id, username: nil")).to be(false)
    end

    it "accepts a threaded username" do
      expect(threads_username?("adapter_name, native_id, username: author.username")).to be(true)
    end

    it "ignores a resolve that is not an operator lookup" do
      expect(operator_lookup?("adapter, account, route_key")).to be(false)
    end

    it "ignores a call written inside a comment" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "example.rb")
        File.write(path, "# directory.resolve(adapter_name, native_id)\nx = 1\n")
        expect(calls(uncommented(path), path)).to be_empty
      end
    end
  end
end
