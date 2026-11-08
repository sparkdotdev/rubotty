# frozen_string_literal: true

require "rubotty/errors"

module Rubotty
  # Operator authored scripts, run out of process: a pool of long lived Lua
  # children talking newline delimited JSON over pipes. Nothing here knows about
  # messages, rooms or commands, which is the layer above.
  module Scripting
    class Error < Rubotty::Error; end

    # No interpreter on PATH, or the child died mid invocation.
    class Unavailable < Error; end

    # The script did not finish inside its budget. The child has been killed by
    # the time this is raised.
    class Timeout < Error; end

    # The script itself failed: it would not compile, it raised, or it broke the
    # protocol. The message is meant to be shown to the operator.
    class Failed < Error; end

    # The conversation with the child ended somewhere it cannot be picked up
    # from: a frame too big to read whole, something that is not a frame at
    # all, or a host call refused without an answer being written back.
    #
    # Its own Failed subclass because a child in this state has to be killed
    # rather than returned to the pool, where it would poison later invocations.
    class Desync < Failed; end

    # A script called a host function that was never registered.
    class UnknownHostFunction < Failed; end
  end
end

require "rubotty/scripting/wake_context"
require "rubotty/scripting/dialects"
require "rubotty/scripting/teal_definitions"
require "rubotty/scripting/libc"
require "rubotty/scripting/isolation"
require "rubotty/scripting/limits"
require "rubotty/scripting/seccomp"
require "rubotty/scripting/landlock"
require "rubotty/scripting/confined"
require "rubotty/scripting/compiler"
require "rubotty/scripting/sandbox"
require "rubotty/scripting/registry"
require "rubotty/scripting/budget"
require "rubotty/scripting/child"
require "rubotty/scripting/pool"
require "rubotty/scripting/triggers"
require "rubotty/scripting/rule"
require "rubotty/scripting/context"
require "rubotty/scripting/answer"
require "rubotty/scripting/markup"
require "rubotty/scripting/room_key"
require "rubotty/scripting/handle"
require "rubotty/scripting/classifier"
require "rubotty/scripting/endpoints"
require "rubotty/scripting/memory"
require "rubotty/scripting/examples"
require "rubotty/scripting/host_functions"
require "rubotty/scripting/smoke_test"
