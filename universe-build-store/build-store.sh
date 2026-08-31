#!/usr/bin/env bash
# Content-addressed build output reuse on a persistent runner fleet.
set -euo pipefail

case "${RUNNER_ARCH:-X64}" in
  X64) arch=x64 ;;
  ARM64) arch=arm64 ;;
  *) arch="$(echo "${RUNNER_ARCH}" | tr '[:upper:]' '[:lower:]')" ;;
esac
os="$(echo "${RUNNER_OS:-Linux}" | tr '[:upper:]' '[:lower:]')"

# The commit is what makes a build output correct, together with the toolchain
# that produced it and the machine shape it was produced for.
key="build-v1-${GITHUB_REPOSITORY//\//-}-${GITHUB_SHA}-$(printf '%s' "${BUILD_PATH}${KEY_SUFFIX}" | sha256sum | cut -c1-16)-${os}-${arch}-node$(node --version | tr -d 'v')"

store="${UNIVERSE_BUILD_STORE:-}"
if [ -z "${store}" ]; then
  store="$(dirname "$(npm config get cache)")/.universe-build-store"
fi

if ! mkdir -p "${store}" 2>/dev/null || [ ! -w "${store}" ]; then
  echo "::warning::Build store ${store} is not writable on ${RUNNER_NAME:-unknown}; this runner cannot share build output."
  echo "state=unavailable" >> "${GITHUB_OUTPUT}"
  [ "${BUILD_MODE}" = restore ] && exit 1
  exit 0
fi

archive="${store}/${key}.tar.zst"

if [ "${BUILD_MODE}" = restore ]; then
  if [ -f "${archive}" ]; then
    rm -rf "${BUILD_PATH}"
    tar --use-compress-program='zstd -d -T0' -xf "${archive}"
    touch "${archive}"
    echo "BUILD HIT: ${key}"
    echo "state=hit" >> "${GITHUB_OUTPUT}"
    exit 0
  fi
  echo "BUILD MISS: ${key}"
  echo "state=miss" >> "${GITHUB_OUTPUT}"
  exit 1
fi

if [ ! -d "${BUILD_PATH}" ]; then
  echo "::error::Nothing to store at ${BUILD_PATH}."
  exit 1
fi

staging="${archive}.$$.partial"
tar --use-compress-program='zstd -6 -T0' -cf "${staging}" "${BUILD_PATH}"
mv -f "${staging}" "${archive}"
echo "BUILD STORED: ${archive} ($(du -h "${archive}" | cut -f1))"
echo "state=stored" >> "${GITHUB_OUTPUT}"

# Bounded by least recent use. A restore touches its archive, so anything a
# live branch still consumes survives.
keep="${UNIVERSE_BUILD_STORE_KEEP:-40}"
find "${store}" -maxdepth 1 -name '*.tar.zst' -printf '%T@ %p\n' 2>/dev/null |
  sort -rn | tail -n "+$((keep + 1))" | cut -d' ' -f2- |
  while read -r stale; do rm -f "${stale}"; echo "BUILD PRUNED: ${stale}"; done
find "${store}" -maxdepth 1 -name '*.partial' -mmin +120 -delete 2>/dev/null || true
