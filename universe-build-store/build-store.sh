#!/usr/bin/env bash
# Content-addressed build output reuse on a persistent runner fleet.
#
# Contract: docs/universe-build-store.md. Kept compatible with bash 3.2 and BSD
# userland so the behaviour tests in universe-build-store/test.sh also run on a
# developer's Mac; the fleet itself runs GNU tools.
set -euo pipefail

BUILD_INPUTS="${BUILD_INPUTS:-}"
BUILD_COMMAND="${BUILD_COMMAND:-}"
BUILD_ENV_KEYS="${BUILD_ENV_KEYS:-}"
BUILD_EMBEDS_COMMIT="${BUILD_EMBEDS_COMMIT:-false}"
KEY_SUFFIX="${KEY_SUFFIX:-}"

output() { if [ -n "${GITHUB_OUTPUT:-}" ]; then printf '%s\n' "$1" >> "${GITHUB_OUTPUT}"; fi; }
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi; }
now_ms() {
  local t
  t="$(date +%s%N 2>/dev/null || true)"
  case "${t}" in ''|*N*) echo $(( $(date +%s) * 1000 )) ;; *) echo $(( t / 1000000 )) ;; esac
}
# mtime, hard-link count, bytes, path. GNU first, BSD second.
stat_line() { stat -c '%Y %h %s %n' "$1" 2>/dev/null || stat -f '%m %l %z %N' "$1"; }

