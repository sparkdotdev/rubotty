# frozen_string_literal: true

module Rubotty
  module Scripting
    # The languages an operator may write a script in. Everything downstream is
    # Lua, so a dialect is a transpiler, its flags, and where the output lands.
    # A dialect whose transpiler is missing is reported unavailable.
    module Dialects
      # @param binary [String, nil] the transpiler, nil for Lua
      # @param args [Array<String>] flags placed before the source path
      # @param output [Symbol] :stdout, or :file when the transpiler insists on
      #   writing one next to the source (Teal has no stdout mode)
      # @param check_args [Array<String>, nil] a validate-only first pass, for a
      #   dialect whose compile step does not check. Teal's `tl gen` strips the
      #   annotations and exits 0 even when they are wrong.
      # @param editor_mode [String] which CodeMirror mode highlights it
      Dialect = Struct.new(:name, :label, :extension, :comment, :binary, :args, :output,
                           :editor_mode, :check_args, keyword_init: true) do
        def checked? = !check_args.nil?
        def native? = binary.nil?

        # Where a shipped example's `trigger:` header is read from, per dialect
        # since the comment marker differs.
        def trigger_pattern = /^#{Regexp.escape(comment)}\s*trigger:\s*(\w+)/

        def summary_prefix = /^#{Regexp.escape(comment)}+\s*/
      end

      # A dialect belongs here only if compiling it executes nothing, or
      # executes it somewhere confined. Fennel is the second case: its
      # eval-compiler form runs code during compilation, which its own
      # compiler sandbox does not stop and its authors say is no security
      # boundary, so {Isolation} spawns every compile into an account of its
      # own instead.
      ALL = [
        Dialect.new(name: "lua", label: "Lua", extension: ".lua", comment: "--",
                    binary: nil, args: [], output: :stdout, editor_mode: "lua"),
        Dialect.new(name: "moonscript", label: "MoonScript", extension: ".moon", comment: "--",
                    binary: "moonc", args: ["-p"], output: :stdout, editor_mode: "moonscript"),
        Dialect.new(name: "fennel", label: "Fennel", extension: ".fnl", comment: ";;",
                    binary: "fennel", args: ["--compile"], output: :stdout, editor_mode: "fennel"),
        Dialect.new(name: "teal", label: "Teal", extension: ".tl", comment: "--",
                    binary: "tl", args: ["gen"], output: :file, editor_mode: "lua",
                    check_args: ["check"])
      ].freeze

      BY_NAME = ALL.to_h { |dialect| [dialect.name, dialect] }.freeze

      DEFAULT = "lua"

      module_function

      def names = ALL.map(&:name)

      def find(name) = BY_NAME[name.to_s]

      def find!(name)
        find(name) || raise(Scripting::Error, "#{name.inspect} is not a language rubotty knows")
      end

      # Walked in Ruby because `command -v` is a shell builtin with no binary
      # behind it on a Debian image.
      def installed?(binary)
        return true if binary.nil?

        search_paths.any? { |dir| File.executable?(File.join(dir, binary)) }
      end

      # PATH, plus wherever luarocks says it puts the executables it installs,
      # since a transpiler installed as a rock lands outside PATH.
      def search_paths
        @search_paths ||= (path_entries + [luarocks_bin_dir]).compact.uniq
      end

      # Forget the cached answer. Only tests need this: the cache keeps a
      # subprocess out of every page render.
      def reset_search_paths!
        @search_paths = nil
      end

      def path_entries
        ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).reject(&:empty?)
      end

      # Best effort: luarocks missing or too old for `config` means carrying on
      # with PATH alone.
      def luarocks_bin_dir
        require "open3"
        out, status = Open3.capture2("luarocks", "config", "deploy_bin_dir")
        return nil unless status.success?

        dir = out.strip
        dir.empty? ? nil : dir
      rescue StandardError
        nil
      end

      # The Lua the sandbox child will actually run, and its version, for the
      # startup banner. Probed through the same names Child looks for so the two
      # can never disagree about which interpreter this image carries.
      def lua_runtime
        @lua_runtime ||= begin
          binary = Child::BINARIES.find { |name| installed?(name) }
          binary.nil? ? nil : probe(binary, "-v")
        end
      end

      # Each transpiler answers a different way, so take the first thing that
      # looks like a version and let the caller print the dialect's own label.
      # A dialect that is missing, or that answers something unrecognisable, is
      # reported without a version rather than not at all.
      def version(dialect)
        return nil if dialect.native? || !installed?(dialect.binary)

        probe(dialect.binary, "--version")&.slice(/\d+(?:\.\d+)+\S*/)
      end

      # Nothing here may raise. A banner is not worth failing a boot over.
      def probe(binary, flag)
        require "open3"
        out, err, status = Open3.capture3(binary, flag)
        return nil unless status.success?

        text = out.strip.empty? ? err.strip : out.strip
        line = text.lines.first.to_s.strip
        line.empty? ? nil : line
      rescue StandardError
        nil
      end

      def reset_versions!
        @lua_runtime = nil
      end

      # Why a missing dialect binary is missing, where that has a known cause
      # worth telling an operator apart from "nobody ran the install command".
      # No dialect has such a cause today, so this answers nil for all of them.
      def unavailable_reason(_dialect)
        nil
      end

      # The dialects this deployment can compile. Lua is always among them.
      def available = ALL.select { |dialect| installed?(dialect.binary) }

      def available?(name)
        dialect = find(name)
        !dialect.nil? && installed?(dialect.binary)
      end

      def available_names = available.map(&:name)
    end
  end
end
