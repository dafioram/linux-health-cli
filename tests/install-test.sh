#!/bin/bash
# End-to-end install test. Needs root on a machine (or container) booted with systemd.
# It really installs, so only run it somewhere disposable: a CI runner or a test container.
#
# usage: sudo tests/install-test.sh [installer options, e.g. --no-apt]
set -u
. "$(dirname "$0")/lib.sh"

[ "$(id -u)" = 0 ] || { echo "run as root"; exit 2; }
[ -d /run/systemd/system ] || { echo "systemd is not running as init"; exit 2; }

STATUS=/run/healthcheck.status
STATE=/var/lib/healthcheck
LOG=$(mktemp); trap 'rm -f "$LOG"' EXIT

# run a login shell on a pseudo-terminal, the way an SSH login does; print what it shows
login_output() { env -u HEALTH_SHOWN script -qec "bash $1 -c true" /dev/null 2>&1; }

section "help"
check "--help prints usage only" bash -c "bash '$INSTALLER' --help | grep -q '^# usage' && ! bash '$INSTALLER' --help | grep -q 'set -u'"
check "unknown option is rejected" bash -c "! bash '$INSTALLER' --bogus >/dev/null 2>&1"

section "install"
bash "$INSTALLER" "$@" >"$LOG" 2>&1; rc=$?
cat "$LOG"
check "installer exits 0" test "$rc" = 0
check "no [fail] lines" bash -c "! grep -q '\[fail\]' '$LOG'"
check "systemd-analyze verify is clean" bash -c "! grep -q 'systemd-analyze verify notes' '$LOG'"
for f in /usr/local/sbin/healthcheck /etc/profile.d/healthcheck.sh; do
  check "$f exists" test -f "$f"
done
check "collector is executable" test -x /usr/local/sbin/healthcheck

section "survives reboot (enabled = wanted by a boot target)"
for u in healthcheck.timer healthcheck-weekly.timer healthcheck-marker.service; do
  check "$u is enabled" systemctl -q is-enabled "$u"
  check "$u is active" systemctl -q is-active "$u"
done
check "healthcheck.timer is in timers.target.wants" test -L /etc/systemd/system/timers.target.wants/healthcheck.timer
check "marker is in multi-user.target.wants" test -L /etc/systemd/system/multi-user.target.wants/healthcheck-marker.service
check "first boot check is scheduled within 1 min" \
  test "$(systemctl show -p TimersMonotonic --value healthcheck.timer | grep -o 'OnBootUSec=[^ ;]*')" = "OnBootUSec=30s"
check "service has a start timeout" bash -c "[ \"\$(systemctl show -p TimeoutStartUSec --value healthcheck.service)\" != infinity ]"

section "status file"
rm -f "$STATUS"
check "healthcheck.service runs under systemd" systemctl start healthcheck.service
check "status file written" test -s "$STATUS"
check "status file is world-readable" bash -c "[ \"\$(stat -c %a '$STATUS')\" = 644 ]"
check "every line is LEVEL|label|message" bash -c "! grep -vE '^(OK|INFO|WARN|CRIT|DETAIL|TS)\|[^|]*\|' '$STATUS'"
check "uptime stamp present" grep -qE '^TS\|[0-9]+\|$' "$STATUS"
check "memory check present" grep -q '|memory|' "$STATUS"
check "disk space checked" grep -q 'free space' "$STATUS"
echo "--- $STATUS"; cat "$STATUS"

section "login hook"
out=$(login_output -li)
echo "$out"
check "interactive login shows dashboard" grep -q 'System health (checked 0 min ago)' <<<"$out"
check "dashboard lists the memory line" grep -q 'memory' <<<"$out"
check "non-interactive login prints nothing (scp/rsync safe)" test -z "$(login_output -l)"
check "nested shell doesn't repeat it" bash -c "! HEALTH_SHOWN=1 script -qec 'bash -li -c true' /dev/null | grep -q 'System health'"
mv "$STATUS" "$STATUS.saved"
out=$(login_output -li)
check "missing status says so instead of printing nothing" grep -q 'no results yet this boot' <<<"$out"
mv "$STATUS.saved" "$STATUS"

section "unclean shutdown marker"
: > "$STATE/alerts.log"
echo clean > "$STATE/boot_state"
/usr/local/sbin/healthcheck boot
check "clean shutdown raises no alert" test ! -s "$STATE/alerts.log"
/usr/local/sbin/healthcheck boot   # boot_state is still "running": like a power cut
check "unclean shutdown is recorded" grep -q 'unclean shutdown' "$STATE/alerts.log"
/usr/local/sbin/healthcheck run
check "dashboard shows it as history" grep -q '^WARN|history|' "$STATUS"
/usr/local/sbin/healthcheck ack
check "ack clears alerts" test ! -s "$STATE/alerts.log"
check "ack keeps a copy" grep -q 'unclean shutdown' "$STATE/alerts.acked.log"
echo running > "$STATE/boot_state"

section "reinstall is idempotent"
bash "$INSTALLER" "$@" >"$LOG" 2>&1; rc=$?
check "reinstall exits 0" test "$rc" = 0
check "no files rewritten" bash -c "! grep -q 'wrote ' '$LOG'"
check "no backups made" bash -c "! grep -q 'backed up' '$LOG'"

section "uninstall"
bash "$INSTALLER" --uninstall >"$LOG" 2>&1; rc=$?
cat "$LOG"
check "uninstall exits 0" test "$rc" = 0
for f in /usr/local/sbin/healthcheck /etc/profile.d/healthcheck.sh /etc/systemd/system/healthcheck.timer "$STATUS"; do
  check "$f removed" test ! -e "$f"
done
check "timer no longer loaded" bash -c "[ \"\$(systemctl show -p LoadState --value healthcheck.timer)\" = not-found ]"
check "clean shutdown marked on uninstall" grep -qx clean "$STATE/boot_state"
check "state kept without --purge" test -d "$STATE"
bash "$INSTALLER" --uninstall --purge >/dev/null 2>&1
check "--purge removes state" test ! -e "$STATE"

finish
