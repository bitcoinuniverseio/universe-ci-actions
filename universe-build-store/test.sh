#!/usr/bin/env bash
# Behaviour tests for build-store.sh. Runs on Linux (CI) and macOS.
#   bash universe-build-store/test.sh
set -euo pipefail

script="$(cd "$(dirname "$0")" && pwd)/build-store.sh"
root="$(mktemp -d)"
trap 'rm -rf "${root}"' EXIT
pass=0
fail=0

export GITHUB_REPOSITORY=bitcoinuniverseio/fixture
export GITHUB_EVENT_NAME=push
export UNIVERSE_BUILD_STORE="${root}/store"
export RUNNER_OS=Linux RUNNER_ARCH=X64

ok() { pass=$((pass + 1)); echo "ok   - $1"; }
no() { fail=$((fail + 1)); echo "FAIL - $1"; }
check() { if eval "$2"; then ok "$1"; else no "$1"; fi; }

# run MODE [extra env assignments...]; sets $state, $key, $log
run() {
  local mode="$1"; shift
  local out="${root}/out.$$"
  : > "${out}"
  set +e
  log="$(env GITHUB_OUTPUT="${out}" BUILD_PATH=dist BUILD_MODE="${mode}" "$@" bash "${script}" 2>&1)"
  rc=$?
  set -e
  state="$(sed -n 's/^state=//p' "${out}" | tail -n1)"
  key="$(sed -n 's/^key=//p' "${out}" | tail -n1)"
  rm -f "${out}"
}

repo="${root}/repo"
mkdir -p "${repo}/src"
cd "${repo}"
git init -q
git config user.email t@example.invalid
git config user.name test
echo 'console.log(1)' > src/a.js
echo '{"lockfileVersion":3}' > package-lock.json
echo '# readme' > README.md
git add -A && git commit -qm one
export GITHUB_SHA="$(git rev-parse HEAD)"
build() { rm -rf dist; mkdir -p dist/assets; cat src/a.js package-lock.json > dist/assets/app.js; head -c 200000 /dev/urandom > dist/assets/blob.bin; }
INPUTS=$'src\npackage-lock.json'

echo "# commit mode (v1-compatible default)"
build; run save
check "save stores" '[ "${state}" = stored ] && [ ${rc} -eq 0 ]'
k1="${key}"
want="$(cd dist && find . -type f -exec cat {} + | (sha256sum 2>/dev/null || shasum -a 256))"
rm -rf dist; run restore
check "restore hits" '[ "${state}" = hit ] && [ ${rc} -eq 0 ]'
check "restored bytes are identical" '[ "$(cd dist && find . -type f -exec cat {} + | (sha256sum 2>/dev/null || shasum -a 256))" = "${want}" ]'
run save
check "second save is a no-op on an existing entry" '[ "${state}" = stored ] && echo "${log}" | grep -q "BUILD PRESENT"'
GITHUB_SHA=0000000000000000000000000000000000000001 run restore
check "another commit misses in commit mode" '[ "${state}" = miss ] && [ ${rc} -ne 0 ]'

echo "# content mode"
build; run save BUILD_INPUTS="${INPUTS}"
check "content save stores" '[ "${state}" = stored ]'
kc="${key}"
check "content key differs from commit key" '[ "${kc}" != "${k1}" ]'
echo more >> README.md; git commit -qam readme
GITHUB_SHA="$(git rev-parse HEAD)" run restore BUILD_INPUTS="${INPUTS}"
check "irrelevant commit reuses the output" '[ "${state}" = hit ] && [ "${key}" = "${kc}" ]'
echo 'console.log(2)' > src/a.js
run restore BUILD_INPUTS="${INPUTS}"
check "changed source misses" '[ "${state}" = miss ]'
git checkout -q src/a.js
echo '{"lockfileVersion":3,"x":1}' > package-lock.json
run restore BUILD_INPUTS="${INPUTS}"
check "changed lockfile misses" '[ "${state}" = miss ]'
git checkout -q package-lock.json
echo 'export const gen = 1' > src/generated.js
run restore BUILD_INPUTS="${INPUTS}"
check "untracked generated input changes the key" '[ "${state}" = miss ]'
rm -f src/generated.js
run restore BUILD_INPUTS="${INPUTS}" BUILD_COMMAND="npm run build -- --mode staging"
check "changed build command misses" '[ "${state}" = miss ]'
run restore BUILD_INPUTS="${INPUTS}" BUILD_EMBEDS_COMMIT=true
check "embeds-commit puts the commit back in the key" '[ "${state}" = miss ]'
run restore BUILD_INPUTS="nothing-matches-this"
check "pathspec matching nothing is an error, not a silent key" '[ ${rc} -ne 0 ] && echo "${log}" | grep -q "matched no files"'

