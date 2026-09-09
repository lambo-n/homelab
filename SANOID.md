# sanoid — ZFS snapshots on `.101`

Phase 5's host-level half. **Everything here runs on the Proxmox host
`192.168.50.101` as root**, not on the dev VM: this VM has no SSH key on `.101`
(`Permission denied (publickey)`) and mounts no NFS, so it cannot run a single
`zfs` command. Neither Flux nor OpenTofu reconciles any of it — snapshots are
host config, not Kubernetes objects. See GITOPS.md Phase 5.

---

## What this does and does not cover

ZFS redundancy already handles **drive** failure. It does nothing for the
failure this file exists for: an accidental `DELETE`, a bad Flux prune, or
logical corruption. RAIDZ/mirror replicates a destructive write to every disk
instantly and the pool still scrubs clean.

| Risk | Covered by |
|---|---|
| Drive failure | the 3-way mirror + SMART |
| Accidental delete / bad prune of MinIO objects | **sanoid, below** |
| Postgres logical corruption, PITR | **CNPG + barman-cloud**, not this |
| Fast rollback of the PGDATA volume | **sanoid** — via the zvol, as of 2026-09-03 |
| Loss of a k3s VM | neither — `vzdump`, or the Phase 6 OpenTofu rebuild |
| Loss of `.101` | nothing. Accepted residual risk |

Two traps worth stating plainly:

- **The k3s VMs are not covered.** Their disks are on `local-lvm` (LVM-thin) and
  the host has zero zvols. A green sanoid dashboard does not mean "the cluster
  is backed up".
- **A snapshot of a live Postgres is crash-consistent, not a backup.** Rolling
  one back is equivalent to yanking the power: Postgres will WAL-replay and
  usually come up, but that is not PITR and it will not survive logical
  corruption. That is barman's job, not sanoid's.

### What changed with the CNPG migration

Phase 5 moves PGDATA off **NFS** onto a **zvol on this same pool** — block
storage attached to `k3s-worker2`, mounted where `local-path` provisions. So
there are four things here worth snapshotting:

| Dataset | Holds | State |
|---|---|---|
| `archive-pool/minio-data` | guide media **+ every Postgres backup and WAL segment** | live, matters most |
| `archive-pool/vm-<VMID>-disk-0` | **PGDATA** (the zvol; name from `STORAGE.md` §2) | live, new |
| `archive-pool/ts-ssh-records` | Tailscale SSH session recordings | live, added 2026-09-09 (`SAS-RECLAIM.md`) |
| `archive-pool/postgres-data` | the old NFS data directory | **legacy** — frozen at cutover |

Keep snapshotting `postgres-data` while the old Deployment is still the rollback
path; it costs nothing on a copy-on-write pool and stops changing the moment the
cutover lands.

> An earlier revision of this file said PGDATA was moving to `local-path` and
> would therefore be **outside** sanoid's reach entirely — GITOPS.md accepted
> "losing `k3s-worker2` means restore-from-backup, not a snapshot rollback" as a
> deliberate cost. That decision was reversed on 2026-09-03 in favour of the
> zvol, and the cost with it. Snapshot coverage of the database is back.

`STORAGE.md` §7 has the `sanoid.conf` stanza for the zvol. Add it beside the two
datasets in §3 below — the volume will not appear in `zfs list` without `-t
volume` (or `-t all`), which is the usual reason it gets forgotten.

---

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
this file's names over the machine's:

```bash
zpool status archive-pool
zfs list -o name,used,avail,mountpoint -r archive-pool
```

Expect `archive-pool/minio-data`, `archive-pool/postgres-data`, and `archive-pool/ts-ssh-records`. If they
differ, fix the config below rather than the machine.

## 3. Configure

`/etc/sanoid/sanoid.conf` — 24 hourly / 30 daily / 6 monthly, as planned in
GITOPS.md:

```ini
[archive-pool/minio-data]
	use_template = archival
	recursive = no

[archive-pool/postgres-data]
	use_template = archival
	recursive = no

# The PGDATA zvol (STORAGE.md). A zvol does not appear in a plain `zfs list` --
# use `zfs list -t volume` -- which is the usual reason this stanza gets left out.
[archive-pool/vm-104-disk-0]
	use_template = archival
	recursive = no

[archive-pool/ts-ssh-records]
	use_template = archival
	recursive = no

[sas-pool/data]
	use_template = archival
	recursive = yes

[template_archival]
	frequently = 0
	hourly = 24
	daily = 30
	monthly = 6
	yearly = 0
	autosnap = yes
	autoprune = yes
```

Tabs, not spaces, for the indented lines — sanoid's INI parser is strict about
it and a space-indented key is silently ignored rather than rejected.

Dry-run before letting the timer near it:

```bash
sanoid --configdir=/etc/sanoid --cron --readonly --verbose
```

The flag is `--readonly`, **not** `--dry-run` — sanoid rejects the latter with a
bare usage dump, which reads like a config error and is not one.