case "${BUILD_PATH:-}" in
  ''|/*|..|../*|*/..|*/../*)
    echo "::error::path must be a relative directory inside the workspace, got '${BUILD_PATH:-}'."
    exit 1 ;;
esac
BUILD_PATH="${BUILD_PATH%/}"

case "${RUNNER_ARCH:-X64}" in
  X64) arch=x64 ;;
  ARM64) arch=arm64 ;;
  *) arch="$(printf '%s' "${RUNNER_ARCH}" | tr '[:upper:]' '[:lower:]')" ;;
esac
os="$(printf '%s' "${RUNNER_OS:-Linux}" | tr '[:upper:]' '[:lower:]')"

# ---------------------------------------------------------------------------
# Identity: every input that can change the bytes of the output.
# ---------------------------------------------------------------------------

osrel=""
if [ -r /etc/os-release ]; then
  osrel="$( . /etc/os-release; printf '%s-%s' "${ID:-}" "${VERSION_ID:-}" )"
fi
libc="$(getconf GNU_LIBC_VERSION 2>/dev/null || (ldd --version 2>&1 | head -n1) 2>/dev/null || true)"
node_v="$(node --version 2>/dev/null || echo none)"
npm_v="$(npm --version 2>/dev/null || echo none)"

if [ -n "${BUILD_INPUTS}" ]; then
  mode=content
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "::error::inputs needs a git checkout to resolve its pathspecs."
    exit 1
  fi
  set --
  while IFS= read -r spec; do
    spec="$(printf '%s' "${spec}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -n "${spec}" ] && set -- "$@" "${spec}"
  done <<EOF
${BUILD_INPUTS}
EOF
  # Tracked and untracked-but-not-ignored files, hashed by their working-tree
  # content, so generated inputs written by an earlier step count too.
  listing="$(git ls-files --cached --others --exclude-standard -- "$@" | LC_ALL=C sort -u)"
  present=""
  while IFS= read -r f; do
    [ -n "${f}" ] && [ -f "${f}" ] && present="${present}${f}
"
  done <<EOF
${listing}
EOF
  if [ -z "${present}" ]; then
    echo "::error::inputs matched no files: $*"
    exit 1
  fi
  input_files="$(printf '%s' "${present}" | grep -c .)"
  sources="$(printf '%s' "${present}" | git hash-object --stdin-paths | paste -d' ' - <(printf '%s' "${present}") | sha256)"
  commit_line=""
  if [ "${BUILD_EMBEDS_COMMIT}" = true ]; then commit_line="commit=${GITHUB_SHA:?}"; fi
else
  mode=commit
  input_files=0
  sources=""
  commit_line="commit=${GITHUB_SHA:?}"
fi

# Values of output-affecting environment variables enter the key only as one
# opaque digest. Neither the values nor that digest are logged or stored.
env_names=""
env_material=""
for name in ${BUILD_ENV_KEYS}; do
  case "${name}" in *[!A-Za-z0-9_]*|[0-9]*) echo "::error::env-keys entry '${name}' is not a variable name."; exit 1 ;; esac
  env_names="${env_names} ${name}"
  if [ -n "${!name+set}" ]; then env_material="${env_material}${name}=$(printf '%s' "${!name}" | sha256)
"; else env_material="${env_material}${name} unset
"; fi
done
env_digest="$(printf '%s' "${env_material}" | sha256)"

identity="schema=universe-build-store-v2
repository=${GITHUB_REPOSITORY:?}
path=${BUILD_PATH}
suffix=${KEY_SUFFIX}
mode=${mode}
${commit_line}
sources=${sources}
command=${BUILD_COMMAND}
env=${env_names# }
os=${os} arch=${arch} release=${osrel} libc=${libc}
node=${node_v} npm=${npm_v}"
digest="$(printf '%s\nenvdigest=%s' "${identity}" "${env_digest}" | sha256 | cut -c1-32)"

# Writers are split by trust. A pull request job can read what trusted
# (push, schedule, dispatch, merge_group) jobs stored, never the other way.
case "${GITHUB_EVENT_NAME:-}" in
  pull_request|pull_request_target) tier=pr ;;
  *) tier=trusted ;;
esac
repo_slug="${GITHUB_REPOSITORY//\//-}"
key="build-v2-${tier}-${repo_slug}-${digest}"
candidates="${key}"
[ "${tier}" = pr ] && candidates="${key} build-v2-trusted-${repo_slug}-${digest}"

echo "Build store identity (${mode} mode, ${input_files} input files):"
printf '%s\n' "${identity}" | sed 's/^/  /'
output "key=${key}"

# ---------------------------------------------------------------------------
# Store location and resource budget.
# ---------------------------------------------------------------------------

store="${UNIVERSE_BUILD_STORE:-}"
if [ -z "${store}" ]; then
  store="$(dirname "$(npm config get cache 2>/dev/null || echo "${HOME}/.npm")")/.universe-build-store"
fi
if ! mkdir -p "${store}" 2>/dev/null || [ ! -w "${store}" ]; then
  echo "::warning::Build store ${store} is not writable on ${RUNNER_NAME:-unknown}; this runner cannot share build output."
  output "state=unavailable"
  [ "${BUILD_MODE}" = restore ] && exit 1
  exit 0
fi

# Compression threads: this job's fair share of the host, never the whole host.
# 48 runner services share one PrimCast host, so -T0 in every job oversubscribes
# it as soon as a few saves coincide.
threads() {
  if [ -n "${UNIVERSE_BUILD_STORE_THREADS:-}" ]; then echo "${UNIVERSE_BUILD_STORE_THREADS}"; return; fi
  local n q p jobs
  n="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
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
level="${UNIVERSE_BUILD_STORE_LEVEL:-3}"
keep="${UNIVERSE_BUILD_STORE_KEEP:-40}"
max_bytes="${UNIVERSE_BUILD_STORE_MAX_BYTES:-21474836480}"   # 20 GiB
min_free_pct="${UNIVERSE_BUILD_STORE_MIN_FREE_PCT:-10}"

free_pct() { df -Pk "${store}" | awk 'NR==2 { if ($2 > 0) printf "%d", $4 * 100 / $2; else print 100 }'; }
free_kb() { df -Pk "${store}" | awk 'NR==2 { print $4 }'; }

# Least recently used first. An archive with more than one hard link has a
# restore in flight (its lease) and is never removed, nor is the one just
# written, so cleanup can't pull an entry out from under an active job.
prune() {
  local protect="$1" listing count bytes mtime links size path
  find "${store}" -maxdepth 1 -name '.*.partial.*' -mmin +120 -exec rm -f {} + 2>/dev/null || true
  find "${store}" -maxdepth 1 -name '*.partial' -mmin +120 -exec rm -f {} + 2>/dev/null || true
  find "${store}" -maxdepth 1 -name '.lease.*' -mmin +120 -exec rm -f {} + 2>/dev/null || true
  listing="$(find "${store}" -maxdepth 1 -name '*.tar.zst' 2>/dev/null | while IFS= read -r a; do stat_line "${a}"; done | sort -n)"
  count="$(printf '%s' "${listing}" | grep -c . || true)"
  bytes="$(printf '%s' "${listing}" | awk '{ s += $3 } END { printf "%d", s }')"
  while IFS=' ' read -r mtime links size path; do
    [ -n "${path:-}" ] || continue
    if [ "${count}" -le "${keep}" ] && [ "${bytes}" -le "${max_bytes}" ] && [ "$(free_pct)" -ge "${min_free_pct}" ]; then break; fi
    [ "${path}" = "${protect}" ] && continue
    [ "${links}" -gt 1 ] && continue
    rm -f "${path}" && echo "BUILD PRUNED: ${path} (${size} bytes)"
    count=$(( count - 1 )); bytes=$(( bytes - size ))
  done <<EOF
${listing}
EOF
}

# ---------------------------------------------------------------------------
# Restore.
# ---------------------------------------------------------------------------

if [ "${BUILD_MODE}" = restore ]; then
  for candidate in ${candidates}; do
    archive="${store}/${candidate}.tar.zst"
    lease="${store}/.lease.${candidate}.$$.${RANDOM}"
    # The hard link is the lease: pruning skips multiply linked archives, and
    # the bytes stay readable even if the name is replaced mid-restore. Touch
    # first: the lease shares the archive's mtime, and stale-lease cleanup goes
    # by mtime, so an untouched old archive would lose its lease at once.
    [ -f "${archive}" ] || continue
    touch -c "${archive}" 2>/dev/null || true
    ln "${archive}" "${lease}" 2>/dev/null || continue
    started="$(now_ms)"
    parent="$(dirname "${BUILD_PATH}")"
    mkdir -p "${parent}"
    scratch="$(mktemp -d "${parent}/.universe-build-restore.XXXXXX")"
    if tar --use-compress-program='zstd -d -q' -C "${scratch}" -xf "${lease}" 2>"${scratch}.err" && [ -d "${scratch}/${BUILD_PATH}" ]; then
      rm -rf "${BUILD_PATH}"
      mv "${scratch}/${BUILD_PATH}" "${BUILD_PATH}"
      rm -rf "${scratch}" "${scratch}.err"
      touch "${archive}" 2>/dev/null || true
      rm -f "${lease}"
      echo "BUILD HIT: ${candidate} ($(( $(now_ms) - started )) ms)"
      output "state=hit"
      output "source=${candidate}"
      exit 0
    fi
    # Corrupt or truncated entry: a recoverable miss. Drop it only if it is
    # still the same file, so a good replacement written meanwhile survives.
    echo "::warning::Build store entry ${candidate} failed to extract and was discarded: $(head -c 300 "${scratch}.err" 2>/dev/null)"
    [ "${archive}" -ef "${lease}" ] && rm -f "${archive}"
    rm -rf "${scratch}" "${scratch}.err" "${lease}"
  done
  echo "BUILD MISS: ${key}"
  output "state=miss"
  exit 1
fi

# ---------------------------------------------------------------------------
# Save.
# ---------------------------------------------------------------------------

if [ ! -d "${BUILD_PATH}" ]; then
  echo "::error::Nothing to store at ${BUILD_PATH}."
  exit 1
fi

archive="${store}/${key}.tar.zst"
if [ -f "${archive}" ]; then
  # Same inputs already stored by another job: identical bytes by contract.
  touch "${archive}" 2>/dev/null || true
  echo "BUILD PRESENT: ${archive}"
  output "state=stored"
  exit 0
fi

need_kb="$(du -sk "${BUILD_PATH}" | cut -f1)"
prune ""
if [ "$(free_kb)" -lt "${need_kb}" ] || [ "$(free_pct)" -lt "${min_free_pct}" ]; then
  echo "::warning::Build store ${store} is below its ${min_free_pct}% free-space floor; not storing ${BUILD_PATH}."
  output "state=skipped"
  exit 0
fi

t="$(threads)"
started="$(now_ms)"
staging="$(mktemp "${store}/.${key}.partial.XXXXXX")"
if ! tar --use-compress-program="zstd -q -${level} -T${t}" -cf "${staging}" "${BUILD_PATH}"; then
  rm -f "${staging}"
  echo "::warning::Could not write the build store archive for ${BUILD_PATH}; nothing stored."
  output "state=skipped"
  exit 0
fi
chmod a+r "${staging}" 2>/dev/null || true
mv -f "${staging}" "${archive}"
size="$(stat_line "${archive}" | cut -d' ' -f3)"
echo "BUILD STORED: ${archive} (${size} bytes, zstd -${level} -T${t}, $(( $(now_ms) - started )) ms)"
output "state=stored"
prune "${archive}"
