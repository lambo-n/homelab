# sanoid — ZFS snapshots on `.101`

**Everything here runs on the Proxmox host `192.168.50.101` as root.** The dev
VM reaches it over a dedicated SSH key (`id_ed25519_pve-hostconfig`) and
applies config with the Ansible layer in [`ansible/`](ansible/) — see
[`ansible/README.md`](ansible/README.md) for how to run it. Neither Flux nor
OpenTofu reconciles any of this; it's the third layer named in `GITOPS.md` →
"Scope: Flux manages the cluster, not the hypervisor". The original install
was by hand; see [`archive/SANOID-SETUP.md`](archive/SANOID-SETUP.md) for that
and [`archive/ANSIBLE-HOST-CONFIG-SETUP.md`](archive/ANSIBLE-HOST-CONFIG-SETUP.md)
for how it moved into git.

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
| Loss of `.101` | **monthly restic copy on Backblaze B2**: database and guide media only, up to a month old ([`runbooks/OFFSITE-RESTORE.md`](runbooks/OFFSITE-RESTORE.md)) |

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

`/etc/sanoid/sanoid.conf` on `.101` is rendered from
[`ansible/roles/sanoid/templates/sanoid.conf.j2`](ansible/roles/sanoid/templates/sanoid.conf.j2) —
that template is the source of truth; this table is a summary, not a copy to
edit separately. 24 hourly / 30 daily / 6 monthly:

| Dataset | Template | Recursive |
|---|---|---|
| `archive-pool/minio-data` | `archival` | no |
| `archive-pool/vm-104-disk-0` | `archival` | no |
| `archive-pool/ts-ssh-records` | `archival` | no |
| `sas-pool/data` | `archival` | yes |

Tabs, not spaces, for the indented lines in the rendered file — sanoid's INI
parser is strict about it and a space-indented key is silently ignored rather
than rejected. Adding a new dataset means an entry in the template, then
`ansible-playbook site.yml --check --diff` from `ansible/` to review the
change, then apply, then `ssh pve-hostconfig systemctl restart sanoid.timer`
(the role doesn't restart it for you), then a run of
[`runbooks/SANOID-VERIFY.md`](runbooks/SANOID-VERIFY.md) before trusting it.

## Leave a note where the next person will look

None of this is reconciled, so the check is a metric:

- `host_zfs_autosnap_newest_timestamp_seconds{dataset}` is the newest
  `autosnap_*` snapshot per dataset, from `host-metrics` on the host.
  `HostSnapshotStale` fires when one is more than 2 hours old
  ([`HOST-MONITORING.md`](HOST-MONITORING.md)). It only runs while the
  cluster is up.
- By hand: `zfs list -t snapshot -r archive-pool | wc -l`. A number that
  stops growing is the failure mode.

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
