#!/usr/bin/env bash
# Boot-time bootstrap for a Universe ephemeral runner VM.
#
#   1. read non-secret configuration from instance metadata
#   2. fetch a GCE identity token for the control plane audience
#   3. exchange it for a one-time GitHub JIT runner configuration
#   4. run exactly one job
#   5. tell the control plane the job is done, then power off
#
# The JIT configuration lives only in memory and on a tmpfs for the seconds
# between fetch and start. It is never logged.
set -uo pipefail

MD="http://metadata.google.internal/computeMetadata/v1"
RUNNER_DIR=/opt/actions-runner
STATE_DIR=/run/universe-runner
LOG=/var/log/universe-runner.log

log() { printf '%s universe-runner: %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$LOG"; }
md() { curl -sf -H 'Metadata-Flavor: Google' "$MD/$1"; }
attr() { md "instance/attributes/$1"; }

CONTROL_URL="$(attr universe-control-url || true)"
CLASS="$(attr universe-runner-class || true)"
NAME="$(md instance/name || true)"
ZONE="$(md instance/zone | awk -F/ '{print $NF}')"

if [ -z "$CONTROL_URL" ] || [ -z "$NAME" ]; then
  log "missing control URL or instance name in metadata; powering off"
  sleep 5; systemctl poweroff; exit 1
fi
log "boot name=$NAME zone=$ZONE class=$CLASS"

# Hard fail-safe independent of the control plane: no runner VM outlives this.
shutdown -h +420 "universe-runner: maximum lifetime reached" >/dev/null 2>&1 || true

# Docker must be ready before a job can use it.
for _ in $(seq 1 60); do docker info >/dev/null 2>&1 && break; sleep 1; done

report() {
  local reason="$1" code="${2:-0}" token
  token="$(md "instance/service-accounts/default/identity?audience=${CONTROL_URL}&format=full" || true)"
  [ -n "$token" ] || return 0
  curl -s -o /dev/null -m 20 -X POST \
    -H "Authorization: Bearer $token" -H 'content-type: application/json' \
    -d "{\"reason\":\"$reason\",\"exit_code\":$code}" \
    "$CONTROL_URL/runner/finished" || true
}

install -d -m 0700 "$STATE_DIR"
JIT_FILE="$STATE_DIR/jit.json"
code=""
# Up to about forty minutes: the control plane answers 503 with Retry-After
# while GitHub's REST budget is exhausted, and that budget returns hourly.
for attempt in $(seq 1 160); do
  token="$(md "instance/service-accounts/default/identity?audience=${CONTROL_URL}&format=full" || true)"
  if [ -z "$token" ]; then log "no identity token yet (attempt $attempt)"; sleep 3; continue; fi
  code="$(curl -s -m 30 -o "$JIT_FILE" -w '%{http_code}' -X POST \
    -H "Authorization: Bearer $token" -H 'content-type: application/json' \
    -d "{\"instance\":\"$NAME\",\"zone\":\"$ZONE\"}" "$CONTROL_URL/runner/jit" || echo 000)"
  case "$code" in
    200) break ;;
    403|404|409)
      log "control plane refused JIT request (http $code); powering off"
      report "jit refused $code" 2
      sleep 3; systemctl poweroff; exit 2 ;;
    503) log "control plane waiting on GitHub (http 503), attempt $attempt"; sleep 15 ;;
    *) log "JIT request failed (http $code), attempt $attempt"; sleep $(( attempt < 8 ? attempt * 2 : 15 )) ;;
  esac
done
if [ "$code" != "200" ]; then
  log "never obtained a JIT configuration; powering off"
  report "jit unavailable" 3
  sleep 3; systemctl poweroff; exit 3
fi

JIT="$(jq -r '.jit_config' "$JIT_FILE")"
rm -f "$JIT_FILE"
if [ -z "$JIT" ] || [ "$JIT" = "null" ]; then
  log "empty JIT configuration; powering off"
  report "jit empty" 4
  sleep 3; systemctl poweroff; exit 4
fi
log "JIT configuration received; starting runner"

# The job environment: the runner exports /etc/environment into every step.
set -a; . /etc/environment; set +a
export HOME=/home/runner USER=runner LOGNAME=runner
export RUNNER_ALLOW_RUNASROOT=0
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
export UNIVERSE_RUNNER_CLASS="$CLASS" UNIVERSE_RUNNER_ZONE="$ZONE"
cd "$RUNNER_DIR"
runuser -u runner --preserve-environment -- ./run.sh --jitconfig "$JIT" >>"$LOG" 2>&1
EXIT=$?
unset JIT
log "runner exited with $EXIT"

# Diagnostics are shipped by the ops agent from _diag; give it a moment.
sleep 3
report "runner exited" "$EXIT"
sleep 5
systemctl poweroff
exit "$EXIT"
