#!/usr/bin/env bash
# Runs only after the fallback install. Brings npm to the pinned version once,
# on a runner that was missing the toolchain entirely.
set -euo pipefail

if [ -n "${PINNED_NPM}" ] && [ "$(npm --version)" != "${PINNED_NPM}" ]; then
  echo "::error title=Runner provisioning defect::npm $(npm --version) after installing Node once, but the repository pins ${PINNED_NPM}. Provision the host tool cache (provision-toolchain.sh); jobs do not install npm."
  exit 1
fi

echo "TOOLCHAIN REPAIRED: node $(node --version | tr -d 'v') npm $(npm --version)"
