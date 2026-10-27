# linux-health-cli

A small health dashboard that prints when you log in over SSH. It is for headless
Debian-family machines: Raspberry Pi (DietPi/Raspbian), mini PCs, home servers.

```
--- System health (checked 4 min ago) ---
 ✓ kernel           no storage/USB/power errors since boot
 ✓ mounts           all filesystems writable
 ✓ ext4             error counters are zero
 ✓ /                58% free space
 ✓ /boot/efi        94% free space
 ✓ /                94% free inodes
 ✓ sda              SMART passed, 41234h on
 ✓ nvme0n1          SMART passed, 3% life used
 ✓ memory           93% available
 ✓ services         no failed units
 ✓ weekly           package files verified clean on 2026-10-18
```

`✓` OK · `·` info · `⚠` warning · `✗` critical

A systemd timer collects the checks in the background. Logging in only reads a small
file, so the dashboard never slows down your SSH login, and scp/rsync/`ssh host cmd`
never print it.

## Install

```sh
sudo ./install-healthcheck.sh
```

You need systemd as init. The installer installs `smartmontools` with apt if it is
missing, runs a first check, and shows you the result. Log out and back in to see the
dashboard. Running the installer again is safe: unchanged files are left alone, and
changed ones are backed up as `*.bak.<timestamp>` first.

| Option | |
|---|---|
| `--no-apt` | don't install smartmontools |
| `--run-weekly-now` | start the package verification now, in the background |
| `--uninstall` | remove the scripts and units, but keep the alert history |
| `--uninstall --purge` | also delete `/var/lib/healthcheck` and `/etc/healthcheck` |