echo "# environment identity"
build; run save BUILD_INPUTS="${INPUTS}" BUILD_ENV_KEYS="VITE_API_ORIGIN" VITE_API_ORIGIN=https://secret-origin.example
ke="${key}"
check "env value is never logged" '! echo "${log}" | grep -q "secret-origin"'
run restore BUILD_INPUTS="${INPUTS}" BUILD_ENV_KEYS="VITE_API_ORIGIN" VITE_API_ORIGIN=https://other.example
check "different env value misses" '[ "${state}" = miss ] && [ "${key}" != "${ke}" ]'
run restore BUILD_INPUTS="${INPUTS}" BUILD_ENV_KEYS="VITE_API_ORIGIN" VITE_API_ORIGIN=https://secret-origin.example
check "same env value hits" '[ "${state}" = hit ]'
run restore BUILD_INPUTS="${INPUTS}" BUILD_ENV_KEYS="bad-name"
check "invalid env-keys entry is rejected" '[ ${rc} -ne 0 ]'

echo "# trust tiers"
build; GITHUB_EVENT_NAME=pull_request run save BUILD_INPUTS="${INPUTS}" BUILD_COMMAND=pr-only
kp="${key}"
check "pull request writes to the pr tier" 'case "${kp}" in build-v2-pr-*) true;; *) false;; esac'
run restore BUILD_INPUTS="${INPUTS}" BUILD_COMMAND=pr-only
check "trusted job never restores a pr entry" '[ "${state}" = miss ]'
GITHUB_EVENT_NAME=pull_request run restore BUILD_INPUTS="${INPUTS}"
check "pull request restores a trusted entry" '[ "${state}" = hit ]'

echo "# corrupt and interrupted entries"
build; run save; arch="${UNIVERSE_BUILD_STORE}/${key}.tar.zst"
size="$(wc -c < "${arch}" | tr -d ' ')"
head -c $((size / 2)) "${arch}" > "${arch}.t" && mv "${arch}.t" "${arch}"
echo keep > dist/sentinel
run restore
check "truncated entry is a recoverable miss" '[ "${state}" = miss ] && echo "${log}" | grep -q "failed to extract"'
check "truncated entry was removed" '[ ! -f "${arch}" ]'
check "failed restore leaves the existing directory alone" '[ -f dist/sentinel ]'
build; run save; run restore
check "next save repairs the entry" '[ "${state}" = hit ]'
printf 'garbage' > "${arch}"
run restore
check "garbage entry is a recoverable miss" '[ "${state}" = miss ]'
: > "${UNIVERSE_BUILD_STORE}/.${key}.partial.abc123"
rm -rf dist; run restore
check "an in-flight partial is never read as an entry" '[ "${state}" = miss ]'
rm -f "${UNIVERSE_BUILD_STORE}/.${key}.partial.abc123"
leftovers="$(find . -maxdepth 1 -name '.universe-build-restore.*' | wc -l | tr -d ' ')"
check "failed restores leave no scratch directories" '[ "${leftovers}" = 0 ]'

