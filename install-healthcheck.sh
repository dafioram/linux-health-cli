#!/bin/bash
# install-healthcheck.sh - installs the login health dashboard
# Works on Raspberry Pi (DietPi/Raspbian) and generic Debian PCs.
#
# usage: sudo ./install-healthcheck.sh [options]
#   --no-apt           skip installing smartmontools
#   --run-weekly-now   start the weekly dpkg verification in the background
#   --uninstall        remove units and scripts (keeps saved alert history)
#   --purge            with --uninstall, also delete /var/lib/healthcheck
#   -h, --help         show this help

set -u

SBIN=/usr/local/sbin/healthcheck
HOOK=/etc/profile.d/healthcheck.sh
UNITDIR=/etc/systemd/system
STATE=/var/lib/healthcheck
UNITS=(healthcheck.service healthcheck.timer healthcheck-weekly.service healthcheck-weekly.timer healthcheck-marker.service)
ENABLE=(healthcheck-marker.service healthcheck.timer healthcheck-weekly.timer)

DO_APT=1; RUN_WEEKLY=0; UNINSTALL=0; PURGE=0
STAMP=$(date +%Y%m%d-%H%M%S)
WARNINGS=0; ERRORS=0

c() { [ -t 1 ] && printf '\033[%sm' "$1"; }
info() { echo "$(c '1;32')[ok]$(c 0) $*"; }
note() { echo "$(c '1;36')[..]$(c 0) $*"; }
warn() { echo "$(c '1;33')[warn]$(c 0) $*" >&2; WARNINGS=$((WARNINGS+1)); }
err()  { echo "$(c '1;31')[fail]$(c 0) $*" >&2; ERRORS=$((ERRORS+1)); }
die()  { err "$*"; exit 1; }

for a in "$@"; do
  case $a in
    --no-apt) DO_APT=0 ;;
    --run-weekly-now) RUN_WEEKLY=1 ;;
    --uninstall) UNINSTALL=1 ;;
    --purge) PURGE=1 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) die "unknown option: $a (try --help)" ;;
  esac
done

# --- must be root ---
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    note "re-running with sudo..."
    exec sudo bash "$0" "$@"
  fi
  die "run as root (sudo not available)"
fi

# --- uninstall path ---
if [ "$UNINSTALL" = 1 ]; then
  note "uninstalling..."
  for u in "${ENABLE[@]}"; do systemctl disable --now "$u" >/dev/null 2>&1; done
  for u in "${UNITS[@]}"; do rm -f "$UNITDIR/$u"; done
  rm -f "$SBIN" "$HOOK" /run/healthcheck.status
  systemctl daemon-reload >/dev/null 2>&1
  if [ "$PURGE" = 1 ]; then rm -rf "$STATE"; info "removed $STATE"; else note "kept $STATE (use --purge to delete)"; fi
  info "uninstalled"
  exit 0
fi

# --- preflight ---
[ -d /run/systemd/system ] || die "systemd is not running as init; this installer requires systemd"
command -v systemctl >/dev/null 2>&1 || die "systemctl not found"

missing=()
for cmd in bash awk grep sed df stat mktemp date dmesg lsblk dpkg cmp timeout; do
  command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
