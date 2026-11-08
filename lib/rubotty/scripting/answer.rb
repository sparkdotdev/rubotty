# frozen_string_literal: true

module Rubotty
  module Scripting
    # The protocol carries one Lua return value, so a handler returning
    # [false, "why"] would arrive as a truthy table and `if not ok then`
    # would never fire. Values are kept explicit rather than unpacked from
    # an Array, since some host functions return real Arrays that must
    # still arrive as a single Lua table.
    class Answer
      # false plus the reason, the shape every refusal takes.
      def self.refuse(reason) = new(false, reason.to_s)

      # true plus nothing, so a caller reading `ok, err` gets a nil err.
      def self.ok = new(true)

      def initialize(*values)
        @values = values.freeze
        freeze
      end

      attr_reader :values

      # What a Ruby caller of the same handler sees, since the router's handlers
      # are also called from Ruby that never crosses into Lua.
      def to_a = @values.dup

      def ok? = @values.first == true
    end
  end
end
