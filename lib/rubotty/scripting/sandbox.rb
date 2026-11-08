# frozen_string_literal: true

module Rubotty
  module Scripting
    # What a script is allowed to see, declared once here so the child, the editor's
    # autocomplete, and the docs cannot drift from each other. The child enforces its own
    # hard floor regardless of this list (see DENIED in sandbox.lua), so a bug here cannot
    # hand a script io, os, debug, or load.
    module Sandbox
      # Bare globals a script gets; setmetatable and rawget exist only because a compiled
      # MoonScript class needs them. getmetatable is deliberately absent: it exposes the
      # metatable Lua shares across every string in the process, so holding it would let a
      # script rewrite string.upper for every later script in the same pooled child,
      # including another community's.
      GLOBALS = %w[
        assert error ipairs next pairs pcall rawget select setmetatable
        tonumber tostring type xpcall
      ].freeze

      # Standard library, member by member rather than whole modules, so adding
      # a function is a deliberate act. byte, sub and gsub are also what
      # sandbox.lua's own MessagePack encoding resolves through the shared
      # string metatable, so dropping any of the three breaks the transport
      # itself rather than just narrowing what a script can do.
      MODULES = {
        "string" => %w[byte char find format gmatch gsub len lower match rep reverse sub upper],
        "table" => %w[concat insert remove sort unpack],
        "math" => %w[abs ceil floor fmod huge max min modf pi sqrt tointeger type]
      }.freeze

      # Everything rubotty offers, including the invocation payload, lives under one table
      # rather than as bare globals, so a script writing `local rooms = {}` can't shadow
      # anything and `m.text` and `rubotty.classify()` live in the same place.
      NAMESPACE = "rubotty"

      module_function

      # What the editor's autocomplete offers, built from the same constants the child is
      # handed so the list can't drift from what actually runs. A host function's `detail`
      # is the one-line row text; `info` is the CodeMirror side panel for argument types
      # and examples.
      # @param host_functions [Hash{String=>Hash}] name to { detail:, info: }
      def completions(host_functions: {})
        globals = GLOBALS.map { |name| entry(name, "function", "Lua standard library") }
        members = MODULES.flat_map do |mod, names|
          [entry(mod, "namespace", "Lua standard library")] +
            names.map { |name| entry("#{mod}.#{name}", "function", "Lua standard library") }
        end
        hosts = host_functions.map do |name, described|
          entry("#{NAMESPACE}.#{name}", "function", described[:detail].to_s, info: described[:info].to_s)
        end
        [entry(NAMESPACE, "namespace", "Everything rubotty exposes")] + globals + members + hosts
      end

      def entry(label, type, detail, info: nil)
        row = { "label" => label, "type" => type, "detail" => detail }
        info.nil? || info.empty? ? row : row.merge("info" => info)
      end
    end
  end
end
