#!/usr/bin/env bash
# Shared user-space toolchain for universe-runners-1. Safe to run concurrently:
# every mutation happens under one flock, and finished work is marked so later
# jobs only export the environment.
set -Eeuo pipefail

ROOT="${UNIVERSE_HOST_TOOLS_ROOT:-$HOME/.local/universe-host-tools}"
PREFIX="$ROOT/prefix"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PWSH_VERSION=7.6.6
PWSH_SHA256=ddbc4a2d113bbd46d283cfedcbcd117a70caefd7673f41f2b4e0000badf103bc
DEFAULT_PACKAGES="mysql-client-core-8.0 postgresql-client-16 redis-tools protobuf-compiler libprotobuf-dev pkg-config libssl-dev musl-tools git-lfs"

mkdir -p "$ROOT/state" "$PREFIX" "$ROOT/shim"
exec 9>"$ROOT/.lock"
flock -w 1800 9

if [[ ! -x "$ROOT/pwsh/$PWSH_VERSION/pwsh" ]]; then
  tmp="$(mktemp -d)"
  curl -fsSL --retry 3 -o "$tmp/pwsh.tgz" "https://github.com/PowerShell/PowerShell/releases/download/v${PWSH_VERSION}/powershell-${PWSH_VERSION}-linux-x64.tar.gz"
  echo "$PWSH_SHA256  $tmp/pwsh.tgz" | sha256sum -c --quiet -
  mkdir -p "$ROOT/pwsh/$PWSH_VERSION.partial"
  tar -xzf "$tmp/pwsh.tgz" -C "$ROOT/pwsh/$PWSH_VERSION.partial"
  chmod +x "$ROOT/pwsh/$PWSH_VERSION.partial/pwsh"
  rm -rf "$ROOT/pwsh/$PWSH_VERSION"; mv "$ROOT/pwsh/$PWSH_VERSION.partial" "$ROOT/pwsh/$PWSH_VERSION"
  rm -rf "$tmp"
fi
ln -sfn "$ROOT/pwsh/$PWSH_VERSION/pwsh" "$ROOT/shim/pwsh"

wanted=()
for p in $DEFAULT_PACKAGES ${UHT_EXTRA_PACKAGES:-}; do
  [[ -f "$ROOT/state/$p.done" ]] || wanted+=("$p")
done
if (( ${#wanted[@]} )); then
  bash "$here/apt-userspace.sh" "$ROOT" "${wanted[@]}"
fi

bash "$here/apt-userspace.sh" "$ROOT" --relocate-only
install -m 0755 "$here/sudo-shim.sh" "$ROOT/shim/sudo"
install -m 0755 "$here/apt-userspace.sh" "$ROOT/apt-userspace.sh"
flock -u 9

lib="$PREFIX/usr/lib/x86_64-linux-gnu:$PREFIX/lib/x86_64-linux-gnu:$PREFIX/usr/lib"
{
  echo "$ROOT/shim"
  echo "$PREFIX/usr/bin"
  echo "$PREFIX/usr/sbin"
  echo "$PREFIX/usr/lib/postgresql/16/bin"
} >> "$GITHUB_PATH"
{
  echo "UNIVERSE_HOST_TOOLS_ROOT=$ROOT"
  echo "LD_LIBRARY_PATH=$lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  echo "LIBRARY_PATH=$lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
  echo "CPATH=$PREFIX/usr/include:$PREFIX/usr/include/x86_64-linux-gnu${CPATH:+:$CPATH}"
  echo "PKG_CONFIG_PATH=$PREFIX/usr/lib/x86_64-linux-gnu/pkgconfig:$PREFIX/usr/share/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
  echo "PROTOC=$PREFIX/usr/bin/protoc"
  echo "PROTOC_INCLUDE=$PREFIX/usr/include"
} >> "$GITHUB_ENV"
echo "universe host tools ready under $ROOT (pwsh $PWSH_VERSION)"
