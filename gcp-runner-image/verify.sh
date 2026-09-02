#!/usr/bin/env bash
# Fails the build if the image does not carry exactly what CI expects. An image
# that boots but is missing a toolchain would show up as a job-time failure on
# every runner it produces, so it is caught here instead.
set -euo pipefail
export RUSTUP_HOME="${RUSTUP_HOME:-/usr/local/rustup}"
export CARGO_HOME="${CARGO_HOME:-/usr/local/cargo}"
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

for tool in git gh jq curl wget unzip cmake pkg-config deno uv pnpm yarn cargo docker-compose; do
  case "$tool" in
    cargo)          command -v /usr/local/cargo/bin/cargo >/dev/null && echo "ok    cargo present" || { echo "FAIL  cargo missing" >&2; fail=1; } ;;
    docker-compose) docker compose version >/dev/null 2>&1 && echo "ok    docker compose present" || { echo "FAIL  docker compose missing" >&2; fail=1; } ;;
    *)              present "$tool" ;;
  esac
done

docker buildx version >/dev/null 2>&1 && echo "ok    buildx present" || { echo "FAIL  buildx missing" >&2; fail=1; }

exit "$fail"
