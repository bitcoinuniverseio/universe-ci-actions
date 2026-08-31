#!/usr/bin/env bash
# Runs only after the fallback install. Brings npm to the pinned version once,
# on a runner that was missing the toolchain entirely.
set -euo pipefail

if [ -n "${PINNED_NPM}" ] && [ "$(npm --version)" != "${PINNED_NPM}" ]; then
  npm install --global --no-audit --no-fund "npm@${PINNED_NPM}"
fi

echo "TOOLCHAIN REPAIRED: node $(node --version | tr -d 'v') npm $(npm --version)"
