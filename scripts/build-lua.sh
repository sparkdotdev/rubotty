#!/bin/sh
# Build Lua (whatever the newest stable tag is) and luarocks from source,
# tuned for the machine doing the build.
#
# luarocks is built here too rather than installed from apt, because Debian's
# luarocks package is configured against Debian's own lua at package build
# time and would drag that interpreter back in alongside this one.
set -eu

PREFIX=/usr/local

ARCH_FLAGS="${RUBOTTY_ARCH_FLAGS:--march=native}"
OPTFLAGS="-O3 ${ARCH_FLAGS}"

# Always the newest tagged stable release, matching build-ruby.sh's reasoning:
# no version to bump by hand, a future breakage from a version jump is a bug
# to fix rather than a reason to pin. A stable tag is exactly vN.N.N.
LUA_VERSION=$(
  git ls-remote --tags --refs https://github.com/lua/lua.git \
    | awk '{print $2}' | sed 's#refs/tags/v##' \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
    | sort -V | tail -1
)
[ -n "${LUA_VERSION}" ] || { echo "could not resolve the latest lua tag" >&2; exit 1; }
LUA_MAJOR_MINOR="${LUA_VERSION%.*}"
echo "building lua ${LUA_VERSION}"

# Fetched from lua.org rather than cloned, unlike build-ruby.sh: github.com/lua/lua
# is explicitly a development mirror ("please do not send pull requests... download
# official Lua releases from Lua.org", straight from its own README), not the
# release source. Its makefile is a flat, test-harness-inclusive developer build
# with no platform targets at all, confirmed by direct inspection: no `linux` target,
# no src/ layout. The real release tarball still has both, so only the version
# NUMBER comes from git tags here; the source itself comes from where Lua's own
# README says to get it. TLS is the integrity check, matching build-node.sh's own
# NodeSource fetches: lua.org does not publish a machine-checkable per-release
# checksum to verify against.
cd /tmp
curl -fsSL -o "lua-${LUA_VERSION}.tar.gz" "https://www.lua.org/ftp/lua-${LUA_VERSION}.tar.gz"
tar xzf "lua-${LUA_VERSION}.tar.gz"

# The linux target passes -Wl,-E, which is what lets a C rock resolve the Lua
# symbols the interpreter already carries. Without it every compiled rock loads
# and then fails on an undefined symbol.
JOBS="${RUBOTTY_MAKE_JOBS:-$(( $(nproc) / 2 ))}"
[ "${JOBS}" -ge 1 ] || JOBS=1

cd "lua-${LUA_VERSION}/src"
make linux MYCFLAGS="${OPTFLAGS}" -j"${JOBS}"

# install lives in the top-level Makefile, not src/: it also reaches into
# ../doc for the man pages, so it has to run one level up from where the
# compile just happened.
cd ..
make install INSTALL_TOP="${PREFIX}"
mkdir -p "${PREFIX}/share/licenses/lua"
cp src/lua.h "${PREFIX}/share/licenses/lua/lua.h"

# Lua installs its man pages into ${PREFIX}/man as a real directory, and the
# Fedora base image ships /usr/local/man as a symlink to share/man. Copying this
# step's /usr into the deploy image then dies with "cannot copy to
# non-directory". Nothing reads a man page in a container, so drop it.
rm -rf "${PREFIX}/man"

# Scripting::Child probes for lua5.5, lua5.4, lua5.3 and lua in that order, and
# a source install lands as plain lua, so give it the name it looks for first,
# matching whichever major.minor actually got built.
ln -sf "${PREFIX}/bin/lua" "${PREFIX}/bin/lua${LUA_MAJOR_MINOR}"

# Also always the newest tag, for a concrete reason rather than just
# consistency: luarocks hardcodes the list of Lua versions its own configure
# script will accept via --lua-version, and a pin here can fall behind a
# newly latest Lua and start rejecting it outright (confirmed: 3.12.2 does
# not know "5.5" exists yet and 3.13.0 does). Pinning this independently of
# Lua's own version would only recreate that trap at the next Lua release.
LUAROCKS_VERSION=$(
  git ls-remote --tags --refs https://github.com/luarocks/luarocks.git \
    | awk '{print $2}' | sed 's#refs/tags/v##' \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
    | sort -V | tail -1
)
[ -n "${LUAROCKS_VERSION}" ] || { echo "could not resolve the latest luarocks tag" >&2; exit 1; }
echo "building luarocks ${LUAROCKS_VERSION}"

# Cloned, same as build-ruby.sh: unlike lua/lua, luarocks/luarocks is the
# genuine project repo (real README, MIT license, no "download the release
# elsewhere" disclaimer), and a tagged checkout's ./configure works as-is
# with no separate autogen step, confirmed by direct build.
cd /tmp
git clone --depth 1 --branch "v${LUAROCKS_VERSION}" \
  https://github.com/luarocks/luarocks.git "luarocks-${LUAROCKS_VERSION}"
cd "luarocks-${LUAROCKS_VERSION}"
./configure --prefix="${PREFIX}" --with-lua="${PREFIX}" --lua-version="${LUA_MAJOR_MINOR}"
make
make install
mkdir -p "${PREFIX}/share/licenses/luarocks"
cp COPYING "${PREFIX}/share/licenses/luarocks/"

# Rocks are always built from source, there is no such thing as a precompiled
# rock, so the two that carry C (lpeg under MoonScript, compat53 under Teal)
# compile here whatever we do. What they do NOT inherit is our flags: luarocks
# keeps its own CFLAGS, defaulting to a plain -O2. -fPIC has to stay, because
# these build loadable shared modules.
#
# Appended to the config rather than set with `luarocks config`, because that
# subcommand parses the leading -O3 of the value as an option and refuses.
# The generated config is Lua and assigns `variables` above this line, so
# mutating one key leaves the paths luarocks worked out for itself alone.
LUAROCKS_CONFIG_FILE="${PREFIX}/etc/luarocks/config-${LUA_MAJOR_MINOR}.lua"
test -f "${LUAROCKS_CONFIG_FILE}" || { echo "no luarocks config at ${LUAROCKS_CONFIG_FILE}"; exit 1; }
printf '\nvariables.CFLAGS = "%s -fPIC"\n' "${OPTFLAGS}" >> "${LUAROCKS_CONFIG_FILE}"
# Checked by reading the file rather than executing it. luarocks injects globals
# of its own when it loads this config, so running it standalone dies on a nil
# `home` before it ever reaches the line we just added.
grep -q "^variables.CFLAGS" "${LUAROCKS_CONFIG_FILE}" || { echo "CFLAGS did not take"; exit 1; }
grep "^variables.CFLAGS" "${LUAROCKS_CONFIG_FILE}"

cd /
rm -rf "/tmp/lua-${LUA_VERSION}" "/tmp/lua-${LUA_VERSION}.tar.gz"
rm -rf "/tmp/luarocks-${LUAROCKS_VERSION}" "/tmp/luarocks-${LUAROCKS_VERSION}.tar.gz"

"${PREFIX}/bin/lua${LUA_MAJOR_MINOR}" -v
"${PREFIX}/bin/luarocks" --version
echo "lua built with optflags ${OPTFLAGS}"
