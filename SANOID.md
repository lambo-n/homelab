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
after the cutover there are three things here worth snapshotting, not two:

| Dataset | Holds | State |
|---|---|---|
| `archive-pool/minio-data` | guide media **+ every Postgres backup and WAL segment** | live, matters most |
| `archive-pool/vm-<VMID>-disk-0` | **PGDATA** (the zvol; name from `STORAGE.md` §2) | live, new |
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

Expect `archive-pool/minio-data` and `archive-pool/postgres-data`. If they
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
sanoid --configdir=/etc/sanoid --cron --dry-run --verbose
```

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

```bash
SNAP=$(zfs list -t snapshot -o name -s creation -H -r archive-pool/minio-data | tail -1)
echo "$SNAP"
zfs clone "$SNAP" archive-pool/restore-test
ls -la /archive-pool/restore-test
# expect the MinIO layout: .minio.sys/ plus the bucket directories
du -sh /archive-pool/restore-test
zfs destroy archive-pool/restore-test
```

Record the date you did this. An untested snapshot is a belief, not a backup.

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
