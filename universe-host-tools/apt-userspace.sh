#!/usr/bin/env bash
# Install Ubuntu packages without root: apt resolves the dependencies that the
# host's dpkg database lacks and verifies them against the signed archive
# indexes; dpkg -x unpacks them into a private staging tree, which is relocated
# and then published into the shared prefix one rename(2) at a time. Jobs keep
# loading libraries from the prefix while this runs, so no file there is ever
# visible half written. Caller holds the lock.
set -Eeuo pipefail
ROOT="$1"; shift
PREFIX="$ROOT/prefix"
relocate() { # tree: rewrite /usr paths in tree to the prefix
  local tree="$1" f l t
  # Idempotent: the prefix itself ends in ".../prefix", so an already relocated
  # path is preceded by "x" and is never rewritten twice.
  find "$tree" -name '*.pc' -type f -exec sed -i "s#^prefix=/usr\$#prefix=$PREFIX/usr#; s#=/usr/#=$PREFIX/usr/#g" {} +
  for f in "$tree/usr/bin/musl-gcc" "$tree"/usr/lib/x86_64-linux-musl/musl-gcc.specs "$tree"/usr/lib/musl/lib/musl-gcc.specs; do
    [[ -f "$f" ]] && sed -i "s#\([^x]\|^\)/usr/\(lib\|include\)/\(x86_64-linux-musl\|musl\)#\1$PREFIX/usr/\2/\3#g" "$f"
  done
  find "$tree" -type l | while read -r l; do
    t="$(readlink "$l")"
    if [[ "$t" == /* && ! -e "$t" && ( -e "$PREFIX$t" || -e "$tree$t" ) ]]; then
      ln -sfn "$PREFIX$t" "$l.relocate.$$" && mv -Tf "$l.relocate.$$" "$l"
    fi
  done
}
if [[ "${1:-}" == --relocate-only ]]; then relocate "$PREFIX"; exit 0; fi
APT="$ROOT/apt"
mkdir -p "$APT/lists/partial" "$APT/archives/partial" "$PREFIX"
opts=(-o "Dir::State::Lists=$APT/lists" -o "Dir::Cache=$APT/cache" -o "Dir::Cache::archives=$APT/archives"
      -o Debug::NoLocking=1 -o APT::Sandbox::User="$(id -un)" -o Dpkg::Use-Pty=0 -q)
if [[ -z "$(find "$APT/lists" -name '*_Packages*' -mmin -1440 -print -quit 2>/dev/null)" ]]; then
  apt-get "${opts[@]}" update >/dev/null
fi
apt-get "${opts[@]}" install --download-only --no-install-recommends -y "$@" >/dev/null
stage="$ROOT/stage.$$"; rm -rf "$stage"; mkdir -p "$stage"
trap 'rm -rf "$stage"' EXIT
shopt -s nullglob
unpacked=()
for deb in "$APT"/archives/*.deb; do
  name="$(dpkg-deb -f "$deb" Package)"
  if [[ ! -f "$ROOT/state/deb-$name.done" ]]; then dpkg-deb -x "$deb" "$stage"; unpacked+=("$name"); fi
done
relocate "$stage"
# Publish: directories first, then every file and link by atomic rename.
(cd "$stage" && find . -mindepth 1 -type d -print0 | while IFS= read -r -d '' d; do mkdir -p "$PREFIX/${d#./}"; done)
(cd "$stage" && find . -mindepth 1 ! -type d -print0 | while IFS= read -r -d '' f; do mv -Tf "$f" "$PREFIX/${f#./}"; done)
for name in "${unpacked[@]}"; do touch "$ROOT/state/deb-$name.done"; done
for p in "$@"; do touch "$ROOT/state/$p.done"; done
rm -f "$APT"/archives/*.deb