if [ ${#missing[@]} -gt 0 ]; then
  warn "missing commands: ${missing[*]} (some checks may be skipped or fail)"
fi

if [ -r /proc/device-tree/model ]; then
  info "detected: $(tr -d '\0' < /proc/device-tree/model)"
else
  info "detected: generic PC ($(uname -m))"
fi

# --- install packages (non-fatal) ---
if [ "$DO_APT" = 1 ]; then
  if command -v smartctl >/dev/null 2>&1; then
    info "smartmontools already installed"
  elif command -v apt-get >/dev/null 2>&1; then
    note "installing smartmontools..."
    export DEBIAN_FRONTEND=noninteractive
    if ! apt-get install -y --no-install-recommends smartmontools >/dev/null 2>&1; then
      note "install failed, refreshing package lists and retrying..."
      apt-get update >/dev/null 2>&1
      if apt-get install -y --no-install-recommends smartmontools >/dev/null 2>&1; then
        info "smartmontools installed"
      else
        warn "could not install smartmontools (no network or apt locked?). SMART checks will show an 'install smartmontools' notice. Re-run later."
      fi
    else
      info "smartmontools installed"
    fi
  else
    warn "apt-get not found; install smartmontools manually if you have SMART-capable drives"
  fi
else
  note "skipping apt (--no-apt)"
fi

# --- file writer: backup if changed, write atomically ---
write_file() {  # usage: write_file PATH MODE  (content on stdin)
  local path=$1 mode=$2 tmp
  mkdir -p "$(dirname "$path")" || { err "cannot create $(dirname "$path")"; cat >/dev/null; return 1; }
  tmp=$(mktemp "${path}.new.XXXXXX") || { err "cannot create temp file for $path"; cat >/dev/null; return 1; }
  cat > "$tmp"
  if [ -f "$path" ] && cmp -s "$tmp" "$path"; then
    rm -f "$tmp"; chmod "$mode" "$path"; note "unchanged: $path"; return 0
  fi
  if [ -f "$path" ]; then
    cp -p "$path" "$path.bak.$STAMP" && note "backed up old file to $path.bak.$STAMP"
  fi
  chmod "$mode" "$tmp" && mv -f "$tmp" "$path" || { err "failed writing $path"; rm -f "$tmp"; return 1; }
  info "wrote $path"
}

mkdir -p "$STATE" || warn "could not create $STATE"

# ==================== the collector ====================
write_file "$SBIN" 0755 <<'HC_EOF'
#!/bin/bash
# usage: healthcheck [run|weekly|ack|boot|shutdown]
set -u
STATE=/var/lib/healthcheck
ALERTS=$STATE/alerts.log
WEEKLY=$STATE/weekly.status
OUT=/run/healthcheck.status
PAT='I/O error|EXT4-fs error|Remounting filesystem read-only|mmc[0-9]+: .*([Tt]imeout|CRC|error)|blk_update_request|[Uu]nder-?voltage|usb [0-9.-]+: (USB disconnect|device descriptor read|device not accepting address|unable to enumerate|Cannot enable)|nvme[0-9]+: .*(timeout|reset)|ata[0-9.]+: .*(exception|failed|error)|Out of memory|oom-kill|Call trace|Hardware Error|Machine check'
mkdir -p "$STATE"

alert() { echo "$(date '+%F %T') | $1" >> "$ALERTS"; }

case "${1:-run}" in
  boot)      # unclean shutdown detection (Pi has no RTC, so early timestamps may be off)
    [ "$(cat "$STATE/boot_state" 2>/dev/null)" = running ] && alert "unclean shutdown before this boot (power loss or crash?)"
    echo running > "$STATE/boot_state"; exit 0 ;;
  shutdown)  echo clean > "$STATE/boot_state"; exit 0 ;;
  weekly)
    res=$(nice -n 19 dpkg --verify 2>&1 | grep -v ' c /' | grep -vE '/var/lib/(apt/(mirrors(/partial)?|periodic)|rpimonitor/updatestatus\.txt)$')   # ignore modified config files and known DietPi/rpimonitor noise
    { date '+%F'; grep -c . <<<"$res"; [ -n "$res" ] && head -n 10 <<<"$res"; } > "$WEEKLY"
    exit 0 ;;
  ack)       [ -s "$ALERTS" ] && { cat "$ALERTS" >> "$STATE/alerts.acked.log"; : > "$ALERTS"; } ;;
  run)       ;;
  *)         echo "usage: $0 [run|weekly|ack]"; exit 1 ;;
esac

