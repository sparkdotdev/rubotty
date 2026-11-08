#!/bin/sh
# Build CRuby from source, tuned for the machine doing the build.
#
# Lives in a script rather than inline in railpack.json for one concrete reason:
# railpack reads a command string containing a colon as "type:payload", so a
# https:// URL cannot appear in a command at all.
set -eu

PREFIX=/usr/local

# -march=native is deliberate. Every host builds its own image under Coolify, so
# the build machine and the run machine are the same one. The rule that follows
# is that these images must never be pushed to a registry and pulled elsewhere.
# Override to something portable, e.g. x86-64-v3, if that ever stops being true.
ARCH_FLAGS="${RUBOTTY_ARCH_FLAGS:--march=native}"
OPTFLAGS="-O3 ${ARCH_FLAGS}"

# On aarch64, Ruby's own configure.ac probes whether the compiler supports
# -mbranch-protection=pac-ret (return-address signing), and turns it on
# unconditionally the moment a small test program survives it. That probe
# passes and then real code, in this case linked against jemalloc, segfaults
# at a later, unrelated configure check under at least one real arm64
# hypervisor (Apple's Virtualization.framework, confirmed by direct
# reproduction). configure.ac prepends its own detected flags ahead of
# whatever CFLAGS already holds specifically so a caller-supplied override
# here wins, so hand it one on aarch64: hardening the interpreter binary
# against ROP is not worth a hypervisor-dependent coin flip on whether it
# boots at all.
CFLAGS=""
[ "$(uname -m)" = "aarch64" ] && CFLAGS="-mbranch-protection=none"

# Always the newest tagged stable release, so this never needs a version bump
# by hand. A tag counts as stable when it is exactly N.N.N with nothing after
# it; a preview, an rc, or a patchlevel suffix all fail that match and are
# skipped. Ruby's own tag spelling changed at the 4.0 boundary, from
# underscores (v3_4_10) to dots (v4.0.0); both are matched and normalised to
# dots before comparing, so the newest tag wins regardless of which era it is
# from. A future breakage from a version jump is a bug to fix, not a reason to
# pin.
RUBY_VERSION=$(
  git ls-remote --tags --refs https://github.com/ruby/ruby.git \
    | awk '{print $2}' | sed 's#refs/tags/v##' \
    | grep -E '^([0-9]+_[0-9]+_[0-9]+|[0-9]+\.[0-9]+\.[0-9]+)$' \
    | tr '_' '.' | sort -V | tail -1
)
[ -n "${RUBY_VERSION}" ] || { echo "could not resolve the latest ruby tag" >&2; exit 1; }
echo "building ruby ${RUBY_VERSION}"

# Cloned rather than fetched as a tarball: git's own object hashing is the
# integrity check, so there is no separate checksum to fetch and no vendored
# hash to fall out of date. Depth 1 at the tag, so this is one commit, not the
# whole history.
cd /tmp
git clone --depth 1 --branch "v${RUBY_VERSION}" \
  https://github.com/ruby/ruby.git "ruby-${RUBY_VERSION}" 2>/dev/null \
  || git clone --depth 1 --branch "v$(echo "${RUBY_VERSION}" | tr '.' '_')" \
       https://github.com/ruby/ruby.git "ruby-${RUBY_VERSION}"
cd "ruby-${RUBY_VERSION}"

# A release tarball ships a pre-generated configure AND pre-generated sources
# like prism/ast.h; a raw git checkout has neither. autoconf and bison
# (already on PATH from the toolchain step above) regenerate configure, but
# prism's own generator is a Ruby script, so the build needs a working Ruby
# on PATH before it can build Ruby. Debian's own packaged interpreter clears
# the >=3.1.0 floor and is gone before this script exits, never reaching the
# deploy image (apt installs it to /usr, not /usr/local, and only /usr/local
# from this step is copied into deploy).
apt-get install -y --no-install-recommends ruby
BASERUBY=/usr/bin/ruby
./autogen.sh

# --enable-yjit needs rustc at build time and is the single largest win
# available to this service. --with-jemalloc links it directly rather than
# relying on the LD_PRELOAD the ruby provider bakes into the environment.
CFLAGS="${CFLAGS}" ./configure \
  --prefix="${PREFIX}" \
  --with-baseruby="${BASERUBY}" \
  --enable-yjit \
  --with-jemalloc \
  --disable-install-doc \
  --disable-install-rdoc \
  optflags="${OPTFLAGS}"

# Half the cores, not all of them. Merging to main deploys the bot and the web
# app at once, so two of these run side by side, and -j$(nproc) each puts twice
# the machine's threads of compilers on it while the CI runners are also working.
# Override with RUBOTTY_MAKE_JOBS when building alone.
JOBS="${RUBOTTY_MAKE_JOBS:-$(( $(nproc) / 2 ))}"
[ "${JOBS}" -ge 1 ] || JOBS=1
echo "building ruby with ${JOBS} jobs"

make -j"${JOBS}"
make install

# Preserve the interpreter and statically linked runtime notices in the image.
mkdir -p "${PREFIX}/share/licenses/ruby"
cp COPYING BSDL "${PREFIX}/share/licenses/ruby/"
cp /usr/share/doc/rustc/copyright "${PREFIX}/share/licenses/ruby/Rust-copyright"

# The bootstrap interpreter's job ends here; ${PREFIX}/bin/ruby is the one
# everything from here on uses.
apt-get purge -y --auto-remove ruby

cd /
rm -rf "/tmp/ruby-${RUBY_VERSION}"

# Fail here rather than in production if YJIT did not actually build. ruby -v
# only advertises YJIT once it is switched on, so ask the VM directly.
"${PREFIX}/bin/ruby" -v
"${PREFIX}/bin/ruby" --yjit -e "abort(%q[yjit did not build]) unless RubyVM::YJIT.enabled?"
echo "ruby built with yjit, optflags ${OPTFLAGS}"
