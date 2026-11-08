#!/bin/sh
# Install Node from NodeSource's apt repository, tracking whatever the newest
# stable release actually is.
#
# Not built from source, unlike Ruby and Lua: Node is a build-time-only tool
# here (npm run build produces static assets; nothing in the deploy image
# ever runs node again), so there is no runtime performance case for a
# from-source build, and apt gives us a maintained package without a tarball
# to fetch and verify by hand. Lives in a script rather than inline in
# railpack.json for the same reason as build-ruby.sh: a command string
# containing a colon breaks railpack's own command parsing, and this needs
# several https:// URLs.
set -eu

# curl has to exist before it can resolve a version below, so this installs
# first rather than relying on an earlier railpack step having already
# pulled it in for its own reasons.
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl gnupg

# Always the newest published release, LTS or not, matching build-ruby.sh and
# build-lua.sh's reasoning: no version to bump by hand, a future breakage
# from a version jump is a bug to fix rather than a reason to pin. dist/index.json
# lists every release newest-first, so the top entry is the answer.
NODE_MAJOR=$(
  curl -fsSL https://nodejs.org/dist/index.json \
    | grep -o '"version":"v[0-9]*' | head -1 | grep -o '[0-9]*$'
)
[ -n "${NODE_MAJOR}" ] || { echo "could not resolve the latest node version" >&2; exit 1; }
echo "installing node ${NODE_MAJOR}.x"

mkdir -p /usr/share/keyrings
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key -o /tmp/nodesource.asc
gpg --dearmor -o /usr/share/keyrings/nodesource.gpg /tmp/nodesource.asc
rm -f /tmp/nodesource.asc

# Architecture is read from the machine doing the build rather than assumed,
# so this works the same under amd64 and arm64.
printf 'Types: deb\nURIs: https://deb.nodesource.com/node_%s.x\nSuites: nodistro\nComponents: main\nArchitectures: %s\nSigned-By: /usr/share/keyrings/nodesource.gpg\n' \
  "${NODE_MAJOR}" "$(dpkg --print-architecture)" > /etc/apt/sources.list.d/nodesource.sources

apt-get update
apt-get install -y --no-install-recommends nodejs

node --version
npm --version
