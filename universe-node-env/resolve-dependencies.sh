#!/usr/bin/env bash
# Activates the exact dependency tree for this fingerprint. On a persistent
# runner that is universe-deps: a private hard-link farm of the host's
# immutable snapshot, built once per fingerprint per host under a lock. On an
# ephemeral runner the Actions cache stands in.
set -euo pipefail

started="$(date +%s)"
state=miss

report() {
  local elapsed=$(( $(date +%s) - started ))
  echo "state=${state}" >> "${GITHUB_OUTPUT}"
  echo "DEPENDENCY ${state^^}: ${DEPENDENCY_KEY} in ${elapsed}s"
}

if [ "${PERSISTENT_RUNNER}" = true ]; then
  # The host's copy is the one the warmer used; the bundled copy is the same
  # file at this action's pin and covers a host that predates it.
  deps="${UNIVERSE_DEPS_BIN:-$(dirname "${DEPENDENCY_STORE}")/bin/universe-deps}"
  if [ ! -x "${deps}" ]; then deps="$(dirname "${BASH_SOURCE[0]}")/universe-deps.sh"; fi
  output="$(UNIVERSE_DEP_STORE="${DEPENDENCY_STORE}" NPM_INSTALL_ARGS="${NPM_INSTALL_ARGS:-}" bash "${deps}" activate 2>&1 | tee /dev/stderr)" || exit 1
  case "${output}" in
    *"NO DEPENDENCIES"*) state=empty ;;
    *"DEPENDENCY CACHE: warm"*) state=hit ;;
    *) state=miss ;;
  esac
  report
  exit 0
fi

# Ephemeral runner: actions/cache restored the exact tree for this key.
if [ "${REMOTE_CACHE_HIT:-}" = 'true' ] && [ -d node_modules ]; then
  state=hit
  report
  exit 0
fi

echo "DEPENDENCY MISS: ${DEPENDENCY_KEY}"
rm -rf node_modules
# shellcheck disable=SC2086
npm ci --no-audit --no-fund ${NPM_INSTALL_ARGS:-}
if [ ! -d node_modules ]; then
  echo "NO DEPENDENCIES: the lockfile installs nothing, so there is no tree to reuse."
  state=empty
fi
report
