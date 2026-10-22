#!/usr/bin/env bash
# Verifies the pinned Node.js and npm that the runner host already carries and
# puts them on PATH. Nothing is downloaded here: every Universe runner host is
# provisioned once with every pinned version in its shared Actions tool cache,
# and a runner that is missing the pin is a provisioning defect, reported as
# one, so the host is repaired instead of every job repairing itself.
set -euo pipefail

fail() {
  echo "::error title=Runner provisioning error::$*"
  echo "RUNNER PROVISIONING ERROR: $*" >&2
  echo "Required Node.js/npm toolchain is not preinstalled on ${RUNNER_NAME:-this runner}. Repair the host with provision-toolchain.sh before it accepts CI jobs." >&2
  exit 1
}

# .nvmrc is the preferred pin, then an exact engines.node, then the
# organization pin, so a repository without an .nvmrc still gets an exact
# declared version rather than whatever happens to be first on PATH.
if [ -f "${NODE_VERSION_FILE}" ]; then
  pinned_node="$(tr -d ' \t\r\nv' < "${NODE_VERSION_FILE}")"
else
  pinned_node="$( [ -f package.json ] && sed -n 's/.*"node"[[:space:]]*:[[:space:]]*"[^0-9]*\([0-9][0-9.]*\).*/\1/p' package.json | head -n 1 || true)"
  if [ -z "${pinned_node}" ] || [ "$(printf '%s' "${pinned_node}" | tr -cd . | wc -c)" -ne 2 ]; then
    pinned_node="${UNIVERSE_NODE_VERSION:-24.19.0}"
    echo "No ${NODE_VERSION_FILE} and no exact engines.node; using the organization pin ${pinned_node}."
  else
    echo "No ${NODE_VERSION_FILE}; using engines.node ${pinned_node} from package.json."
  fi
fi
pinned_npm="$( [ -f package.json ] && sed -n 's/.*"npm"[[:space:]]*:[[:space:]]*"\([0-9][0-9.]*\)".*/\1/p' package.json | head -n 1 || true)"

case "${RUNNER_ARCH:-X64}" in
  X64) arch=x64 ;;
  ARM64) arch=arm64 ;;
  *) arch="$(echo "${RUNNER_ARCH}" | tr '[:upper:]' '[:lower:]')" ;;
esac

tool_cache="${RUNNER_TOOL_CACHE:-/opt/hostedtoolcache}"
candidate="${tool_cache}/node/${pinned_node}/${arch}"

{
  echo "pinned-node=${pinned_node}"
  echo "pinned-npm=${pinned_npm}"
} >> "${GITHUB_OUTPUT}"

[ -x "${candidate}/bin/node" ] || fail "Node.js ${pinned_node} is not in the tool cache ${tool_cache} on ${RUNNER_NAME:-unknown}"

echo "${candidate}/bin" >> "${GITHUB_PATH}"
export PATH="${candidate}/bin:${PATH}"
hash -r

node_version="$(node --version | tr -d 'v')"
npm_version="$(npm --version)"

[ "${node_version}" = "${pinned_node}" ] || fail "tool cache holds Node ${node_version} under the ${pinned_node} directory on ${RUNNER_NAME:-unknown}"
if [ -n "${pinned_npm}" ] && [ "${npm_version}" != "${pinned_npm}" ]; then
  fail "npm ${npm_version} on ${RUNNER_NAME:-unknown} but the repository pins ${pinned_npm}; run provision-toolchain.sh (NPM_VERSION=${pinned_npm}) on the host"
fi

echo "NODE: preinstalled ${node_version} ($(command -v node))"
echo "NPM: preinstalled ${npm_version} ($(command -v npm))"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  echo "- runtime pre-warmed: node ${node_version}, npm ${npm_version}" >> "${GITHUB_STEP_SUMMARY}"
fi