Confirm the indentation actually became tabs before trusting any of it. A
space-indented key is silently ignored, so a config that *looks* right can
produce no snapshots at all:

```bash
grep -Pc '^\t' /etc/sanoid/sanoid.conf     # expect 17
```

If that prints 0, the substitution did not take — fall back to
`perl -i -pe 's/^ +/\t/' /etc/sanoid/sanoid.conf` and re-check.

Then enable:

```bash
systemctl enable --now sanoid.timer
systemctl status sanoid.timer
zfs list -t snapshot -r archive-pool     # after the next quarter hour
```

`sanoid.timer` fires every 15 minutes and decides internally what is due; there
is no separate prune timer to enable.

## 4. Verify a rollback actually works — before relying on it

GITOPS.md is emphatic here and it is the step people skip. **Do not test with
`zfs rollback` on live data.** Clone the snapshot and inspect the clone; that
proves the snapshot is readable and complete without risking the original.

**For `minio-data`** (a filesystem dataset — the clone mounts itself):

```bash
SNAP=$(zfs list -t snapshot -o name -s creation -H -r archive-pool/minio-data | tail -1)
echo "$SNAP"
zfs clone "$SNAP" archive-pool/restore-test
ls -la /archive-pool/restore-test
# expect the MinIO layout: .minio.sys/ plus the bucket directories
du -sh /archive-pool/restore-test
zfs destroy archive-pool/restore-test
```

**For the PGDATA zvol, the same procedure does not apply.** A zvol clone is a
*block device*, not a directory — there is nothing to `ls`. It appears under
`/dev/zvol/` and carries the ext4 filesystem from `STORAGE.md` §3:

```bash
SNAP=$(zfs list -t snapshot -o name -s creation -H -r archive-pool/vm-104-disk-0 | tail -1)
echo "$SNAP"
zfs clone "$SNAP" archive-pool/pgdata-restore-test
udevadm settle
blkid /dev/zvol/archive-pool/pgdata-restore-test
# expect: TYPE="ext4" LABEL="pgdata"
zfs destroy archive-pool/pgdata-restore-test
```

`blkid` recognising the filesystem is the right stopping point. **Do not mount
it to look inside.** The snapshot is crash-consistent — taken while Postgres was
running — so the ext4 journal is dirty and mounting would replay it, and mounting
a live database's filesystem image on the hypervisor is a good way to confuse
yourself about which copy is real. If you ever genuinely need the contents, mount
`-o ro,norecovery` and treat what you see as a crash image.

Record the date you did this. An untested snapshot is a belief, not a backup.

### Verified 2026-09-04 — both clones passed

Snapshots present for **all three** datasets (hourly, daily and monthly), the
zvol included:

```
archive-pool/minio-data@autosnap_2026-09-04_03:00:13_hourly       440K   97.1M
archive-pool/postgres-data@autosnap_2026-09-04_03:00:13_hourly      0B   12.7M
archive-pool/vm-104-disk-0@autosnap_2026-09-04_03:00:13_hourly      0B   74.8M
```

**`minio-data` clone** mounted and showed the real layout — `.minio.sys/`,
`sunfire-guide-media/` and `sunfire-postgres-backups/`, 97 M total. Worth noting
what that third directory means: the Postgres base backups and archived WAL are
themselves inside the ZFS snapshot. Barman protects the database, sanoid protects
the volume, and here the volume contains barman's output — so an accidental
deletion inside the backup bucket is recoverable too.

**Zvol clone** returned:

```
LABEL="pgdata" UUID="47470f9d-6503-4538-bd6f-4acc2e818366" TYPE="ext4"
```

That UUID is byte-identical to the one `blkid` reported when the filesystem was
created in `STORAGE.md` §3. The chain is closed end to end: the filesystem made
on the zvol, mounted on `k3s-worker2`, holding PGDATA, is the same filesystem
that comes back out of a snapshot clone on the hypervisor.

Both clones were destroyed afterwards. Note also that the earlier snapshot had
grown to `440K USED` on `minio-data` — copy-on-write is doing what it should,
retaining only the delta.

### Verified 2026-09-09 — `ts-ssh-records` added

Following `SAS-RECLAIM.md` §6, `archive-pool/ts-ssh-records` was placed under
the `archival` template. First execution confirmed initial snapshots taken
(`monthly`, `daily`, `hourly`, all at 108K REFER) and `sanoid.timer` active.

## 5. Leave a note where the next person will look

Because none of this is reconciled, nothing will tell you when it stops
working. Two cheap habits:

- `zfs list -t snapshot -r archive-pool | wc -l` in whatever you use to poke at
  the host — a number that stops growing is the failure mode.
- Phase 7 (`kube-prometheus-stack`) has no visibility here at all. If host
  monitoring ever lands, snapshot age is the first metric worth having.

## 6. When the Ansible layer exists

GITOPS.md Phase 5 has an open item to pin sanoid in host config. Until that
layer exists this file *is* the record, which is exactly why it is checked in
rather than left in a terminal.
