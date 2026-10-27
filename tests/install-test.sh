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
IGNORE=/etc/healthcheck/ignore-units
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

section "journal scan after an unclean shutdown"
FAKEBIN=$(mktemp -d)
cat > "$FAKEBIN/journalctl" <<'EOF'
#!/bin/sh
# fake journalctl: prints $FAKE_JOURNAL for boot $FAKE_BOOT, else fails like the real one
case " $* " in *" -b $FAKE_BOOT "*) [ -n "$FAKE_JOURNAL" ] && printf '%s\n' "$FAKE_JOURNAL" && exit 0 ;; esac
echo "No journal boot entry found for the specified boot" >&2; exit 1
EOF
chmod +x "$FAKEBIN/journalctl"
crash_boot() {  # pretend boot $1 just ended in a power cut, then boot
  echo "$1" > "$STATE/last_boot_id"; echo running > "$STATE/boot_state"; /usr/local/sbin/healthcheck boot
}
journal_run() { FAKE_BOOT=$prev FAKE_JOURNAL=$1 PATH="$FAKEBIN:$PATH" /usr/local/sbin/healthcheck run; }
prev=0123456789abcdef0123456789abcdef
A=$STATE/alerts.log

: > "$A"
crash_boot "$prev"
check "unclean shutdown queues a scan of that boot" grep -qx "$prev" "$STATE/scan_boot"
check "this boot's id is remembered" test "$(cat "$STATE/last_boot_id")" = "$(tr -d - < /proc/sys/kernel/random/boot_id)"
echo "2026-01-01 00:00:00 | ${prev:0:8} | [   10.000000] EXT4-fs error (device sda1): saved while running" >> "$A"
journal_run "EXT4-fs error (device sda1): saved while running
systemd-journald: some harmless line
nvme nvme0: Shutdown timeout set to 8 seconds
blk_update_request: I/O error, dev sda, sector 42"
check "error after the last run is recovered" grep -qF "| ${prev:0:8} | journal: blk_update_request: I/O error, dev sda, sector 42" "$A"
check "error saved while running isn't duplicated" test "$(grep -c 'saved while running' "$A")" = 1
check "non-matching lines are ignored" bash -c "! grep -q harmless '$A'"
check "informational NVMe timeout notice is ignored" bash -c "! grep -q 'Shutdown timeout set' '$A'"
check "scan only runs once" test ! -e "$STATE/scan_boot"
check "recovered error shows in history" grep -q 'journal: blk_update_request' "$STATUS"

: > "$A"
crash_boot "$prev"
journal_run ""; rc=$?     # DietPi: journal kept in RAM, nothing saved for the crashed boot
check "no saved journal: run still succeeds" test "$rc" = 0
check "no saved journal: status still written" test -s "$STATUS"
check "no saved journal: nothing recovered" bash -c "! grep -q 'journal:' '$A'"
check "no saved journal: scan cleared" test ! -e "$STATE/scan_boot"

echo running > "$STATE/boot_state"; echo clean > "$STATE/boot_state"
: > "$A"
/usr/local/sbin/healthcheck boot
check "clean shutdown queues no scan" test ! -e "$STATE/scan_boot"
rm -rf "$FAKEBIN"

# real kernel errors: a device-mapper device that fails every read makes the kernel log a
# genuine I/O error. (Text written to /dev/kmsg won't do: the kernel tags it as a user
# message, which journalctl -k skips.)
kernel_io_error() {  # prints the kernel's message, without the [uptime] stamp
  local dm
  command -v dmsetup >/dev/null && dmsetup create hc-test-err --table "0 8 error" 2>/dev/null || return 1
  dm=dm-$(dmsetup info -c --noheadings -o minor hc-test-err | tr -d ' ')
  dd if=/dev/mapper/hc-test-err of=/dev/null bs=4096 count=1 2>/dev/null
  dmsetup remove hc-test-err; sleep 2
  dmesg | grep 'I/O error' | grep -F "dev $dm," | tail -n 1 | sed -E 's/^\[ *[0-9.]+\] //' | grep .
}
if msg=$(kernel_io_error); then
  echo "  (kernel logged: $msg)"
  : > "$A"
  /usr/local/sbin/healthcheck run
  check "real kernel error is saved" grep -qF "$msg" "$A"
  /usr/local/sbin/healthcheck ack
  check "ack doesn't bring this boot's errors straight back" test ! -s "$A"
  cur=$(tr -d - < /proc/sys/kernel/random/boot_id)
  if journalctl -q --no-pager -k -b "$cur" -o cat 2>/dev/null | grep -qxF -- "$msg"; then
    dmesg -C   # gone from dmesg, still in the journal
    : > "$A"; : > "$STATE/alerts.acked.log"; echo "$cur" > "$STATE/scan_boot"
    /usr/local/sbin/healthcheck run
    check "real journalctl: kernel error recovered from the journal" grep -qF "journal: $msg" "$A"
  else
    echo "  skip real journalctl check (this system's journal doesn't record kernel messages)"
  fi