TMP=$(mktemp /run/healthcheck.XXXXXX)
add()  { printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$TMP"; }   # LEVEL|label|message
have() { command -v "$1" >/dev/null 2>&1; }
BOOT=$(cut -c1-8 /proc/sys/kernel/random/boot_id)

# --- Power / throttling (Pi only; original Pi 1 Model B has no undervoltage detector) ---
VC=$(command -v vcgencmd || true)
[ -z "$VC" ] && [ -x /opt/vc/bin/vcgencmd ] && VC=/opt/vc/bin/vcgencmd
if [ -n "$VC" ]; then
  th=$("$VC" get_throttled 2>/dev/null); th=${th#*=}
  if [[ $th =~ ^0x[0-9a-fA-F]+$ ]]; then
    v=$((th))
    if   (( v & 0xF ));     then add CRIT power "happening NOW ($th): undervoltage/throttling"
    elif (( v & 0xF0000 )); then add WARN power "occurred since boot ($th), fine right now"
    else                         add OK   power "no undervoltage or throttling flagged"; fi
  fi
fi

# --- Temperature (any board with thermal zones) ---
t=0
for z in /sys/class/thermal/thermal_zone*/temp; do
  v=$(cat "$z" 2>/dev/null) || continue
  [[ $v =~ ^[0-9]+$ ]] || continue
  v=$((v/1000)); [ "$v" -gt "$t" ] && t=$v
done
if [ "$t" -gt 0 ]; then
  if   [ "$t" -ge 80 ]; then add CRIT temp "${t}°C"
  elif [ "$t" -ge 70 ]; then add WARN temp "${t}°C"
  else                       add OK   temp "${t}°C"; fi
fi

# --- Kernel errors this boot (also saved persistently, deduped, max 20 new per run) ---
errs=$(dmesg 2>/dev/null | grep -E "$PAT")
n=$(grep -c . <<<"$errs")
if [ "$n" -gt 0 ]; then
  new=0
  while [ "$new" -lt 20 ] && IFS= read -r l; do
    grep -qF "| $BOOT | $l" "$ALERTS" 2>/dev/null && continue
    alert "$BOOT | $l"; new=$((new+1))
  done <<<"$errs"
  add WARN kernel "$n error-like lines since boot, latest:"
  tail -n 3 <<<"$errs" | while IFS= read -r l; do add DETAIL "" "$l"; done
else
  add OK kernel "no storage/USB/power errors since boot"
fi
if [ -f "$ALERTS" ] && [ "$(wc -l < "$ALERTS")" -gt 300 ]; then
  tail -n 200 "$ALERTS" > "$ALERTS.tmp" && mv "$ALERTS.tmp" "$ALERTS"
fi

# --- Read-only mounts ---
ro=""
while read -r _ mp fs opts _; do
  case $fs in ext2|ext3|ext4|btrfs|xfs|f2fs|vfat|exfat|ntfs3) ;; *) continue ;; esac
  case ",$opts," in *,ro,*) ro="$ro $mp" ;; esac
done < /proc/mounts
if [ -n "$ro" ]; then add CRIT mounts "READ-ONLY:$ro (kernel remounts on fs errors)"; else add OK mounts "all filesystems writable"; fi

