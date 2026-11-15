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

# zstd threads for a save: this job's fair share of the host, never -T0. One
# PrimCast host runs 48 runner services, so -T0 in every job oversubscribes it
# whenever a few cold installs coincide. Level 3 measured best on total
# save+restore time (docs/universe-build-store.md, "Compression").
store_threads() {
  if [ -n "${UNIVERSE_STORE_THREADS:-}" ]; then echo "${UNIVERSE_STORE_THREADS}"; return; fi
  local n q p jobs
  n="$(nproc 2>/dev/null || echo 1)"
  if [ -r /sys/fs/cgroup/cpu.max ]; then
    read -r q p < /sys/fs/cgroup/cpu.max || true
    if [ "${q:-max}" != max ] && [ "${p:-0}" -gt 0 ]; then
      q=$(( (q + p - 1) / p )); [ "${q}" -lt "${n}" ] && n="${q}"
    fi
  fi
  jobs="$(pgrep -f 'Runner\.Worker' 2>/dev/null | wc -l | tr -d ' ')"
  [ "${jobs:-0}" -gt 1 ] && n=$(( n / jobs ))
  [ "${n}" -gt 4 ] && n=4
  [ "${n}" -lt 1 ] && n=1
  echo "${n}"
}

# Warm path 1: the exact tree already sits on this runner's own disk. A corrupt
# or truncated archive, or one pruned between the check and the read, is a
# recoverable miss: drop it and fall through to the cold path instead of
# failing every job on this host that shares the lockfile.
if [ -n "${archive}" ] && [ -f "${archive}" ]; then
  touch -c "${archive}" 2>/dev/null || true
  rm -rf node_modules
  if tar --use-compress-program='zstd -d -q' -xf "${archive}"; then
    state=hit
    report
    exit 0
  fi
  echo "::warning::Dependency store entry ${DEPENDENCY_KEY} failed to extract and was discarded; installing instead."
  rm -f "${archive}"
  rm -rf node_modules
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

# A lockfile can resolve to nothing to install, and npm then creates no
# node_modules at all. There is no tree to store and nothing for a later job
# to restore, so say so and stop rather than failing on a missing directory.
if [ ! -d node_modules ]; then
  echo "NO DEPENDENCIES: the lockfile installs nothing, so there is no tree to reuse."
  state=empty
  report
  exit 0
fi

if [ -n "${archive}" ]; then
  # Written to a private temporary name and moved into place, so a second job
  # racing on the same key never reads a half-written archive.
  staging="${archive}.$$.partial"
  threads="$(store_threads)"
  level="${UNIVERSE_STORE_LEVEL:-3}"
  if tar --use-compress-program="zstd -q -${level} -T${threads}" -cf "${staging}" node_modules; then
    mv -f "${staging}" "${archive}"
    echo "DEPENDENCY STORED: ${archive} ($(du -h "${archive}" | cut -f1), zstd -${level} -T${threads})"
  else
    # A full disk must not fail a job whose install already succeeded.
    rm -f "${staging}"
    echo "::warning::Could not write the dependency store archive; this install is not shared."
  fi

  # Least-recently-used pruning keeps the store bounded without a scheduled job.
  # Every hit touches its archive, so an active dependency identity survives.
  keep="${UNIVERSE_DEP_STORE_KEEP:-24}"
  find "${DEPENDENCY_STORE}" -maxdepth 1 -name '*.tar.zst' -printf '%T@ %p\n' 2>/dev/null |
    sort -rn | tail -n "+$((keep + 1))" | cut -d' ' -f2- |
    while read -r stale; do rm -f "${stale}"; echo "DEPENDENCY PRUNED: ${stale}"; done
  find "${DEPENDENCY_STORE}" -maxdepth 1 -name '*.partial' -mmin +120 -delete 2>/dev/null || true
fi

report