else
  echo "  skip real kernel error checks (no device-mapper here)"
fi
: > "$A"; echo running > "$STATE/boot_state"

section "ZFS pools (fake zpool)"
FAKEBIN=$(mktemp -d)
cat > "$FAKEBIN/zpool" <<'EOF'
#!/bin/bash
# fake zpool: one pool "tank" in state $FAKE_HEALTH whose last scan line is $FAKE_SCAN
case "${FAKE_MODE:-}" in   # machines where ZFS isn't really in use
  nomodule) echo "The ZFS modules are not loaded." >&2; exit 1 ;;
  nopools)  exit 0 ;;
  chatty)   echo "no pools available"; exit 0 ;;
esac
case "$1 $2" in
  "list -H") printf 'tank\t%s\n' "$FAKE_HEALTH" ;;
  "status -x") if [ "$FAKE_HEALTH" = ONLINE ] && [ -z "${FAKE_ERRORS:-}" ]; then echo "pool 'tank' is healthy"
               elif [ -n "${FAKE_ERRORS:-}" ]; then   # wrapped like the real thing
                 printf '  pool: tank\n state: %s\nstatus: %s\n\tattempt was made to correct the error.\n action: ...\n' "$FAKE_HEALTH" "$FAKE_ERRORS"
               else
                 printf '  pool: tank\n state: %s\nstatus: One or more devices could not be used because the label is missing or\n\tinvalid.  Sufficient replicas exist for the pool to continue\n action: ...\n' "$FAKE_HEALTH"
               fi ;;
  "status tank") printf '  pool: tank\n state: %s\n  scan: %s\nconfig:\n\nerrors: No known data errors\n' "$FAKE_HEALTH" "$FAKE_SCAN" ;;
esac
EOF
chmod +x "$FAKEBIN/zpool"
zfs_line() {  # usage: zfs_line HEALTH SCAN [ERRORS]; prints the pool's status line
  FAKE_HEALTH=$1 FAKE_SCAN=$2 FAKE_ERRORS=${3:-} PATH="$FAKEBIN:$PATH" /usr/local/sbin/healthcheck run
  grep '|zfs:tank|' "$STATUS"
}
no_zfs_line() {  # usage: no_zfs_line MODE; succeeds if the run worked and printed no zfs line
  FAKE_MODE=$1 PATH="$FAKEBIN:$PATH" /usr/local/sbin/healthcheck run && test -s "$STATUS" && ! grep -q '|zfs:' "$STATUS"
}
if command -v zpool >/dev/null; then
  echo "  (zpool is installed here, so the not-installed case is skipped)"
else
  /usr/local/sbin/healthcheck run
  check "zpool not installed (a Pi, most Debian boxes): no zfs line" bash -c "! grep -q '|zfs:' '$STATUS'"
fi
check "zpool installed but ZFS module not loaded: no zfs line" no_zfs_line nomodule
check "zpool installed but no pools: no zfs line" no_zfs_line nopools
check "a stray non-pool line from zpool isn't shown as a pool" no_zfs_line chatty
scrubbed() { echo "scrub repaired 0B in 00:10:12 with ${2:-0} errors on $(date -d "$1 days ago" '+%a %b %e %T %Y')"; }
l=$(zfs_line ONLINE "$(scrubbed 3)");  echo "    $l"
check "healthy pool, recent scrub: OK with its age" grep -qx 'OK|zfs:tank|ONLINE, scrubbed 3 day(s) ago' <<<"$l"
l=$(zfs_line ONLINE "$(scrubbed 60)"); echo "    $l"
check "scrub older than 45 days: warns overdue" grep -q '^WARN|zfs:tank|.*overdue' <<<"$l"
l=$(zfs_line ONLINE "$(scrubbed 2 5)"); echo "    $l"
check "last scrub found errors: warns" grep -q '^WARN|zfs:tank|.*last scrub found 5 error' <<<"$l"
l=$(zfs_line ONLINE "none requested"); echo "    $l"
check "never scrubbed: info, not a warning" grep -q '^INFO|zfs:tank|.*no completed scrub' <<<"$l"
l=$(zfs_line ONLINE "scrub in progress since $(date '+%a %b %e %T %Y')"); echo "    $l"
check "scrub running: OK" grep -q '^OK|zfs:tank|ONLINE, scrub running' <<<"$l"
l=$(zfs_line ONLINE "$(scrubbed 3)" "One or more devices has experienced an unrecoverable error.  An"); echo "    $l"
check "device errors: warns with zpool's reason (first sentence, unwrapped)" \
  grep -qx 'WARN|zfs:tank|ONLINE, One or more devices has experienced an unrecoverable error, scrubbed 3 day(s) ago' <<<"$l"
