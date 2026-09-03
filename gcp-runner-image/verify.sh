#!/usr/bin/env bash
# Fails the build if the image does not carry exactly what CI expects. An image
# that boots but is missing a toolchain would show up as a job-time failure on
# every runner it produces, so it is caught here instead.
set -euo pipefail
fail=0
check() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "ok    $label = $actual"
  else
    echo "FAIL  $label expected $expected, got $actual" >&2
    fail=1
  fi
}
present() {
  if command -v "$1" >/dev/null 2>&1; then echo "ok    $1 present"
  else echo "FAIL  $1 missing" >&2; fail=1; fi
}

check node "v${NODE_VERSION}" "$(node --version)"
check npm  "${NPM_VERSION}"   "$(npm --version)"
check docker "${DOCKER_VERSION}" "$(docker --version | sed -E 's/.*version ([0-9.]+).*/\1/')"
check rustc  "${RUST_VERSION}"   "$(/usr/local/cargo/bin/rustc --version | awk '{print $2}')"

for tool in git gh jq curl wget unzip cmake pkg-config clang deno uv pnpm yarn cargo docker-compose; do
  case "$tool" in
    cargo)          command -v /usr/local/cargo/bin/cargo >/dev/null && echo "ok    cargo present" || { echo "FAIL  cargo missing" >&2; fail=1; } ;;
    docker-compose) docker compose version >/dev/null 2>&1 && echo "ok    docker compose present" || { echo "FAIL  docker compose missing" >&2; fail=1; } ;;
    *)              present "$tool" ;;
  esac
done

docker buildx version >/dev/null 2>&1 && echo "ok    buildx present" || { echo "FAIL  buildx missing" >&2; fail=1; }

# Runner host pieces added by runner.sh.
check runner "${RUNNER_VERSION}" "$(cat /opt/actions-runner/.universe-runner-version)"
check playwright "${PLAYWRIGHT_VERSION}" "$(cat /ms-playwright/.universe-playwright-version)"
[ -x /opt/actions-runner/run.sh ] && echo "ok    actions runner present" || { echo "FAIL  actions runner missing" >&2; fail=1; }
ls -d /ms-playwright/chromium-* >/dev/null 2>&1 && echo "ok    chromium present" || { echo "FAIL  chromium missing" >&2; fail=1; }
systemctl is-enabled universe-runner.service >/dev/null 2>&1 && echo "ok    universe-runner.service enabled" || { echo "FAIL  universe-runner.service not enabled" >&2; fail=1; }
systemctl is-enabled google-cloud-ops-agent >/dev/null 2>&1 && echo "ok    ops agent enabled" || { echo "FAIL  ops agent not enabled" >&2; fail=1; }
id runner >/dev/null 2>&1 && id -nG runner | grep -qw docker && echo "ok    runner user in docker group" || { echo "FAIL  runner user misconfigured" >&2; fail=1; }
grep -q '^PLAYWRIGHT_BROWSERS_PATH=/ms-playwright$' /etc/environment && echo "ok    PLAYWRIGHT_BROWSERS_PATH exported" || { echo "FAIL  PLAYWRIGHT_BROWSERS_PATH missing" >&2; fail=1; }
[ "$(stat -c %U /ms-playwright)" = runner ] && echo "ok    /ms-playwright owned by runner" || { echo "FAIL  /ms-playwright not owned by runner" >&2; fail=1; }
command -v pwsh >/dev/null 2>&1 && pwsh -NoProfile -Command '$PSVersionTable.PSVersion.Major' | grep -q '^7' && echo "ok    pwsh 7 present" || { echo "FAIL  pwsh 7 missing" >&2; fail=1; }
[ "$(stat -c %U /usr/local/rustup)" = runner ] && [ "$(stat -c %U /usr/local/cargo)" = runner ] && echo "ok    rust toolchain owned by runner" || { echo "FAIL  rust toolchain not owned by runner" >&2; fail=1; }
[ -x /opt/universe-runner/bootstrap.sh ] && echo "ok    bootstrap present" || { echo "FAIL  bootstrap missing" >&2; fail=1; }

exit "$fail"
