#!/usr/bin/env bash
# Builds the content-addressed dependency key and decides where the exact
# dependency state lives for this runner class.
set -euo pipefail

node_version="$(node --version | tr -d 'v')"
npm_version="$(npm --version)"
workspace_path="$(pwd)"

case "${RUNNER_ARCH:-X64}" in
  X64) arch=x64 ;;
  ARM64) arch=arm64 ;;
  *) arch="$(echo "${RUNNER_ARCH}" | tr '[:upper:]' '[:lower:]')" ;;
esac

os="$(echo "${RUNNER_OS:-Linux}" | tr '[:upper:]' '[:lower:]')"

# glibc and musl produce incompatible native addons for the same Node ABI.
libc=unknown
if [ "${os}" = linux ]; then
  if ldd --version 2>&1 | head -n 1 | grep -qi musl; then libc=musl; else libc=glibc; fi
fi

# Node's ABI number is what every prebuilt native addon is compiled against.
node_abi="$(node -p 'process.versions.modules')"

# A repository can legitimately have no dependencies to install: a docs site
# that runs plain node scripts has neither a package.json nor a lockfile. Say
# so and let the toolchain stand on its own rather than failing the job.
if [ ! -f package.json ]; then
  echo "NO DEPENDENCIES: ${workspace_path} has no package.json; toolchain only."
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
fi

lockfiles="$(git ls-files -- '**/package-lock.json' 'package-lock.json' 'npm-shrinkwrap.json' '**/npm-shrinkwrap.json' 2>/dev/null | sort || true)"
if [ -z "${lockfiles}" ]; then
  lockfiles="$(ls package-lock.json npm-shrinkwrap.json 2>/dev/null || true)"
fi
if [ -z "${lockfiles}" ]; then
  echo "NO DEPENDENCIES: ${workspace_path} has no lockfile; toolchain only."
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
fi

# Every input capable of making a restored tree wrong is inside the digest.
fingerprint="$(
  {
    echo "schema=2"
    echo "os=${os}"
    echo "arch=${arch}"
    echo "libc=${libc}"
    echo "node=${node_version}"
    echo "node-abi=${node_abi}"
    echo "npm=${npm_version}"
    echo "flags=${NPM_INSTALL_ARGS:-}"
    echo "repo=${GITHUB_REPOSITORY:-local}"
    echo "path=${INPUT_WORKING_DIRECTORY:-.}"
    # package.json carries overrides, workspaces, engines and install scripts,
    # none of which appear in the lockfile hash alone.
    sha256sum package.json
    # shellcheck disable=SC2086
    sha256sum ${lockfiles}
  } | sha256sum | cut -d' ' -f1
)"

key="universe-deps-v2-${os}-${arch}-${libc}-node${node_version}-npm${npm_version}-${fingerprint}"

# A persistent runner keeps its filesystem between jobs, so an exact dependency
# tree can be reused from local NVMe with no network transfer at all. RunsOn
# instances are ephemeral and use the account's own S3-backed Actions cache.
persistent=false
store_root="${STORE_ROOT_INPUT:-}"
ephemeral=false
case "${RUNNER_NAME:-}" in runs-on*) ephemeral=true ;; esac
[ "${RUNNER_ENVIRONMENT:-self-hosted}" = github-hosted ] && ephemeral=true
[ -n "${RUNS_ON_RUNNER_NAME:-}${RUNS_ON_S3_BUCKET_CACHE:-}" ] && ephemeral=true

if [ "${ephemeral}" = false ]; then
  persistent=true
  if [ -z "${store_root}" ]; then
    # npm's cache directory already sits in the shared root that every runner
    # service on this host uses, so its parent is the one place a dependency
    # tree can be written once and reused by all of them.
    store_root="${UNIVERSE_DEP_STORE:-$(dirname "$(npm config get cache)")/.universe-dep-store}"
  fi
  mkdir -p "${store_root}" 2>/dev/null && [ -w "${store_root}" ] || {
    echo "::warning::Dependency store ${store_root} is not writable; falling back to the remote cache."
    persistent=false
    store_root=""
  }
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

echo "DEPENDENCY KEY: ${key}"
echo "DEPENDENCY STORE: ${store_root:-remote actions cache} (persistent=${persistent})"
