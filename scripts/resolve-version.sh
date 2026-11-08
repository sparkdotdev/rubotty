#!/bin/sh
# Resolves this build's version from the nearest reachable git tag and bakes
# it into lib/rubotty/resolved_version.txt, since the deploy image carries no
# .git for lib/rubotty/version.rb to read this from at runtime instead.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${ROOT}/lib/rubotty/resolved_version.txt"

DESCRIBED=$(git -C "${ROOT}" describe --tags --match "v[0-9]*" 2>/dev/null || true)

if [ -z "${DESCRIBED}" ]; then
  # Coolify supplies the checked-out commit separately from Git history.
  # Record that identity without requesting credentials or guessing a tag.
  case "${SOURCE_COMMIT:-}" in
    ''|*[!0-9a-f]*) exit 0 ;;
  esac
  [ "${#SOURCE_COMMIT}" -eq 40 ] || exit 0
  FALLBACK=$(ruby -I "${ROOT}/lib" -r rubotty/version -e 'puts Rubotty::VersionResolution::FALLBACK')
  ABBREVIATED=$(printf '%.8s' "${SOURCE_COMMIT}")
  printf '%s+g%s\n' "${FALLBACK}" "${ABBREVIATED}" > "${OUT}"
  exit 0
fi

# On a tagged commit this is just "v0.7.0". Between tags it grows a
# "-N-gSHA" suffix, which becomes semver build metadata once the "v" comes
# off the front: 0.7.0+215-gabc1234 rather than git's own dashed form.
BASE=${DESCRIBED%%-*}
REST=${DESCRIBED#"${BASE}"}
VERSION="${BASE#v}${REST:+"+${REST#-}"}"

printf '%s\n' "${VERSION}" > "${OUT}"
echo "resolved version ${VERSION} from ${DESCRIBED}"
