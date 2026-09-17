# sanoid — initial install (completed)

> 📦 **Archived 2026-09-16 — completed one-time setup.** Installed and
> configured on `.101` on 2026-09-02 through 2026-09-09, across the phases
> below. The resulting configuration is current-state reference in
> [`../SANOID.md`](../SANOID.md); the repeatable rollback-verification drill is
> [`../runbooks/SANOID-VERIFY.md`](../runbooks/SANOID-VERIFY.md).

## 1. Install

Proxmox is Debian-based and sanoid is packaged:

```bash
apt update && apt install -y sanoid
systemctl list-unit-files | grep -E 'sanoid|syncoid'
```

If the package is absent on this release, install from source into
`/usr/local/sbin` per the upstream README rather than pulling a random PPA.

## 2. Confirm the dataset names before writing any config

The pool was rebuilt as a 3-way mirror (`POOL-DOWNSIZE.md`), so do not trust
a document's names over the machine's:

```bash
zpool status archive-pool
zfs list -o name,used,avail,mountpoint -r archive-pool
```

Expect `archive-pool/minio-data`, `archive-pool/postgres-data`, and `archive-pool/ts-ssh-records`.

## Enabling the timer

```bash
sanoid --configdir=/etc/sanoid --cron --readonly --verbose   # dry run; --readonly, NOT --dry-run
grep -Pc '^\t' /etc/sanoid/sanoid.conf     # expect one line per indented key; a space-indented
                                            # key is silently ignored by sanoid's strict INI parser
systemctl enable --now sanoid.timer
systemctl status sanoid.timer
zfs list -t snapshot -r archive-pool       # after the next quarter hour
```

`sanoid.timer` fires every 15 minutes and decides internally what is due;
there is no separate prune timer.

> ⚠️ **A running timer is not evidence that anything is being snapshotted.**
> From 2026-09-15 to 2026-09-16 `sas-pool` was unimported while this timer fired
> every 15 minutes against `[sas-pool/data]`, a dataset that did not exist, and
> `systemctl status sanoid.timer` read `active (waiting)` the whole time
> ([`../SAS-STORAGE.md`](../SAS-STORAGE.md)). Verify the **snapshots**, per pool,
> not the timer.
>
> ⚠️ **sanoid names snapshots in UTC; `zpool history` logs local time (PDT).** A
> 17:00 history line creates `autosnap_2026-09-16_00:00_hourly`. Do not read
> snapshot names against journal timestamps to reconstruct an outage window —
> the 7-hour skew makes it look like pools were exported when they were not.

## Datasets added over time

- **2026-09-04:** `archive-pool/minio-data`, `archive-pool/postgres-data`, and
  the PGDATA zvol `archive-pool/vm-104-disk-0`, all under `template_archival`.
  First rollback drill passed the same day.
- **2026-09-09:** `archive-pool/ts-ssh-records` added, following
  [`SAS-RECLAIM.md`](SAS-RECLAIM.md) §6.
- **2026-09-09:** `sas-pool/data` added, following
  [`../SAS-STORAGE.md`](../SAS-STORAGE.md), with `recursive = yes`.
