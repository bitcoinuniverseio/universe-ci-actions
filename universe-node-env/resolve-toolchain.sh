#!/usr/bin/env bash
# Puts the pinned Node.js and npm on PATH without downloading anything.
#
# Every supported runner image ships the pinned Node.js in the Actions tool
# cache. Selecting it is a PATH change, so a warm job spends milliseconds here
# instead of the ~93 seconds an actions/setup-node download costs.
set -euo pipefail

pinned_node="$(tr -d ' \t\r\nv' < "${NODE_VERSION_FILE}")"
pinned_npm="$(node -e 'process.stdout.write(require("./package.json").engines?.npm ?? "")' 2>/dev/null || true)"
if [ -z "${pinned_npm}" ]; then
  pinned_npm="$(sed -n 's/.*"npm"[[:space:]]*:[[:space:]]*"\([0-9][0-9.]*\)".*/\1/p' package.json | head -n 1)"
fi

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

if [ ! -x "${candidate}/bin/node" ]; then
  echo "::warning title=Runner image defect::TOOLCHAIN MISS on ${RUNNER_NAME:-unknown}: Node ${pinned_node} is not in ${tool_cache}. This job installs it once; fix the runner image so no other job pays this cost."
  echo "TOOLCHAIN MISS: node/${pinned_node}/${arch}"
  echo "needs-install=true" >> "${GITHUB_OUTPUT}"
  exit 0
fi

echo "${candidate}/bin" >> "${GITHUB_PATH}"
export PATH="${candidate}/bin:${PATH}"

node_version="$(node --version | tr -d 'v')"
npm_version="$(npm --version)"

if [ "${node_version}" != "${pinned_node}" ]; then
  echo "::error::Tool cache holds Node ${node_version} under the ${pinned_node} directory."
  exit 1
fi

# npm ships inside the Node tarball. A mismatch means the image was built with
# the wrong bundle, so repair the tool cache once instead of every job.
if [ -n "${pinned_npm}" ] && [ "${npm_version}" != "${pinned_npm}" ]; then
  echo "::warning title=Runner image defect::NPM MISS on ${RUNNER_NAME:-unknown}: tool cache has npm ${npm_version}, repository pins ${pinned_npm}. Repairing the tool cache copy once."
  npm install --global --no-audit --no-fund "npm@${pinned_npm}"
  npm_version="$(npm --version)"
  if [ "${npm_version}" != "${pinned_npm}" ]; then
    echo "::error::npm is ${npm_version} after repair, expected ${pinned_npm}."
    exit 1
  fi
fi

echo "TOOLCHAIN HIT: node ${node_version} npm ${npm_version} from ${candidate}"
echo "needs-install=false" >> "${GITHUB_OUTPUT}"