# --- ext4 persistent error counters ---
eb=""; seen=0
for f in /sys/fs/ext4/*/errors_count; do
  [ -r "$f" ] || continue
  seen=1; c=$(cat "$f"); [ "$c" -gt 0 ] && eb="$eb $(basename "$(dirname "$f")")=$c"
done
if [ -n "$eb" ]; then add WARN ext4 "errors recorded:$eb (stays until fsck clears it)"
elif [ "$seen" = 1 ]; then add OK ext4 "error counters are zero"; fi

# --- Space and inodes, one line per mount ---
usage_check() {  # $1=word for display ("space"|"inodes") $2=df field
  local pct mp free
  while read -r pct mp; do
    pct=${pct%\%}
    [[ $pct =~ ^[0-9]+$ ]] || continue       # filesystems with no inodes show "-"
    free=$((100 - pct))
    if [ "$free" -le 10 ]; then
      add WARN "$mp" "$free% free $1, low"
    else
      add OK "$mp" "$free% free $1"
    fi
  done < <(df -l -x tmpfs -x devtmpfs -x squashfs -x overlay --output="$2",target 2>/dev/null | tail -n +2)
}
usage_check space pcent
usage_check inodes ipcent

# --- Drives ---
smart_check() {
  local dev=/dev/$1 out bad wear used hrs msg lvl=OK
  out=$(timeout 30 smartctl -H -A "$dev" 2>&1)
  grep -qE 'overall-health|SMART Health Status' <<<"$out" || out=$(timeout 30 smartctl -d sat -H -A "$dev" 2>&1)
  if ! grep -qE 'overall-health|SMART Health Status' <<<"$out"; then
    add INFO "$1" "no SMART support (normal for USB flash drives)"; return
  fi
  if grep -qE 'overall-health.*FAILED|Health Status: (FAILED|FAILING)' <<<"$out"; then
    add CRIT "$1" "SMART health FAILED - back up now"; return
  fi
  bad=$(awk '$2 ~ /^(Reallocated_Sector_Ct|Current_Pending_Sector|Offline_Uncorrectable|Reported_Uncorrect)$/ && $10+0>0 {printf "%s=%s ",$2,$10}' <<<"$out")
  wear=$(awk '$2 ~ /^(Wear_Leveling_Count|Media_Wearout_Indicator|Percent_Lifetime_Remain|SSD_Life_Left|Remaining_Lifetime_Perc)$/ {print $4+0; exit}' <<<"$out")
  used=$(awk -F: '/Percentage Used/ {gsub(/[ %]/,"",$2); print $2}' <<<"$out")
  hrs=$(awk '$2=="Power_On_Hours" {print $10+0; exit}' <<<"$out")
  msg="SMART passed"
  [ -n "$hrs" ]  && msg="$msg, ${hrs}h on"
  [ -n "$wear" ] && { msg="$msg, ~${wear}% life left"; [ "$wear" -lt 20 ] && lvl=WARN; }
  [ -n "$used" ] && { msg="$msg, ${used}% life used"; [ "$used" -ge 80 ] && lvl=WARN; }
  [ -n "$bad" ]  && { msg="$msg, BAD SECTORS: $bad"; lvl=WARN; }
  add "$lvl" "$1" "$msg"
}
for d in $(lsblk -dnro NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}'); do
  case $d in
    mmcblk*boot*|zram*|ram*|loop*) continue ;;
    mmcblk*) add INFO "$d" "SD/eMMC has no SMART; judged by kernel, ext4 and mount checks"; continue ;;
  esac
  have smartctl || { add INFO "$d" "smartctl missing (apt install smartmontools)"; continue; }
  smart_check "$d"
done

# --- Memory, services ---
read -r tot avail < <(awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{print t,a}' /proc/meminfo)
if [ -n "${tot:-}" ] && [ -n "${avail:-}" ]; then
  p=$((avail*100/tot))
  if [ "$p" -lt 10 ]; then add WARN memory "only ${p}% available"; else add OK memory "${p}% available"; fi
fi
if have systemctl; then
  failed=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | head -n 5 | tr '\n' ' ')
  if [ -n "$failed" ]; then add WARN services "failed: $failed"; else add OK services "no failed units"; fi
fi

# --- Weekly package verification result ---
if [ -f "$WEEKLY" ]; then
  { IFS= read -r wd; IFS= read -r wc; } < "$WEEKLY"
  if [ "${wc:-0}" = 0 ]; then add OK weekly "package files verified clean on $wd"
  else add WARN weekly "$wc package files differ ($wd):"; sed -n '3,5p' "$WEEKLY" | while IFS= read -r l; do add DETAIL "" "$l"; done; fi
else
  add INFO weekly "weekly package check hasn't run yet"
fi

# --- Past events that are no longer in dmesg ---
if [ -s "$ALERTS" ]; then
  old=$(grep -vc -- "| $BOOT |" "$ALERTS")
  if [ "$old" -gt 0 ]; then
    add WARN history "$old unacknowledged event(s) from earlier boots, newest:"
    grep -v -- "| $BOOT |" "$ALERTS" | tail -n 3 | while IFS= read -r l; do add DETAIL "" "$l"; done
    add DETAIL "" "review: sudo less $ALERTS    clear: sudo healthcheck ack"
  fi
fi

add TS "$(cut -d. -f1 /proc/uptime)" ""   # uptime at write; age survives clock jumps (no RTC)
chmod 644 "$TMP"; mv -f "$TMP" "$OUT"
HC_EOF

if [ -f "$SBIN" ]; then
  if bash -n "$SBIN" 2>/dev/null; then info "syntax check passed for $SBIN"; else err "syntax check FAILED for $SBIN"; fi
fi

# ==================== the login hook ====================
write_file "$HOOK" 0644 <<'HOOK_EOF'
case $- in *i*) ;; *) return 0 ;; esac      # interactive only (scp/rsync/ssh cmd never print)
[ -t 1 ] || return 0                         # must be a real terminal
[ -n "${HEALTH_SHOWN:-}" ] && return 0       # once per login, not per nested shell
export HEALTH_SHOWN=1
_hc=/run/healthcheck.status
_up=$(cut -d. -f1 /proc/uptime 2>/dev/null)
if [ -r "$_hc" ]; then
  _ts=$(sed -n 's/^TS|\([0-9]*\)|.*/\1/p' "$_hc")
  if [ -n "$_ts" ] && [ -n "$_up" ]; then _age=$(( (_up - _ts) / 60 ))
  else _age=$(( ($(date +%s) - $(stat -c %Y "$_hc")) / 60 )); fi
  printf '\033[1;33m--- System health (checked %s min ago) ---\033[0m\n' "$_age"
  [ "$_age" -gt 40 ] && printf '\033[1;31m ⚠ status is stale, is healthcheck.timer running?\033[0m\n'
  while IFS='|' read -r _l _n _m; do
    case $_l in
      OK)     printf ' \033[1;32m✓\033[0m %-16s %s\n' "$_n" "$_m" ;;
      INFO)   printf ' \033[1;36m·\033[0m %-16s %s\n' "$_n" "$_m" ;;
      WARN)   printf ' \033[1;33m⚠\033[0m %-16s %s\n' "$_n" "$_m" ;;
      CRIT)   printf ' \033[1;31m✗\033[0m %-16s %s\n' "$_n" "$_m" ;;
      DETAIL) printf '     %s\n' "$_m" ;;
    esac
  done < "$_hc"
  echo
