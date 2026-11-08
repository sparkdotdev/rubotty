# frozen_string_literal: true

require "fiddle"

module Rubotty
  module Scripting
    # syscall(2) and the pointers handed to it, for the layers a script's
    # process puts on itself between the fork and the exec.
    #
    # Fiddle rather than `Kernel#syscall` because all three of those layers pass
    # the address of a structure full of zero bytes, and `Kernel#syscall` runs a
    # String argument through StringValueCStr, which refuses one. The Gemfile
    # says why the dependency was worth taking.
    module Libc
      # What every argument past the number is: a machine word.
      WORD = Fiddle::TYPE_LONG

      module_function

      # syscall(2), declared variadic because it is: six fixed arguments works
      # under the Linux ABIs here and silently reads the wrong registers under
      # Apple's arm64 one. The GVL is held across it, the way `Kernel#syscall`
      # holds it.
      def function
        @function ||= Fiddle::Function.new(entry_point, [WORD, Fiddle::TYPE_VARIADIC], WORD,
                                           name: "syscall", need_gvl: true)
      end

      # Said the way `Kernel#syscall` says it on a platform that has no such call.
      def entry_point
        Fiddle::Handle::DEFAULT["syscall"]
      rescue Fiddle::DLError
        raise NotImplementedError, "syscall() function is unimplemented on this machine"
      end

      # Make system call +number+, with all six arguments every time since the
      # kernel reads only the ones its call takes. Fixed arity so a child that
      # has capped its address space is not building an Array per call.
      def syscall(number, one = 0, two = 0, three = 0, four = 0, five = 0, six = 0)
        result = function.call(number, WORD, one, WORD, two, WORD, three,
                               WORD, four, WORD, five, WORD, six)
        raise SystemCallError.new("syscall #{number}", Fiddle.last_error) if result == -1

        result
      end

      # The address of a NUL terminated copy of +value+, which the pointer holds.
      def string(value) = Fiddle::Pointer["#{value}\0"]

      # The address of +bytes+, for a structure laid out by hand.
      def pointer(bytes) = Fiddle::Pointer[bytes]

      # C argv and envp: a NULL terminated array of pointers, carrying the
      # strings it points at so nothing collects them.
      Vector = Struct.new(:block, :strings) do
        # So a vector can go straight to {Libc.syscall}.
        def to_int = block.to_i
      end

      def vector(values)
        strings = values.map { |value| string(value) }
        Vector.new(pointer((strings.map(&:to_i) + [0]).pack("J*")), strings)
      end
    end
  end
end
