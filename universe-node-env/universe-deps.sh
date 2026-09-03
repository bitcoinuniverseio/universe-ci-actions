#!/usr/bin/env bash
# universe-deps: exact, pre-warmed Node.js dependency trees for permanent
# Universe runners.
#
# A dependency tree is identified by everything that can change its content:
# OS, CPU architecture, libc, Node.js version and ABI, npm version, install
# flags, .npmrc, package.json, every lockfile and every workspace package.json.
# One immutable snapshot per identity lives in the shared store on the host.
# A job that needs it gets a private hard-link farm of that snapshot in its
# own workspace: thousands of files in well under a second, no network, and
# no shared writable node_modules between runners. The snapshot's files are
# read-only, so a job cannot alter what the next job receives; every
# activation verifies the snapshot's metadata manifest before linking it.
#
# A tree is built at most once per host: the first job (or the warmer) holds
# an exclusive lock while `npm ci` runs, every other job waits for the ready
# marker and then links the same tree.
#
#   universe-deps key        print the dependency key of the working directory
#   universe-deps activate   link the warm tree into the working directory,
#                            building it once first when it does not exist
#   universe-deps build      build the tree without linking it (warmers)
#   universe-deps verify     verify the snapshot of the working directory's key
#   universe-deps status     summarize the store
#   universe-deps prune      apply the retention policy
#
# Environment: UNIVERSE_DEP_STORE (store root; defaults next to the npm cache),
# UNIVERSE_DEP_STORE_KEEP (trees kept, default 600), NPM_INSTALL_ARGS (extra
# flags for the one cold install), UNIVERSE_DEPS_VERIFY (full|none, default full).
set -euo pipefail

UNIVERSE_DEPS_VERSION=3

log() { printf '%s\n' "$*"; }
die() { printf 'RUNNER PROVISIONING ERROR: %s\n' "$*" >&2; exit 1; }
summary() { [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && printf -- '- %s\n' "$*" >> "${GITHUB_STEP_SUMMARY}" || true; }
now() { date +%s; }

command -v node >/dev/null || die "node is not on PATH; the runner toolchain is not provisioned"
command -v npm >/dev/null || die "npm is not on PATH; the runner toolchain is not provisioned"

store="${UNIVERSE_DEP_STORE:-}"
if [[ -z "${store}" ]]; then
  store="$(dirname "$(npm config get cache)")/.universe-dep-store"
fi
trees="${store}/trees"
locks="${store}/locks"
tmp="${store}/tmp"
keep="${UNIVERSE_DEP_STORE_KEEP:-600}"
verify_mode="${UNIVERSE_DEPS_VERIFY:-full}"

ensure_store() {
  mkdir -p "${trees}" "${locks}" "${tmp}" 2>/dev/null || die "dependency store ${store} cannot be created"
  [[ -w "${trees}" && -w "${locks}" && -w "${tmp}" ]] || die "dependency store ${store} is not writable by $(id -un)"
}

# ---------------------------------------------------------------------------
# Identity
# ---------------------------------------------------------------------------
platform() {
  local os arch libc
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  case "$(uname -m)" in x86_64) arch=x64 ;; aarch64|arm64) arch=arm64 ;; *) arch="$(uname -m)" ;; esac
  libc=none
  if [[ "${os}" == linux ]]; then
    if ldd --version 2>&1 | head -n 1 | grep -qi musl; then libc=musl; else libc=glibc; fi
  fi
  printf '%s %s %s' "${os}" "${arch}" "${libc}"
}

lockfiles() {
  local f
  for f in package-lock.json npm-shrinkwrap.json; do [[ -f "${f}" ]] && printf '%s\n' "${f}"; done
  return 0
}

# Workspace package.json files, from the lockfile: npm validates every one of
# them against the lock, so each is part of the identity.
workspace_manifests() {
  local lock
  lock="$(lockfiles | head -n 1)"
  [[ -n "${lock}" ]] || return 0
  node -e '
    const lock = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const out = new Set();
    for (const key of Object.keys(lock.packages || {})) {
      if (key === "" || key.includes("node_modules/")) continue;
      if (require("fs").existsSync(require("path").join(key, "package.json"))) out.add(key + "/package.json");
    }
    process.stdout.write([...out].sort().join("\n"));
  ' "${lock}"
}

