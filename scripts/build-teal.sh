#!/bin/sh
# Build Teal from source rather than installing the published rock.
#
# The upstream main branch carries the Lua 5.5 fixes before the next tagged
# release. Overrides remain for a temporary upstream regression, but a normal
# build follows Teal itself rather than a Rubotty fork.
set -eu
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

TEAL_REPO="${RUBOTTY_TEAL_REPO:-https://github.com/teal-language/tl}"
TEAL_REF="${RUBOTTY_TEAL_REF:-main}"

# Installed directly because the rockspec also names compat53, which has no
# build for Lua 5.5 at all, so resolving from the rockspec fails before it
# compiles anything. Teal only asks for compat53 below 5.3, through a pcall.
luarocks install argparse
luarocks install luafilesystem

echo "building teal from ${TEAL_REPO} at ${TEAL_REF}"
rm -rf /tmp/tl
git clone --depth 1 --branch "${TEAL_REF}" "${TEAL_REPO}" /tmp/tl
cd /tmp/tl
luarocks make --deps-mode=none

# Record the exact checkout before its temporary source directory is removed.
ruby "${SCRIPT_DIR}/runtime-components.rb" capture-teal /tmp/tl

cd /
rm -rf /tmp/tl

# Proves the interpreter can actually load it, which is the thing the published
# rock failed at: it installed fine and then crashed on startup.
tl --version
