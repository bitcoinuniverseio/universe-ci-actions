#!/usr/bin/env bash
# Reuses an exact dependency tree when one exists, and installs exactly once
# for a dependency identity that has never been built before.
set -euo pipefail

started="$(date +%s)"
state=miss

report() {
  local elapsed=$(( $(date +%s) - started ))
  echo "state=${state}" >> "${GITHUB_OUTPUT}"
  echo "DEPENDENCY ${state^^}: ${DEPENDENCY_KEY} in ${elapsed}s"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    echo "- dependency ${state} in ${elapsed}s (\`${DEPENDENCY_KEY}\`)" >> "${GITHUB_STEP_SUMMARY}"
  fi
}

archive=""
if [ "${PERSISTENT_RUNNER}" = true ]; then
  archive="${DEPENDENCY_STORE}/${DEPENDENCY_KEY}.tar.zst"
fi

# Warm path 1: the exact tree already sits on this runner's own disk.
if [ -n "${archive}" ] && [ -f "${archive}" ]; then
  rm -rf node_modules
  tar --use-compress-program='zstd -d -T0' -xf "${archive}"
  touch "${archive}"
  state=hit
  report
  exit 0
fi

# Warm path 2: actions/cache already restored the exact tree for this key.
if [ "${REMOTE_CACHE_HIT:-}" = 'true' ] && [ -d node_modules ]; then
  state=hit
  report
  exit 0
fi

# Cold path. This is the only place a dependency download is allowed, and it
# happens once per dependency identity rather than once per job.
echo "DEPENDENCY MISS: ${DEPENDENCY_KEY}"
rm -rf node_modules
# shellcheck disable=SC2086
npm ci --no-audit --no-fund ${NPM_INSTALL_ARGS:-}

if [ -n "${archive}" ]; then
  # Written to a private temporary name and moved into place, so a second job
  # racing on the same key never reads a half-written archive.
  staging="${archive}.$$.partial"
  tar --use-compress-program='zstd -6 -T0' -cf "${staging}" node_modules
  mv -f "${staging}" "${archive}"
  echo "DEPENDENCY STORED: ${archive} ($(du -h "${archive}" | cut -f1))"

  # Least-recently-used pruning keeps the store bounded without a scheduled job.
  # Every hit touches its archive, so an active dependency identity survives.
  keep="${UNIVERSE_DEP_STORE_KEEP:-24}"
  find "${DEPENDENCY_STORE}" -maxdepth 1 -name '*.tar.zst' -printf '%T@ %p\n' 2>/dev/null |
    sort -rn | tail -n "+$((keep + 1))" | cut -d' ' -f2- |
    while read -r stale; do rm -f "${stale}"; echo "DEPENDENCY PRUNED: ${stale}"; done
  find "${DEPENDENCY_STORE}" -maxdepth 1 -name '*.partial' -mmin +120 -delete 2>/dev/null || true
fi

report