Clear saved alerts once you've read them with `sudo healthcheck ack`. They are moved
to `alerts.acked.log`. The same command accepts each drive's current lifetime error
counts (see [Bad sectors and read errors](#bad-sectors-and-read-errors)).

## What it checks

| Line | Source | Warns when |
|---|---|---|
| `power` | `vcgencmd get_throttled` (Raspberry Pi only) | ✗ undervoltage/throttling now, ⚠ it happened since boot |
| `temp` | hottest `/sys/class/thermal` zone | ⚠ ≥70 °C, ✗ ≥80 °C |
| `kernel` | `dmesg` this boot, plus the journal after a crash ([see below](#how-it-works)): I/O errors, ext4 errors, read-only remounts, SD/eMMC timeouts and CRC errors, NVMe resets, ATA errors, USB disconnects, undervoltage, OOM kills, call traces, machine checks | ⚠ any match (shows the latest 3) |
| `mounts` | `/proc/mounts` for ext2/3/4, btrfs, xfs, f2fs, vfat, exfat, ntfs3 | ✗ any of them mounted read-only |
| `ext4` | `/sys/fs/ext4/*/errors_count` | ⚠ any count above zero (stays until `fsck` clears it) |
| one per mount | `df`: space, then inodes (ZFS and btrfs mounts: see their own lines) | ⚠ 10% or less free |
| one per disk | `smartctl` (see below) | see below |
| `memory` | `MemAvailable` | ⚠ under 10% |
| `zfs:<pool>` | `zpool list` and `zpool status` ([see below](#zfs-pools)) | ✗ faulted/unavailable, ⚠ degraded, errors, or scrub overdue |
| `btrfs:<mount>` | `btrfs filesystem usage`, `device stats`, `scrub status` ([see below](#btrfs-filesystems)) | ⚠ low space, missing device, device errors, or scrub overdue |
| `services` | `systemctl --failed`, minus your [ignore list](#failed-services) | ⚠ any failed unit |
| `weekly` | `dpkg --verify`, Sundays 03:30 (ignores changed config files) | ⚠ package files that differ from what was installed |
| `history` | saved alerts from earlier boots | ⚠ any you haven't acknowledged |

### Disks

Disks show up in two places on the dashboard.

**Per mount point** (labelled by path, e.g. `/`, `/boot/efi`):

- Space and inodes, one line each. Only local filesystems are checked. tmpfs,
  devtmpfs, squashfs and overlay are skipped, and so is ZFS: its free space is on
  the [pool line](#zfs-pools) instead. btrfs is skipped too when btrfs-progs is
  installed, for its [own line](#btrfs-filesystems). Filesystems with no inode count
  (vfat, btrfs without btrfs-progs) only get a space line.
- Read-only status. All read-only mounts are listed together on the `mounts` line.
  The kernel remounts a filesystem read-only when it hits errors, so this is CRIT.
- ext4 error counters, listed together on the `ext4` line by device (e.g. `mmcblk0p2=3`).

**Per physical disk** (labelled by device, e.g. `sda`, `nvme0n1`), from `smartctl -H -A`.
If that finds no SMART data, it retries with `-d sat`, which is what most USB-to-SATA
enclosures need:

| Drive | Typical line | Warns when |
|---|---|---|
| SATA hard disk | `SMART passed, 41234h on` | ⚠ [bad sectors or read errors](#bad-sectors-and-read-errors) |
| SATA SSD | `SMART passed, 9120h on, ~93% life left` | ⚠ under 20% life left. Life left is the normalized value of the first of Wear_Leveling_Count, Media_Wearout_Indicator, Percent_Lifetime_Remain, SSD_Life_Left, Remaining_Lifetime_Perc. Bad sectors warn as for hard disks. |
| NVMe SSD | `SMART passed, 3% life used` | ⚠ 80% or more of rated life used |
| SAS/SCSI disk | `SMART passed` | health status only |
| USB-SATA enclosure | same as SATA, via `-d sat` | same as SATA |
| Any drive failing its SMART self-assessment | `SMART health FAILED - back up now` | ✗ always |
| USB flash drive, VM disk, unsupported USB bridge | `no SMART support (normal for USB flash drives)` | info only |
| SD card / eMMC (`mmcblk*`) | `SD/eMMC has no SMART; judged by kernel, ext4 and mount checks` | info only |

#### Bad sectors and read errors

| Attribute | Shown as | Warns |
|---|---|---|
| 5 Reallocated_Sector_Ct | `24 reallocated sector(s)` | until acknowledged, then only when it grows: `26 reallocated sector(s) (2 new)` |
| 187 Reported_Uncorrect | `3 uncorrectable read error(s)` | the same |
| 197 Current_Pending_Sector | `8 pending (unreadable) sector(s)` | always |
| 198 Offline_Uncorrectable | `2 offline-uncorrectable sector(s)` | always |

Reallocated sectors and uncorrectable reads are lifetime counts that never go down,
so an old event would otherwise warn forever. Once you've checked the drive (a long
self-test, a ZFS scrub), `sudo healthcheck ack` records the current counts, and the
line becomes `3 old uncorrectable read error(s) (acked)` until the count grows.
Counts are kept per drive serial number. Pending and offline-uncorrectable sectors
are sectors the drive can't read right now, so they always warn.

Some firmware, for example HGST's, packs extra fields above the low 16 bits of these
raw values. `smartctl` might show `Reported_Uncorrect` as `524291` (hex `0x80003`)
for a drive whose error log holds 3 errors. Values above 65535 are therefore read
from their low 16 bits. If those are all zero, the raw value is shown as-is.

`zram`, `ram`, `loop` and the eMMC `boot` partitions are skipped. Without
smartmontools each disk shows `smartctl missing`.

SD cards and USB sticks don't report their own health. For those, the early signs
are the `kernel` line (mmc timeouts and CRC errors, I/O errors), the `ext4` counters,
and a mount suddenly going read-only.

Not covered: which mount lives on which disk, NVMe power-on hours and media-error
counts, SMART self-test logs, drive temperature, and mdadm RAID health. The
member disks of an mdadm array are still checked one by one.

### ZFS pools

Only machines that use ZFS get this. Without `zpool` (a Pi, most Debian installs),
with no pools, or with the ZFS module not loaded, there is no `zfs` line at all. The
installer never installs ZFS. If `zpool` is installed, each pool gets a `zfs:<pool>`
line with the pool's health, its free space, and its last scrub:

| Line | Level |
|---|---|
| `ONLINE, 25% free, scrubbed 12 day(s) ago` | ✓ |
| `ONLINE, 15% free (low for ZFS), ...` | ⚠ 20% or less free. ZFS slows down well before it is full. |
| `ONLINE, 25% free, scrub running` | ✓ |
| `ONLINE, 25% free, no completed scrub on record` | · run `sudo zpool scrub <pool>` once |
| `ONLINE, scrubbed 60 day(s) ago (overdue)` | ⚠ more than 45 days. Ubuntu and Debian scrub monthly by default. |
| `ONLINE, last scrub found 2 error(s)` | ⚠ |
| `ONLINE, One or more devices has experienced an unrecoverable error` | ⚠ any pool `zpool status -x` doesn't call healthy, with its reason. Checksum errors stay until `zpool clear`. |
| `DEGRADED, ...` | ⚠ |
| `FAULTED, ...` (or `UNAVAIL`, `SUSPENDED`) | ✗ |

Any warning adds `details: sudo zpool status -v <pool>`.

Free space comes from `zpool list`, which counts the whole pool. `df` on a ZFS
dataset only shows that dataset's view, and a pool with several datasets would get
several lines that disagree, so ZFS mounts don't get `df` lines. A dataset that
fills up its own `quota` isn't flagged.

### btrfs filesystems

Like ZFS, this only appears where it applies. Without btrfs-progs (the `btrfs`
command) or without a mounted btrfs filesystem, there is no `btrfs` line. Each
filesystem gets one `btrfs:<mountpoint>` line, named after its first mount, however
many subvolumes are mounted from it:

| Line | Level |
|---|---|
| `60% free, scrubbed 12 day(s) ago` | ✓ |
| `60% free, scrub running` | ✓ |
| `8% free (low), ...` | ⚠ 10% or less free |
| `60% free, no completed scrub on record` | · run `sudo btrfs scrub start /mountpoint` once |
| `60% free, scrubbed 60 day(s) ago (overdue)` | ⚠ more than 45 days. Debian and Ubuntu don't schedule btrfs scrubs by default; the `btrfsmaintenance` package can. |
| `60% free, last scrub found 12 error(s)` | ⚠ |
| `60% free, 3 device error(s) (corruption 3), ...` | ⚠ any non-zero `btrfs device stats` counter (read, write, flush, corruption, generation) |
| `60% free, device(s) missing (degraded), ...` | ⚠ |

Any warning adds `details: sudo btrfs device stats <mount>; sudo btrfs scrub status <mount>`.
The device error counters are lifetime counts that stay until you reset them. Once
the cause is fixed (often a cable or a failing disk), reset them with
`sudo btrfs device stats -z <mount>`.

Free space comes from `btrfs filesystem usage`, so it accounts for RAID profiles
(RAID1 stores everything twice) and for space btrfs has allocated but not filled.
Plain `df` often gets btrfs wrong.

### Failed services

Any failed systemd unit turns the `services` line into a warning. Many of these are
harmless one-offs: a message-of-the-day fetch that ran before the network was up, a
service for hardware the machine doesn't have, a mount for a drive that isn't plugged
in. In order of preference:

1. **Find out why:** `systemctl status UNIT` and `journalctl -b -u UNIT`.
2. **It failed once and won't again:** `sudo systemctl reset-failed UNIT`. Failed
   states also clear on reboot.
3. **This machine never needs it:** `sudo systemctl mask UNIT`. It won't run again,
   so it can't fail again.
4. **It's noise you want to keep running:** add it to `/etc/healthcheck/ignore-units`,
   one unit name or shell glob per line, `#` for comments:

   ```
   motd-news.service
   mnt-*.mount
   ```

   Ignored units drop off the warning, but the line still counts them, e.g.
   `no failed units (2 ignored)`. The installer creates this file once and never
   overwrites it.

smartmontools comes with `smartd`, a monitoring service that fails when there is no
SMART-capable disk to watch, for example on a Pi that runs from an SD card. The
dashboard only needs `smartctl`, so the installer disables `smartd` if it has failed
and tells you how to turn it back on.

## How it works

| File | Purpose |
|---|---|
| `/usr/local/sbin/healthcheck` | the collector: `run`, `weekly`, `ack`, `boot`, `shutdown` |
| `/etc/profile.d/healthcheck.sh` | login hook: prints `/run/healthcheck.status` in interactive terminal logins, once per login |
| `healthcheck.timer` | runs the check 30s after boot, then every 15 minutes |
| `healthcheck-weekly.timer` | weekly `dpkg --verify` at idle priority; catches up after downtime |
| `healthcheck-marker.service` | records clean/unclean shutdowns (power loss, crash) |
| `/etc/healthcheck/ignore-units` | failed units to leave off the dashboard (yours to edit) |
| `/var/lib/healthcheck/` | `alerts.log` (kernel errors and unclean shutdowns, kept across reboots), weekly result, boot marker |

The status file lives in `/run`, which is cleared at every boot, so it only describes
the current boot. Kernel errors are also copied to `alerts.log`, deduplicated, at most
20 new lines per run, so they still show up after the kernel log is gone.

The kernel log (`dmesg`) only covers the current boot, so after a power cut or crash,
anything logged between the last 15-minute check and the crash would be lost. Those
are often the messages that explain it. If `journalctl` is installed and the journal
is kept on disk, the first check after an unclean shutdown also reads the crashed
boot's kernel messages from the journal. It saves up to 20 matching errors that
weren't already saved, marked `journal:` in the history. Without a saved journal
(DietPi keeps it in RAM by default) or without `journalctl`, this step finds nothing
and changes nothing.

## Troubleshooting

- **"no results yet this boot"**: you logged in before the first check ran (about 30s
  after boot). Log in again in a minute.
- **The red line still shows 5 minutes after boot**, or **"status is stale"**: the
  timer isn't running. Check with
  `systemctl status healthcheck.timer healthcheck.service` and
  `journalctl -b -u healthcheck`.
- **Nothing prints at all**: your shell may not read `/etc/profile.d`. The installer
  warns about this. Add `. /etc/profile.d/healthcheck.sh` to `~/.bashrc`.

## Tests

CI (`.github/workflows/ci.yml`) runs on every push and pull request:

| Script | What it does |
|---|---|
| `tests/lint.sh` | `bash -n` and shellcheck on the installer and the scripts it embeds |
| `tests/install-test.sh` | real install, checks and uninstall on a systemd host (needs root; only run it somewhere disposable) |
| `tests/reboot-test.sh [image]` | installs into a systemd container, reboots and power-cuts it, and checks the dashboard comes back (needs Docker) |

```sh
tests/lint.sh
sudo tests/install-test.sh --no-apt
tests/reboot-test.sh debian:bookworm
```
