# frozen_string_literal: true

# The per-probe timeout every spec's own SmokeTest instance should use.
# Slacker than production's Rubotty::Scripting::SmokeTest::DEFAULT_TIMEOUT
# (1s): the gate under test here is the check itself, not its budget, and a
# freshly sandboxed probe (its own fork, seccomp and Landlock setup) can run
# past 1s on a loaded runner without the script under test being wrong.
SMOKE_TEST_SPEC_TIMEOUT = 5
