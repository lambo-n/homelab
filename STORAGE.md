# Host storage — PGDATA zvol and worker disk growth

**Everything here runs on the Proxmox host `192.168.50.101` as root**, plus a
few steps inside `k3s-worker2`. The dev VM has no SSH key on `.101` and no route
to the pool, so none of it can be run from there. See GITOPS.md Phase 5.

Two independent jobs, and they are not the same job:

| Job | Why | Where the data goes |
|---|---|---|
| **§1–5 — PGDATA zvol** | CNPG needs a real device on redundant storage | `archive-pool` (1.68 TiB, 0.01% used) |
| **§6 — grow root disks** | container-image churn; 6.5 of 9.75 GiB already used | `local-lvm` (90.5 GiB free) |

Growing the root disk is **not** an alternative to §1–5. A bigger root disk is
the same absent boundary with more rope: `local-path` provisions a directory,
not a quota, so PGDATA would still share a filesystem with the OS and the image
store and could still take the node down by filling it.

---

## 1. Confirm the pool can hold VM disks

```bash
pvesm status
pvesm config archive-pool
```

`content` must include `images`. If it lists only `rootdir`:

```bash
pvesm set archive-pool --content images,rootdir
```

Then set the block size **before creating the disk** — this is the one setting
that cannot be changed afterwards:

```bash
pvesm set archive-pool --blocksize 8k
```

Postgres pages are 8K. Recent ZFS defaults a zvol to 16K, and the mismatch is
permanent write amplification on every page write for the life of the volume.

## 2. Create and attach the zvol

Find the VMID first — do not guess it:

```bash
qm list                    # confirm; VMIDs do not track the IP last octet here
```

```bash
VMID=104                   # k3s-worker2 -- confirmed via qm list
qm set "$VMID" -scsi1 archive-pool:64,backup=0,discard=on,ssd=1
```

- `64` = 64 GiB. Generous for a guide-metadata table plus a WAL burst while
  MinIO is unreachable, which on this cluster is a normal state rather than an
  incident.
- **Thick, not sparse** — PVE sets `refreservation` to the volume size by
  default, and that is what you want here. It guarantees Postgres can always
  write even if MinIO grows into the rest of the pool. 64 GiB out of 1.68 TiB
  is not worth economising.
- `backup=0` keeps it out of `vzdump`. The database is protected by barman
  (logical, PITR) and sanoid (block, fast rollback); a vzdump of a live PGDATA
  is a third crash-consistent copy nobody would restore from.
- `discard=on,ssd=1` lets guest TRIM return freed blocks to the pool.

Verify the block size actually took — if this says 16K, destroy the disk and
redo §1, because it cannot be changed in place:

```bash
zfs list -t volume -o name,volsize,volblocksize,refreservation -r archive-pool
```

Expect one volume named `archive-pool/vm-<VMID>-disk-0` (or `-disk-1` if the
VM already had one on this pool) with `VOLBLOCK` of `8K`.

> ⚠️ This is the moment the **"no VM disk is on ZFS"** invariant ends. From here
> on, `zpool destroy`/`export`/rebuild of `archive-pool` takes `k3s-worker2`'s
> database disk with it, and any pool work needs the VM **stopped** first.
> `POOL-DOWNSIZE.md` §1 and `HOMELAB.md` both still assert the old invariant.

## 3. Format it, inside `k3s-worker2`

```bash
lsblk                                  # the new device, almost certainly /dev/sdb
mkfs.ext4 -L pgdata /dev/sdb
blkid /dev/sdb                         # copy the UUID
```

Use the whole device — no partition table. One filesystem, one purpose, and
growing it later is `qm resize` + `resize2fs` with no partition to move.

## 4. Mount it where `local-path` already writes

`/var/lib/rancher/k3s/storage` is the configured `nodePathMap` for this cluster
(verified: single `DEFAULT_PATH_FOR_NON_LISTED_NODES` entry, provisioner
v0.0.36). Mounting the device *there* means **zero Kubernetes changes**.

Do not instead add a second StorageClass pointing at a new path: k3s re-applies
its packaged `local-storage.yaml` on every server restart, so an edited
`local-path-config` ConfigMap silently reverts until you start managing `.skip`
files.