else                                         # /run is wiped at boot; say so instead of printing nothing
  printf '\033[1;33m--- System health: no results yet this boot ---\033[0m\n'
  if [ "${_up:-0}" -lt 300 ]; then
    printf ' first check runs about 30s after boot; log in again in a minute\n'
  else
    printf '\033[1;31m ⚠ check: systemctl status healthcheck.timer healthcheck.service\033[0m\n'
  fi
  echo
fi
unset _hc _age _up _ts _l _n _m
HOOK_EOF

# ==================== systemd units ====================
write_file "$UNITDIR/healthcheck.service" 0644 <<'U_EOF'
[Unit]
Description=System health check (writes /run/healthcheck.status)

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/healthcheck run
Nice=10
# oneshot units never time out by default; a hung run would stop the timer re-firing for good
TimeoutStartSec=10min
U_EOF

write_file "$UNITDIR/healthcheck.timer" 0644 <<'U_EOF'
[Unit]
Description=Run system health check every 15 minutes

[Timer]
OnBootSec=30s
OnUnitActiveSec=15min
AccuracySec=10s

[Install]
WantedBy=timers.target
U_EOF

write_file "$UNITDIR/healthcheck-weekly.service" 0644 <<'U_EOF'
[Unit]
Description=Weekly package file verification (dpkg --verify)

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/healthcheck weekly
Nice=19
IOSchedulingClass=idle
U_EOF