compute_key() {
  [[ -f package.json ]] || die "no package.json in $(pwd)"
  [[ -n "$(lockfiles)" ]] || die "no package-lock.json or npm-shrinkwrap.json in $(pwd)"
  local os arch libc node_version node_abi npm_version fingerprint
  read -r os arch libc <<<"$(platform)"
  node_version="$(node --version | tr -d v)"
  node_abi="$(node -p 'process.versions.modules')"
  npm_version="$(npm --version)"
  fingerprint="$(
    {
      echo "schema=${UNIVERSE_DEPS_VERSION}"
      echo "os=${os} arch=${arch} libc=${libc}"
      echo "node=${node_version} abi=${node_abi} npm=${npm_version}"
      echo "flags=${NPM_INSTALL_ARGS:-}"
      sha256sum package.json
      [[ ! -f .npmrc ]] || sha256sum .npmrc
      # shellcheck disable=SC2046
      sha256sum $(lockfiles)
      local m
      while IFS= read -r m; do [[ -n "${m}" ]] || continue; sha256sum "${m}"; done <<<"$(workspace_manifests)"
    } | sha256sum | cut -d' ' -f1
  )"
  printf 'universe-deps-v%s-%s-%s-%s-node%s-abi%s-npm%s-%s' \
    "${UNIVERSE_DEPS_VERSION}" "${os}" "${arch}" "${libc}" "${node_version}" "${node_abi}" "${npm_version}" "${fingerprint:0:32}"
}

# ---------------------------------------------------------------------------
# Snapshot helpers
# ---------------------------------------------------------------------------
# node_modules directories of the working directory that are not themselves
# inside another node_modules (workspaces install nested trees).
tree_dirs_in_cwd() {
  find . -name node_modules -type d -prune -print 2>/dev/null | sed 's|^\./||' | LC_ALL=C sort
}

write_manifest() { # <snapshot dir>
  ( cd "$1/tree" && find . -type f -printf '%m %s %T@ %p\n' | LC_ALL=C sort ) > "$1/manifest.txt"
}

snapshot_ok() { # <snapshot dir>
  [[ -f "$1/ready" && -f "$1/manifest.txt" && -f "$1/dirs.txt" && -d "$1/tree" ]]
}

verify_snapshot() { # <snapshot dir>; prints nothing, returns 1 on drift
  local snap="$1" current
  snapshot_ok "${snap}" || return 1
  [[ "${verify_mode}" == none ]] && return 0
  current="$(cd "${snap}/tree" && find . -type f -printf '%m %s %T@ %p\n' | LC_ALL=C sort | sha256sum | cut -d' ' -f1)"
  [[ "${current}" == "$(sha256sum < "${snap}/manifest.txt" | cut -d' ' -f1)" ]]
}

same_filesystem() { [[ "$(stat -c %d "$1")" == "$(stat -c %d "$2")" ]]; }

link_into_cwd() { # <snapshot dir>
  local snap="$1" dir parent
  while IFS= read -r dir; do
    [[ -n "${dir}" ]] || continue
    rm -rf -- "${dir}"
    parent="$(dirname "${dir}")"
    mkdir -p -- "${parent}"
    if same_filesystem "${snap}/tree" "${parent}"; then
      cp -al -- "${snap}/tree/${dir}" "${dir}"
    else
      cp -a -- "${snap}/tree/${dir}" "${dir}"
    fi
  done < "${snap}/dirs.txt"
}

remove_trees_in_cwd() {
  local dir
  while IFS= read -r dir; do [[ -n "${dir}" ]] && rm -rf -- "${dir}"; done <<<"$(tree_dirs_in_cwd)"
  return 0
}

report_hit() { # <key> <snapshot> <seconds> <source>
  local files
  files="$(wc -l < "$2/manifest.txt")"
  log "DEPENDENCY FINGERPRINT: $1"
  log "DEPENDENCY CACHE: warm"
  log "DEPENDENCY SOURCE: $4"
  log "DEPENDENCY ACTIVATED: ${files} files linked in $3s"
  summary "dependencies warm: ${files} files linked in $3s (\`$1\`)"
}

