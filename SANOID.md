# sanoid — ZFS snapshots on `.101`

**Everything here runs on the Proxmox host `192.168.50.101` as root**, not on
the dev VM: this VM has no SSH key on `.101` (`Permission denied (publickey)`)
and mounts no NFS, so it cannot run a single `zfs` command. Neither Flux nor
OpenTofu reconciles any of it — snapshots are host config, not Kubernetes
objects. Installed and configured 2026-09-02 through 2026-09-09; see
[`archive/SANOID-SETUP.md`](archive/SANOID-SETUP.md) for how.

---

## What this does and does not cover

ZFS redundancy already handles **drive** failure. It does nothing for the
failure this exists for: an accidental `DELETE`, a bad Flux prune, or logical
corruption. RAIDZ/mirror replicates a destructive write to every disk
instantly and the pool still scrubs clean.

| Risk | Covered by |
|---|---|
| Drive failure | the 3-way mirror + SMART |
| Accidental delete / bad prune of MinIO objects | **sanoid, below** |
| Postgres logical corruption, PITR | **CNPG + barman-cloud**, not this |
| Fast rollback of the PGDATA volume | **sanoid** — via the zvol |
| Loss of a k3s VM | neither — `vzdump`, or an OpenTofu rebuild |
| Loss of `.101` | nothing. Accepted residual risk |

Two traps worth stating plainly:

- **The k3s VMs are not covered.** Their disks are on `local-lvm` (LVM-thin) and
  the host has zero zvols for them. A green sanoid dashboard does not mean "the
  cluster is backed up".
- **A snapshot of a live Postgres is crash-consistent, not a backup.** Rolling
  one back is equivalent to yanking the power: Postgres will WAL-replay and
  usually come up, but that is not PITR and it will not survive logical
  corruption. That is barman's job, not sanoid's — see `GITOPS.md`
  → CloudNativePG.

## What's under sanoid today

PGDATA lives on a **zvol on this same pool** — block storage attached to
`k3s-worker2`, mounted where `local-path` provisions (`archive/STORAGE.md`).
Five datasets are covered:

| Dataset | Holds | Notes |
|---|---|---|
| `archive-pool/minio-data` | guide media **+ every Postgres backup and WAL segment** | matters most |
| `archive-pool/vm-104-disk-0` | **PGDATA** (the zvol) | a zvol does not appear in a plain `zfs list` — use `-t volume` or `-t all` |
| `archive-pool/ts-ssh-records` | Tailscale SSH session recordings | added 2026-09-09 |
| `sas-pool/data` | Personal storage / Samba share | added 2026-09-09, `recursive = yes` |

**`llm-pool` is deliberately not in `sanoid.conf`.** It holds VM 105's model
weights: multi-GB files that are re-downloadable, where every snapshot would
pin gigabytes for nothing (see [`GPU-VM.md`](GPU-VM.md)).

## Configuration

`/etc/sanoid/sanoid.conf` — 24 hourly / 30 daily / 6 monthly:

```ini
[archive-pool/minio-data]
	use_template = archival
	recursive = no

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
it and a space-indented key is silently ignored rather than rejected. Adding a
new dataset means an entry here, then `systemctl restart sanoid.timer`, then a
run of [`runbooks/SANOID-VERIFY.md`](runbooks/SANOID-VERIFY.md) before trusting it.

## Leave a note where the next person will look

Because none of this is reconciled, nothing will tell you when it stops
working, short of the habits below:

- `zfs list -t snapshot -r archive-pool | wc -l` in whatever you use to poke at
  the host — a number that stops growing is the failure mode.
- Snapshot age is scraped as goal G5 in [`HOST-MONITORING.md`](HOST-MONITORING.md),
  via node-exporter's textfile collector — the first metric worth having if this
  file's own checks ever lapse.

Pinning `sanoid` itself in a host-config layer (Ansible or equivalent) is
tracked in [`BACKLOG.md`](BACKLOG.md) — until that layer exists, this file *is*
the record, which is exactly why it is checked in rather than left in a
terminal.

## Related

- [`archive/SANOID-SETUP.md`](archive/SANOID-SETUP.md) — the original install
- [`runbooks/SANOID-VERIFY.md`](runbooks/SANOID-VERIFY.md) — the repeatable
  rollback drill, with its run log
- [`archive/STORAGE.md`](archive/STORAGE.md) — how the PGDATA zvol was built
- [`SAS-STORAGE.md`](SAS-STORAGE.md) — `sas-pool`, and the import hazard that
  makes "a running timer" insufficient proof