write_file "$UNITDIR/healthcheck-weekly.timer" 0644 <<'U_EOF'
[Unit]
Description=Weekly package file verification

[Timer]
OnCalendar=Sun *-*-* 03:30:00
Persistent=true

[Install]
WantedBy=timers.target
U_EOF

write_file "$UNITDIR/healthcheck-marker.service" 0644 <<'U_EOF'
[Unit]
Description=Clean/unclean shutdown marker for health check

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/healthcheck boot
ExecStop=/usr/local/sbin/healthcheck shutdown

[Install]
WantedBy=multi-user.target
U_EOF

# ==================== activate ====================
note "reloading systemd..."
systemctl daemon-reload || err "daemon-reload failed"

# every unit must be loaded before we try to enable anything
for u in "${UNITS[@]}"; do
  state=$(systemctl show -p LoadState --value "$u" 2>/dev/null)
  if [ "$state" != loaded ]; then
    err "$u is not loaded (LoadState=${state:-unknown}); check $UNITDIR/$u"
  fi
done

if command -v systemd-analyze >/dev/null 2>&1; then
  # verify also loads every unit ours depend on; only report notes about our own units
  vout=$(systemd-analyze verify "${UNITS[@]/#/$UNITDIR/}" 2>&1 | grep healthcheck)
  [ -n "$vout" ] && warn "systemd-analyze verify notes:"$'\n'"$vout"
fi

for u in "${ENABLE[@]}"; do
  if systemctl enable --now "$u" >/dev/null 2>&1; then
    info "enabled and started $u"
  else
    err "could not enable/start $u (see: systemctl status $u)"
  fi
done

# ==================== first run ====================
note "running first health check..."
if "$SBIN" run && [ -r /run/healthcheck.status ]; then
  echo
  while IFS='|' read -r l n m; do
    case $l in
      OK)     printf ' %s✓%s %-16s %s\n' "$(c '1;32')" "$(c 0)" "$n" "$m" ;;
      INFO)   printf ' %s·%s %-16s %s\n' "$(c '1;36')" "$(c 0)" "$n" "$m" ;;
      WARN)   printf ' %s⚠%s %-16s %s\n' "$(c '1;33')" "$(c 0)" "$n" "$m" ;;
      CRIT)   printf ' %s✗%s %-16s %s\n' "$(c '1;31')" "$(c 0)" "$n" "$m" ;;
      DETAIL) printf '     %s\n' "$m" ;;
    esac
  done < /run/healthcheck.status
  echo
else
  err "first run of $SBIN failed; try running it manually: sudo $SBIN run"
fi

if [ "$RUN_WEEKLY" = 1 ]; then
  systemctl start --no-block healthcheck-weekly.service && info "weekly verification started in background (slow on a Pi 1; result appears in a later refresh)"
fi

# ==================== post-install advice ====================
if [ -r /etc/profile ] && ! grep -q 'profile.d' /etc/profile 2>/dev/null; then
  warn "/etc/profile doesn't appear to source /etc/profile.d. If nothing prints at login, add this line to ~/.bashrc:  . $HOOK"
fi

old=$(grep -l 'LOGIN DASHBOARD' /root/.bashrc /home/*/.bashrc 2>/dev/null)
[ -n "$old" ] && warn "old dashboard block still found in: $(echo $old). Delete it to avoid duplicate output."

echo
systemctl list-timers 'healthcheck*' --no-pager 2>/dev/null
echo
if [ "$ERRORS" -gt 0 ]; then
  echo "$(c '1;31')Finished with $ERRORS error(s) and $WARNINGS warning(s).$(c 0) Scroll up for [fail] lines."
  exit 1
fi
echo "$(c '1;32')Done.$(c 0) $WARNINGS warning(s). Log out and back in over SSH to see the dashboard."
echo "Acknowledge saved alerts with: sudo healthcheck ack"
echo "Uninstall with: sudo $0 --uninstall"