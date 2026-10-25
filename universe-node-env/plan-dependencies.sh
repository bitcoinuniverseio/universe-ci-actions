#!/usr/bin/env bash
# Computes the dependency fingerprint with universe-deps (the one key schema the
# host warmer and every job share) and decides where the tree lives for this
# runner class.
set -euo pipefail

node_version="$(node --version | tr -d 'v')"
npm_version="$(npm --version)"
workspace_path="$(pwd)"
deps="${UNIVERSE_DEPS_BIN:-}"
if [ -z "${deps}" ] || [ ! -x "${deps}" ]; then deps="$(dirname "${BASH_SOURCE[0]}")/universe-deps.sh"; fi

no_dependencies() {
  echo "NO DEPENDENCIES: ${workspace_path} $1; toolchain only."
  {
    echo "node-version=${node_version}"
    echo "npm-version=${npm_version}"
    echo "dependency-key="
    echo "persistent=false"
    echo "store-root="
    echo "node-modules-path=${workspace_path}/node_modules"
    echo "no-dependencies=true"
  } >> "${GITHUB_OUTPUT}"
  exit 0
}
[ -f package.json ] || no_dependencies "has no package.json"
[ -f package-lock.json ] || [ -f npm-shrinkwrap.json ] || no_dependencies "has no lockfile"

key="$(bash "${deps}" key)"

# A persistent runner keeps its filesystem between jobs, so the exact tree is
# reused from local disk with no transfer at all. Only GitHub-hosted or
# provider-managed instances are ephemeral.
persistent=true
case "${RUNNER_NAME:-}" in runs-on*) persistent=false ;; esac
[ "${RUNNER_ENVIRONMENT:-self-hosted}" = github-hosted ] && persistent=false
[ -n "${RUNS_ON_RUNNER_NAME:-}${RUNS_ON_S3_BUCKET_CACHE:-}" ] && persistent=false

store_root="${STORE_ROOT_INPUT:-${UNIVERSE_DEP_STORE:-}}"
if [ "${persistent}" = true ] && [ -z "${store_root}" ]; then
  store_root="$(dirname "$(npm config get cache)")/.universe-dep-store"
fi

{
  echo "node-version=${node_version}"
  echo "npm-version=${npm_version}"
  echo "dependency-key=${key}"
  echo "persistent=${persistent}"
  echo "store-root=${store_root}"
  echo "node-modules-path=${workspace_path}/node_modules"
  echo "no-dependencies=false"
} >> "${GITHUB_OUTPUT}"

echo "DEPENDENCY FINGERPRINT: ${key}"
echo "DEPENDENCY STORE: ${store_root:-remote actions cache} (persistent=${persistent})"