check "and says where to look" grep -q 'details: sudo zpool status -v tank' "$STATUS"
l=$(zfs_line DEGRADED "$(scrubbed 3)"); echo "    $l"
check "degraded pool: warns with zpool's reason" \
  grep -qx 'WARN|zfs:tank|DEGRADED, One or more devices could not be used because the label is missing or invalid, scrubbed 3 day(s) ago' <<<"$l"
l=$(zfs_line FAULTED "none requested"); echo "    $l"
check "faulted pool: critical" grep -q '^CRIT|zfs:tank|FAULTED' <<<"$l"
rm -rf "$FAKEBIN"

section "ZFS pools (real ZFS)"
ZDIR=""
if command -v zpool >/dev/null && modprobe zfs 2>/dev/null; then
  ZDIR=$(mktemp -d)
  truncate -s 256M "$ZDIR/a" "$ZDIR/b"
  zpool create -f -m none hctest mirror "$ZDIR/a" "$ZDIR/b" || ZDIR=""
fi
if [ -n "$ZDIR" ]; then
  zline() { /usr/local/sbin/healthcheck run; grep '|zfs:hctest|' "$STATUS"; }
  l=$(zline); echo "    $l"
  check "new pool: online, not scrubbed yet" grep -q '^INFO|zfs:hctest|ONLINE, no completed scrub' <<<"$l"
  zpool scrub -w hctest
  l=$(zline); echo "    $l"
  check "after a scrub: OK, scrubbed 0 days ago" grep -qx 'OK|zfs:hctest|ONLINE, scrubbed 0 day(s) ago' <<<"$l"
  zpool offline hctest "$ZDIR/b"
  l=$(zline); echo "    $l"
  check "a mirror side offline: degraded warning" grep -q '^WARN|zfs:hctest|DEGRADED' <<<"$l"
  zpool online hctest "$ZDIR/b"; zpool wait -t resilver hctest 2>/dev/null; sleep 1
  zpool scrub -w hctest
  dd if=/dev/urandom of="$ZDIR/b" bs=1M seek=16 count=200 conv=notrunc status=none   # corrupt one side, past the labels
  zpool scrub -w hctest
  l=$(zline); echo "    $l"
  check "checksum errors repaired by a scrub still warn" grep -q '^WARN|zfs:hctest|ONLINE, .*unrecoverable error, scrubbed' <<<"$l"
  zpool clear hctest
  l=$(zline); echo "    $l"
  check "after zpool clear: OK again" grep -q '^OK|zfs:hctest|ONLINE, scrubbed 0 day(s) ago' <<<"$l"
  zpool destroy hctest; rm -rf "$ZDIR"
elif [ -n "${HC_REQUIRE_ZFS:-}" ]; then
  fail "real ZFS required (HC_REQUIRE_ZFS) but no pool could be created"
else
  echo "  skip real ZFS checks (ZFS not available here)"
fi

section "failed services and the ignore list"
check "ignore list created" test -f "$IGNORE"
printf '[Service]\nType=oneshot\nExecStart=/bin/false\n' > /etc/systemd/system/hc-test-fail.service
systemctl daemon-reload
systemctl start hc-test-fail.service 2>/dev/null
/usr/local/sbin/healthcheck run
check "failed unit is reported" grep -q '^WARN|services|failed:.*hc-test-fail\.service' "$STATUS"
check "with a hint on how to hide it" grep -q "hide: add it to $IGNORE" "$STATUS"
echo 'hc-test-*.service   # glob' >> "$IGNORE"
/usr/local/sbin/healthcheck run
check "ignored unit (by glob) is hidden" bash -c "! grep -q 'hc-test-fail' '$STATUS'"
check "ignored unit is still counted" grep -q '^[A-Z]*|services|.*(1 ignored)$' "$STATUS"
rm -f /etc/systemd/system/hc-test-fail.service
systemctl reset-failed hc-test-fail.service 2>/dev/null; systemctl daemon-reload

section "reinstall is idempotent"
bash "$INSTALLER" "$@" >"$LOG" 2>&1; rc=$?
check "reinstall exits 0" test "$rc" = 0
check "no files rewritten" bash -c "! grep -q 'wrote ' '$LOG'"
check "no backups made" bash -c "! grep -q 'backed up' '$LOG'"
check "ignore list edits kept" grep -q '^hc-test-' "$IGNORE"

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
check "ignore list kept without --purge" test -f "$IGNORE"
bash "$INSTALLER" --uninstall --purge >/dev/null 2>&1
check "--purge removes state" test ! -e "$STATE"
check "--purge removes the ignore list" test ! -e "$IGNORE"

finish