echo "# concurrent producers"
build
for i in 1 2 3 4; do (run save BUILD_COMMAND=concurrent; echo "${state}" > "${root}/c.${i}") & done
wait
check "all concurrent producers succeed" '[ "$(cat "${root}"/c.* | sort -u)" = stored ]'
rm -rf dist; run restore BUILD_COMMAND=concurrent
check "the surviving entry is valid" '[ "${state}" = hit ] && [ -f dist/assets/app.js ]'
check "no partial files left behind" '[ -z "$(find "${UNIVERSE_BUILD_STORE}" -name "*.partial*")" ]'

echo "# eviction"
rm -rf "${UNIVERSE_BUILD_STORE}"; build
for i in 1 2 3 4; do run save BUILD_COMMAND="evict-${i}"; touch -t "20260101000${i}" "${UNIVERSE_BUILD_STORE}/${key}.tar.zst"; done
k4="${key}"
UNIVERSE_BUILD_STORE_KEEP=2 run save BUILD_COMMAND=evict-5
check "count budget prunes least recently used first" '[ "$(ls "${UNIVERSE_BUILD_STORE}"/*.tar.zst | wc -l | tr -d " ")" = 2 ] && [ -f "${UNIVERSE_BUILD_STORE}/${k4}.tar.zst" ] && [ -f "${UNIVERSE_BUILD_STORE}/${key}.tar.zst" ]'
# An in-flight restore of evict-4: the same lease the restore path takes.
touch -c "${UNIVERSE_BUILD_STORE}/${k4}.tar.zst"; ln "${UNIVERSE_BUILD_STORE}/${k4}.tar.zst" "${UNIVERSE_BUILD_STORE}/.lease.test"
UNIVERSE_BUILD_STORE_MAX_BYTES=1 run save BUILD_COMMAND=evict-6
check "byte budget never removes a leased entry" '[ -f "${UNIVERSE_BUILD_STORE}/${k4}.tar.zst" ] && [ -f "${UNIVERSE_BUILD_STORE}/.lease.test" ] && [ -f "${UNIVERSE_BUILD_STORE}/${key}.tar.zst" ] && [ "$(ls "${UNIVERSE_BUILD_STORE}"/*.tar.zst | wc -l | tr -d " ")" = 2 ]'
rm -f "${UNIVERSE_BUILD_STORE}/.lease.test"
UNIVERSE_BUILD_STORE_MAX_BYTES=1 run save BUILD_COMMAND=evict-7
check "byte budget prunes everything but the new entry once unleased" '[ "$(ls "${UNIVERSE_BUILD_STORE}"/*.tar.zst | wc -l | tr -d " ")" = 1 ] && [ -f "${UNIVERSE_BUILD_STORE}/${key}.tar.zst" ]'
UNIVERSE_BUILD_STORE_MIN_FREE_PCT=101 run save BUILD_COMMAND=evict-8
check "free-space floor skips the save without failing the job" '[ "${state}" = skipped ] && [ ${rc} -eq 0 ]'

echo "# compression budget"
UNIVERSE_BUILD_STORE_THREADS=2 UNIVERSE_BUILD_STORE_LEVEL=5 run save BUILD_COMMAND=threads
check "thread and level overrides are honoured" 'echo "${log}" | grep -q "zstd -5 -T2"'
run save BUILD_COMMAND=threads-default
check "default never uses -T0" 'echo "${log}" | grep -Eq "zstd -3 -T[1-4],"'

echo "# input validation"
run save BUILD_PATH=/etc
check "absolute path is rejected" '[ ${rc} -ne 0 ]'
run save BUILD_PATH=../outside
check "parent path is rejected" '[ ${rc} -ne 0 ]'
ro="${root}/ro"; mkdir -p "${ro}"; chmod 500 "${ro}"
UNIVERSE_BUILD_STORE="${ro}/store" run save
check "unwritable store warns and passes on save" '[ "${state}" = unavailable ] && [ ${rc} -eq 0 ]'
UNIVERSE_BUILD_STORE="${ro}/store" run restore
check "unwritable store fails restore" '[ "${state}" = unavailable ] && [ ${rc} -ne 0 ]'
chmod 700 "${ro}"

echo
echo "${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