# ---------------------------------------------------------------------------
# Build: exactly one cold install per identity per host
# ---------------------------------------------------------------------------
build_snapshot() { # <key> <link:true|false>
  local key="$1" link="$2" snap="${trees}/$1" started staging dir downloads install_log
  ensure_store
  exec 9>"${locks}/${key}.lock"
  log "DEPENDENCY FINGERPRINT: ${key}"
  if ! flock -n -x 9; then
    log "DEPENDENCY CACHE: cold, another job is building this fingerprint; waiting"
    flock -w "${UNIVERSE_DEPS_LOCK_WAIT:-2400}" -x 9 || die "timed out waiting for ${key} to be built"
  fi
  if verify_snapshot "${snap}"; then
    # Built by whoever held the lock before us.
    flock -u 9
    activate_snapshot "${key}" "${link}" "local warm state (built by another job)"
    return 0
  fi
  if [[ -d "${snap}" ]]; then
    log "DEPENDENCY SNAPSHOT INVALID: rebuilding ${key}"
    mv -- "${snap}" "${tmp}/invalid.${key}.$(now).$$"
  fi
  log "DEPENDENCY CACHE: cold"
  log "DEPENDENCY SOURCE: refresh required (one npm ci for this fingerprint, then reused by every job on this host)"
  started="$(now)"
  remove_trees_in_cwd
  install_log="${tmp}/install.${key}.$$.log"
  # --prefer-offline uses the host's content cache without revalidation; the
  # lockfile integrity hashes still verify every package that is unpacked.
  # shellcheck disable=SC2086
  npm ci --no-audit --no-fund --prefer-offline --loglevel=http ${NPM_INSTALL_ARGS:-} > "${install_log}" 2>&1 || {
    cat "${install_log}"; rm -f "${install_log}"; flock -u 9
    echo "npm ci failed for ${key}" >&2; exit 1
  }
  downloads="$(grep -c 'http fetch GET' "${install_log}" || true)"
  rm -f "${install_log}"
  staging="${tmp}/${key}.$$"
  rm -rf -- "${staging}"
  mkdir -p "${staging}/tree"
  : > "${staging}/dirs.txt"
  while IFS= read -r dir; do
    [[ -n "${dir}" ]] || continue
    mkdir -p -- "${staging}/tree/$(dirname "${dir}")"
    mv -- "${dir}" "${staging}/tree/${dir}"
    printf '%s\n' "${dir}" >> "${staging}/dirs.txt"
  done <<<"$(tree_dirs_in_cwd)"
  if [[ ! -s "${staging}/dirs.txt" ]]; then
    rm -rf -- "${staging}"; flock -u 9
    log "NO DEPENDENCIES: the lockfile installs nothing, so there is no tree to reuse."
    return 0
  fi
  # Read-only inodes: a job's hard links share them, so the snapshot cannot be
  # edited in place by the job that received it.
  find "${staging}/tree" -type f -exec chmod a-w {} +
  write_manifest "${staging}"
  node -e '
    const [dir, key, downloads, repo, runner, npmVersion, schema] = process.argv.slice(1);
    const fs = require("fs");
    const files = fs.readFileSync(dir + "/manifest.txt", "utf8").split("\n").filter(Boolean).length;
    fs.writeFileSync(dir + "/snapshot.json", JSON.stringify({
      schema: Number(schema), key, node: process.versions.node, abi: process.versions.modules,
      npm: npmVersion, files, downloads: Number(downloads),
      repository: repo || null, builtBy: runner || null, builtAt: new Date().toISOString(),
      dirs: fs.readFileSync(dir + "/dirs.txt", "utf8").split("\n").filter(Boolean)
    }, null, 2) + "\n");
  ' "${staging}" "${key}" "${downloads}" "${UNIVERSE_DEPS_REPOSITORY:-${GITHUB_REPOSITORY:-}}" "${RUNNER_NAME:-$(hostname)}" "$(npm --version)" "${UNIVERSE_DEPS_VERSION}"
  touch "${staging}/last-used"
  : > "${staging}/ready"
  mv -T -- "${staging}" "${snap}"
  flock -u 9
  log "DEPENDENCY BUILT: $(wc -l < "${snap}/manifest.txt") files in $(( $(now) - started ))s, network package downloads: ${downloads}"
  summary "dependencies built once: $(wc -l < "${snap}/manifest.txt") files in $(( $(now) - started ))s, ${downloads} network downloads (\`${key}\`)"
  if [[ "${link}" == true ]]; then
    started="$(now)"
    link_into_cwd "${snap}"
    log "DEPENDENCY ACTIVATED: linked in $(( $(now) - started ))s"
  fi
  prune_store
}

