#!/usr/bin/env bash
# Install Ubuntu packages without root: apt resolves the dependencies that the
# host's dpkg database lacks and verifies them against the signed archive
# indexes; dpkg -x unpacks them into the shared prefix. Caller holds the lock.
set -Eeuo pipefail
ROOT="$1"; shift
PREFIX="$ROOT/prefix"
relocate() {
  # Idempotent: the prefix itself ends in ".../prefix", so an already relocated
  # path is preceded by "x" and is never rewritten twice.
  find "$PREFIX" -name '*.pc' -type f -exec sed -i "s#^prefix=/usr\$#prefix=$PREFIX/usr#; s#=/usr/#=$PREFIX/usr/#g" {} +
  local f
  for f in "$PREFIX/usr/bin/musl-gcc" "$PREFIX"/usr/lib/x86_64-linux-musl/musl-gcc.specs "$PREFIX"/usr/lib/musl/lib/musl-gcc.specs; do
    [[ -f "$f" ]] && sed -i "s#\([^x]\|^\)/usr/\(lib\|include\)/\(x86_64-linux-musl\|musl\)#\1$PREFIX/usr/\2/\3#g" "$f"
  done
  find "$PREFIX" -type l | while read -r l; do
    t="$(readlink "$l")"
    if [[ "$t" == /* && ! -e "$t" && -e "$PREFIX$t" ]]; then ln -sfn "$PREFIX$t" "$l"; fi
  done
}
if [[ "${1:-}" == --relocate-only ]]; then relocate; exit 0; fi
APT="$ROOT/apt"
mkdir -p "$APT/lists/partial" "$APT/archives/partial" "$PREFIX"
opts=(-o "Dir::State::Lists=$APT/lists" -o "Dir::Cache=$APT/cache" -o "Dir::Cache::archives=$APT/archives"
      -o Debug::NoLocking=1 -o APT::Sandbox::User="$(id -un)" -o Dpkg::Use-Pty=0 -q)
if [[ -z "$(find "$APT/lists" -name '*_Packages*' -mmin -1440 -print -quit 2>/dev/null)" ]]; then
  apt-get "${opts[@]}" update >/dev/null
fi
apt-get "${opts[@]}" install --download-only --no-install-recommends -y "$@" >/dev/null
shopt -s nullglob
for deb in "$APT"/archives/*.deb; do
  name="$(dpkg-deb -f "$deb" Package)"
  if [[ ! -f "$ROOT/state/deb-$name.done" ]]; then
    dpkg-deb -x "$deb" "$PREFIX"
    touch "$ROOT/state/deb-$name.done"
  fi
done
relocate
for p in "$@"; do touch "$ROOT/state/$p.done"; done
rm -f "$APT"/archives/*.deb