```bash
systemctl stop k3s-agent

# The path must be EMPTY before it becomes a mountpoint -- anything already
# there would be shadowed by the mount and silently orphaned. There are zero
# local-path PVCs in this cluster today, so expect nothing.
mkdir -p /var/lib/rancher/k3s/storage
ls -A /var/lib/rancher/k3s/storage      # must print nothing

echo 'UUID=<uuid-from-blkid>  /var/lib/rancher/k3s/storage  ext4  defaults,noatime,nofail  0 2' >> /etc/fstab
mount -a
findmnt /var/lib/rancher/k3s/storage
```

## 5. Guarantee PGDATA cannot land anywhere else

The failure this prevents: the volume does not mount, `local-path` finds a
perfectly writable directory on the **root filesystem**, provisions into it, and
Postgres bootstraps happily onto the 9.75 GiB OS disk. Nothing errors. The first
symptom is `DiskPressure` evicting Postgres, PostgREST and the image store
together. Three independent layers, because one is not enough:

**a. Mount by UUID, never `/dev/sdb`.** Device names reorder when a disk is
added or the controller enumerates differently. That is already done in §4.

**b. Make the bare mountpoint unwritable.** With the volume unmounted, the
underlying directory becomes immutable, so a write attempt fails loudly instead
of landing on the root disk:

```bash
umount /var/lib/rancher/k3s/storage
chattr +i /var/lib/rancher/k3s/storage
mount -a
lsattr -d /var/lib/rancher/k3s/storage   # the ----i---------- is on the UNDERLYING dir
```

The flag applies to the directory beneath the mount, so it constrains nothing
while mounted and blocks everything while not. To change the mount later,
`umount` then `chattr -i`.

**c. Refuse to start k3s without it.**

```bash
mkdir -p /etc/systemd/system/k3s-agent.service.d
cat > /etc/systemd/system/k3s-agent.service.d/10-pgdata-mount.conf <<'EOF'
[Unit]
RequiresMountsFor=/var/lib/rancher/k3s/storage
EOF
systemctl daemon-reload
systemctl start k3s-agent
```

Note the deliberate combination: `nofail` in fstab **and** `RequiresMountsFor`
here. Without `nofail` a missing volume drops the box into an emergency shell
and you lose remote access to fix it. With it, the node boots, SSH works, and
k3s-agent simply refuses to start — the node goes `NotReady`, which is visible
in `kubectl get nodes` and recoverable without a console.

**Verify all three before wiring anything into Flux:**

```bash
# the mount is real and is the zvol
findmnt -no SOURCE,TARGET,FSTYPE /var/lib/rancher/k3s/storage
df -h /var/lib/rancher/k3s/storage        # expect ~63G, not ~9.75G

# and survives a reboot
reboot
# ...then, from the dev VM:
kubectl get nodes                          # k3s-worker2 Ready
```

After the CNPG Cluster is running, confirm where PGDATA actually is — this is
the check that closes the loop, and it is worth doing once:

```bash
# on the dev VM
kubectl get pv -o custom-columns='NAME:.metadata.name,PATH:.spec.local.path,NODE:.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]'
# on k3s-worker2
df -h /var/lib/rancher/k3s/storage         # usage should track the database
```

## 6. Grow the worker root filesystems

Separate job, for **container-image churn only**. No database data lands here.
6.5 of 9.75 GiB is already used, which is tight for image pulls regardless of
where PGDATA lives. ~24 GiB each across three nodes is ~45 GiB of the 90.5 GiB
free in `local-lvm`, so no thin-pool extension is needed.

> Watch the thin pool as you go — `local-lvm` is thin-provisioned and shared by
> all five guests. A **full thin pool breaks every guest at once**, which is
> strictly worse than one full root disk. `lvs` shows `Data%` on the pool.

### The VMIDs — they do NOT track the IP last octet

Confirmed 2026-09-03 with `qm list`. Earlier notes in this repo inferred the
mapping from `.104`–`.106` and got it wrong:

| VMID | Name | Boot disk | RAM |
|---|---|---|---|
| 101 | `dev` | 32 GB | 32 GB |
| 102 | `k3s-control` | 15 GB | 8 GB |
| **103** | **`k3s-worker1`** | 20 GB | 128 GB |
| **104** | **`k3s-worker2`** | 20 GB | 128 GB |

