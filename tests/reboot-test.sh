#!/bin/bash
# Reboot test: install into a container booted with systemd, reboot it, and check the
# dashboard comes back on its own. /run is a fresh tmpfs on every start, like a real boot.
#
# usage: tests/reboot-test.sh [base-image]      (default debian:bookworm)
#   HC_IMAGE=<image>  use a prebuilt image that boots systemd instead of building one
set -u
. "$(dirname "$0")/lib.sh"

BASE=${1:-debian:bookworm}
IMAGE=${HC_IMAGE:-}
NAME=hc-reboot-$$
STATUS=/run/healthcheck.status
ALERTS=/var/lib/healthcheck/alerts.log

if [ -z "$IMAGE" ]; then
  IMAGE=hc-test:$(tr ':/.' '---' <<<"$BASE")
  docker build -q -t "$IMAGE" --build-arg BASE="$BASE" "$ROOT/tests" >/dev/null || { echo "image build failed"; exit 2; }
fi
trap 'docker rm -f "$NAME" >/dev/null 2>&1' EXIT

dx() { docker exec "$NAME" "$@"; }
login() { dx script -qec 'bash -li -c true' /dev/null 2>&1; }
booted() {  # wait until timers can fire (full boot may hang on unrelated units in a container)
  local i
  for i in $(seq 60); do
    dx systemctl -q is-active timers.target 2>/dev/null && return 0
    sleep 1
  done
  echo "  timers.target never became active"; return 1
}
wait_status() {  # wait up to $1 seconds for the status file; prints seconds waited
  local i
  for i in $(seq 0 "$1"); do
    dx test -s "$STATUS" && { echo "$i"; return 0; }
    sleep 1
  done
  return 1
}

section "boot $IMAGE"
docker run -d --name "$NAME" --privileged --tmpfs /run --tmpfs /run/lock \
  -v "$ROOT:/src:ro" "$IMAGE" >/dev/null || { echo "container failed to start"; exit 2; }
check "systemd is up" booted
# a smartd that fails like it does on a box with no SMART-capable disks (Pi on an SD card)
dx bash -c 'printf "[Service]\nExecStart=/bin/sh -c \"exit 17\"\n[Install]\nWantedBy=multi-user.target\n" > /etc/systemd/system/smartmontools.service
  systemctl daemon-reload; systemctl enable -q smartmontools.service; systemctl start smartmontools.service' 2>/dev/null
dx bash /src/install-healthcheck.sh --no-apt > /dev/null 2>&1
check "installer exits 0" test $? = 0
check "failing smartd was disabled" bash -c "! docker exec '$NAME' systemctl -q is-enabled smartmontools.service"
check "and no longer shows as failed" bash -c "! docker exec '$NAME' systemctl -q is-failed smartmontools.service"
check "status written at install" dx test -s "$STATUS"

section "clean reboot"
docker restart -t 30 "$NAME" >/dev/null
check "systemd is up again" booted
check "status file is gone (fresh /run)" bash -c "! docker exec '$NAME' test -e '$STATUS'"
check "login before first check explains why it's empty" grep -q 'no results yet this boot' <<<"$(login)"
if secs=$(wait_status 90); then pass "status file back after ${secs}s"; else fail "status file not back within 90s of boot"; fi
check "timer still enabled" dx systemctl -q is-enabled healthcheck.timer
out=$(login); echo "$out"
check "login shows the dashboard" grep -q 'System health (checked' <<<"$out"
check "clean shutdown is not reported as unclean" bash -c "! docker exec '$NAME' grep -qs 'unclean shutdown' '$ALERTS'"

section "power cut (kill -9, then boot)"
docker kill "$NAME" >/dev/null && docker start "$NAME" >/dev/null
check "systemd is up again" booted
check "boot marker ran" dx systemctl -q is-active healthcheck-marker.service
check "unclean shutdown is recorded" dx grep -q 'unclean shutdown' "$ALERTS"
if secs=$(wait_status 90); then pass "status file back after ${secs}s"; else fail "status file not back within 90s of boot"; fi
check "dashboard shows it in history" grep -q 'unacknowledged event' <<<"$(login)"

finish
