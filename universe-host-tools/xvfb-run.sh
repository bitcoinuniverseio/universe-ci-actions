#!/usr/bin/env bash
# Relocated xvfb-run: start the prefix Xvfb with the prefix keyboard data, run
# the command with DISPLAY set, and always stop the server afterwards.
set -Eeuo pipefail
args=(); srv="-screen 0 1280x1024x24"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -a|--auto-servernum) shift ;;
    -s|--server-args) srv="$2"; shift 2 ;;
    --server-args=*) srv="${1#*=}"; shift ;;
    -n|--server-num|-f|--auth-file|-e|--error-file|-p|--xauth-protocol) shift 2 ;;
    --) shift; break ;;
    -*) shift ;;
    *) break ;;
  esac
done
prefix="${UNIVERSE_HOST_TOOLS_ROOT:?}/prefix"
for n in $(seq 99 199); do [[ -e "/tmp/.X$n-lock" ]] || { num=$n; break; }; done
# shellcheck disable=SC2086
"$prefix/usr/bin/Xvfb" ":$num" -nolisten tcp -xkbdir "$prefix/usr/share/X11/xkb" $srv >/dev/null 2>&1 &
xpid=$!
trap 'kill $xpid 2>/dev/null || true; wait $xpid 2>/dev/null || true' EXIT
for _ in $(seq 50); do [[ -e "/tmp/.X11-unix/X$num" ]] && break; sleep 0.1; done
DISPLAY=":$num" "$@"
