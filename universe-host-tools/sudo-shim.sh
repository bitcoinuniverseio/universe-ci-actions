#!/usr/bin/env bash
# universe-runners-1 has no root: the shared github-runner account has no sudo
# grant. This shim honours the things CI asks of sudo that need no host
# privilege (apt package installs into the user-space prefix, also when wrapped
# in `sh -c` the way `playwright install --with-deps` does, and chown), and fails
# everything else exactly like a missing sudo grant, so root probes
# (sudo -n true) keep reporting "unavailable".
set -Eeuo pipefail
while [[ $# -gt 0 && "$1" == -* ]]; do
  case "$1" in -u|-g|-C|-h|-p|-U) shift 2 ;; *) shift ;; esac
done
while [[ $# -gt 0 && "$1" == *=* ]]; do export "$1"; shift; done
cmd="${1:-}"; shift || true
case "$cmd" in
  apt-get|apt)
    sub=""; pkgs=()
    for a in "$@"; do
      case "$a" in -*) ;; *) if [[ -z "$sub" ]]; then sub="$a"; else pkgs+=("$a"); fi ;; esac
    done
    case "$sub" in
      update) exit 0 ;;
      install)
        root="${UNIVERSE_HOST_TOOLS_ROOT:?universe host tools not initialised}"
        exec 9>"$root/.lock"; flock -w 1800 9
        need=(); for p in "${pkgs[@]}"; do [[ -f "$root/state/$p.done" ]] || need+=("${p%%=*}"); done
        (( ${#need[@]} )) && bash "$root/apt-userspace.sh" "$root" "${need[@]}"
        exit 0 ;;
    esac ;;
  sh|bash)
    # Only an `sh -c` script made of apt-get/apt update and install commands
    # joined by && or ; is honoured; each part goes through the apt path above.
    if [[ "${1:-}" == -c && $# -eq 2 ]]; then
      ok=1; parts=()
      while IFS= read -r part; do
        part="${part#"${part%%[![:space:]]*}"}"; [[ -n "$part" ]] || continue
        read -ra words <<<"$part"
        while [[ ${#words[@]} -gt 0 && "${words[0]}" == *=* ]]; do words=("${words[@]:1}"); done
        [[ "${words[0]:-}" == apt-get || "${words[0]:-}" == apt ]] || { ok=0; break; }
        parts+=("${words[*]}")
      done < <(sed -E 's/[[:space:]]*(&&|;)[[:space:]]*/\n/g' <<<"$2")
      if (( ok && ${#parts[@]} )); then
        for part in "${parts[@]}"; do read -ra words <<<"$part"; "$0" "${words[@]}"; done
        exit 0
      fi
    fi ;;
  chown)
    # Files written by container users map to subordinate UIDs; the rootless
    # Docker namespace's root is github-runner, so it can hand them back.
    paths=(); for a in "$@"; do case "$a" in -*|*:*) ;; *) paths+=("$(realpath -m "$a")") ;; esac; done
    for p in "${paths[@]}"; do
      docker run --rm --network none -v "$p:/target" alpine:3.22.2@sha256:4b7ce07002c69e8f3d704a9c5d6fd3053be500b7f1c69fc0d80990c2ad8dd412 chown -R 0:0 /target
    done
    exit 0 ;;
esac
echo "sudo: root is not available on universe-runners-1 (github-runner has no sudo grant)" >&2
exit 1