activate_snapshot() { # <key> <link:true|false> <source text>
  local key="$1" link="$2" snap="${trees}/$1" started
  exec 8>"${locks}/${key}.lock"
  # A shared lock: many activations may run at once; prune needs the
  # exclusive lock and therefore never removes a tree that is being linked.
  flock -s 8
  touch "${snap}/last-used" 2>/dev/null || true
  started="$(now)"
  if ! verify_snapshot "${snap}"; then
    flock -u 8
    return 1
  fi
  [[ "${link}" == true ]] && link_into_cwd "${snap}"
  flock -u 8
  report_hit "${key}" "${snap}" "$(( $(now) - started ))" "$3"
}

# ---------------------------------------------------------------------------
# Retention: least recently used beyond the keep count, never a tree that is
# being linked (shared lock held) and never one used in the last hour.
# ---------------------------------------------------------------------------
prune_store() {
  local victim key
  [[ -d "${trees}" ]] || return 0
  find "${trees}" -mindepth 2 -maxdepth 2 -name last-used -mmin +60 -printf '%T@ %h\n' 2>/dev/null |
    sort -rn | tail -n "+$((keep + 1))" | cut -d' ' -f2- |
    while IFS= read -r victim; do
      key="$(basename "${victim}")"
      if ( exec 7>"${locks}/${key}.lock"; flock -n -x 7 && mv -T -- "${victim}" "${tmp}/pruned.${key}.$$" ); then
        rm -rf -- "${tmp}/pruned.${key}.$$" "${locks}/${key}.lock"
        log "DEPENDENCY PRUNED: ${key}"
      fi
    done
  # Leftovers: aborted stagings, quarantined snapshots, the archives of the
  # superseded tar.zst format.
  find "${tmp}" -mindepth 1 -maxdepth 1 -mmin +180 -exec rm -rf -- {} + 2>/dev/null || true
  find "${store}" -maxdepth 1 -name '*.tar.zst' -mtime +1 -delete 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
cmd_activate() { # link=true; also used by build with link=false
  local link="${1:-true}" key snap
  ensure_store
  key="$(compute_key)"
  snap="${trees}/${key}"
  if snapshot_ok "${snap}" && activate_snapshot "${key}" "${link}" "local warm state"; then
    return 0
  fi
  build_snapshot "${key}" "${link}"
}

cmd_verify() {
  local key snap
  key="$(compute_key)"
  snap="${trees}/${key}"
  if verify_snapshot "${snap}"; then
    log "DEPENDENCY FINGERPRINT: ${key}"
    log "DEPENDENCY CACHE: warm ($(wc -l < "${snap}/manifest.txt") files, built $(node -p 'require(process.argv[1]).builtAt' "${snap}/snapshot.json" 2>/dev/null || echo unknown))"
  else
    log "DEPENDENCY FINGERPRINT: ${key}"
    log "DEPENDENCY CACHE: cold"
    return 1
  fi
}

cmd_status() {
  local count=0 total=0
  [[ -d "${trees}" ]] && count="$(find "${trees}" -mindepth 1 -maxdepth 1 -type d | wc -l)"
  [[ -d "${trees}" ]] && total="$(find "${trees}" -mindepth 2 -maxdepth 2 -name manifest.txt -exec cat {} + 2>/dev/null | wc -l)"
  log "store=${store}"
  log "version=${UNIVERSE_DEPS_VERSION} keep=${keep} trees=${count} files=${total} writable=$([[ -w "${store}" ]] && echo yes || echo no)"
  [[ -d "${trees}" ]] && find "${trees}" -mindepth 2 -maxdepth 2 -name last-used -printf '%TY-%Tm-%TdT%TH:%TM %h\n' 2>/dev/null | sort -r | head -n "${2:-20}" | sed 's|'"${trees}"'/||'
  return 0
}

case "${1:-}" in
  key) compute_key; echo ;;
  activate) cmd_activate true ;;
  build) cmd_activate false ;;
  verify) cmd_verify ;;
  status) cmd_status ;;
  prune) ensure_store; prune_store ;;
  version) echo "${UNIVERSE_DEPS_VERSION}" ;;
  *) echo "usage: universe-deps key|activate|build|verify|status|prune|version" >&2; exit 64 ;;
esac