`k3s-worker2` is VMID **104** — that is the one §2 attaches the zvol to. The
`.102` vpn-gateway is an LXC and does not appear in `qm list`; use `pct list`.

### First: claim the space you already have

**Do not reach for `qm resize` yet.** The virtual disks are already 20 GB, but
every node reports a **9.75 GiB** root filesystem — including `k3s-control`,
whose disk is 15 GB. One uniform size across two different disk sizes means the
filesystem was never grown to fill the disk, so there is ~10 GiB per worker
sitting allocated and unclaimed. Growing the disk before claiming that would
consume thin-pool space to solve a problem you do not have.

**Confirmed layout 2026-09-03** — the stock Ubuntu Server installer default,
identical on both workers. It builds a 10 G logical volume and leaves the rest
of the volume group unallocated:

```
sda                       20G
├─sda1                     1M          (BIOS boot)
├─sda2                   1.8G  /boot
└─sda3                  18.2G          → VG ubuntu-vg
  └─ubuntu--vg-ubuntu--lv 10G  /       → 8.22 GiB FREE in the VG
```

So the fix is two commands per node, online, no reboot and no unmount (ext4
grows in place):

```bash
sudo lvextend -l +100%FREE /dev/ubuntu-vg/ubuntu-lv
sudo resize2fs /dev/ubuntu-vg/ubuntu-lv
df -h /                                      # expect ~18G, was 9.8G
```

Run it on **`k3s-worker1` (.105)** and **`k3s-worker2` (.106)**. `k3s-control`
(.104) has the same 10 G LV on a 15 GB disk and is worth doing too — its VG has
less spare, so take whatever `vgs` reports.

That takes each worker from 9.8 G (2.8 G free) to ~18 G (~11.4 G free) for
**zero** Proxmox change and zero thin-pool consumption — the space was already
inside the VM disk, just never claimed. With PGDATA on the zvol the root disk
only ever holds the OS, k3s, container images and pod logs, and 18 GiB is
comfortable for that.

> `sda3` is already 18.2 G of the 20 G disk, the remainder being `/boot` and the
> BIOS boot partition, so the VG cannot grow further without `qm resize`. It
> does not need to.

### Not needed — kept for the day the VG really is full

Measured 2026-09-03, it is not: `lvextend` above is sufficient and costs nothing
from the thin pool. Should that change:

```bash
qm resize 103 scsi0 +15G          # k3s-worker1
qm resize 104 scsi0 +15G          # k3s-worker2
lvs                               # watch Data% on the thin pool afterwards
```

`qm resize` grows the virtual disk online; the guest still has to be told —
`growpart` the partition, `pvresize` the PV, then `lvextend` + `resize2fs` as
above. `growpart` is in `cloud-guest-utils` on Debian/Ubuntu.

Confirm with `df -h /`, then from the dev VM:

```bash
kubectl get --raw "/api/v1/nodes/k3s-worker2/proxy/stats/summary" \
  | python3 -c 'import json,sys;f=json.load(sys.stdin)["node"]["fs"];print(round(f["capacityBytes"]/1024**3,2),"GiB total,",round(f["availableBytes"]/1024**3,2),"available")'
```

## 7. Add the zvol to sanoid

PGDATA is on ZFS again, which is the point — `SANOID.md` was written when it was
going to live on `local-path` and be unsnapshottable. Add the new volume beside
the two datasets:

```ini
[archive-pool/vm-<VMID>-disk-0]
	use_template = archival
	recursive = no
```

Substitute the real name from §2. Same caveat as everywhere else in this repo:
**a snapshot of a live Postgres is crash-consistent, not a backup.** It is a
fast rollback for the volume; barman is what protects the database. Neither
substitutes for the other, and `RESTORE.md` is still non-optional.

## 8. Then, and only then

`kubernetes/apps/sunfire/postgres-cnpg/` is deliberately absent from
`kubernetes/apps/sunfire/kustomization.yaml`. Add it once §5 verifies and
`scripts/minio-barman-account.sh` has created the backup bucket — those are the
two remaining blockers. Order does not matter between them; both must be done.
