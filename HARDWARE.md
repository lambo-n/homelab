# Hardware — the physical storage inventory

Every other document here describes storage **logically**: pools, datasets,
PVs, quotas, what data lives where. None of them names a device. `README.md`
says `archive-pool` is a "ZFS 3-way mirror, 1.68 TiB usable" without recording
what the three members are; `STORAGE.md` sets `blocksize` on a pool whose disks
it never identifies.

That was survivable while the answer to every storage question was "put it on
`archive-pool`". It stops being survivable the moment a question needs a
**device**: adding a pool, replacing a failed member, passing an HBA through to
a guest, or deciding whether there is physical room for any of it.

This file is the one place that records the metal. It is currently **mostly
unfilled**, and the unfilled rows are the point — an empty cell here is a known
gap, not an oversight.

> ⚠️ **Two access paths, and they answer different questions.** `192.168.50.101`
> accepts no SSH key from the dev VM or from a laptop (`tofu/README.md:200`), and
> the dev VM has no route to the *pool* itself (`STORAGE.md:4-5`). But the
> Proxmox **API on `:8006`** is reachable from the dev VM and — via the approved
> `192.168.50.0/24` subnet route — from any tailnet device running
> `tailscale set --accept-routes` (see [`GITOPS.md`](GITOPS.md#tailscale-host)).
> So most of this file can be filled in from wherever you are; only the
> controller and `by-id` questions need a console on the host. Every figure below
> carries the date and the command that produced it, because nothing inside the
> cluster can re-derive one later.

---

## Status

| | |
|---|---|
| Created | 2026-09-09 |
| Physical devices recorded | **none yet** |
| Blocking | new-pool sizing, TrueNAS/HBA passthrough feasibility, any disk replacement |

---

## What is known today

Aggregated from the existing documents, with provenance. **None of it names a
device**, which is exactly the problem this file exists to fix.

### The host

| | | Source |
|---|---|---|
| Proxmox VE | `192.168.50.101` (`pve`) | `README.md:83` |
| Also runs | NFS server exporting `/archive-pool` | `README.md:84` |
| Chassis / board / bay count | **not recorded** | — |
| Storage controller(s) | **not recorded** | — |

### `local-lvm` — VM disks

| | | Source |
|---|---|---|
| Type | LVM-thin | `README.md:85` |
| Backing | "an NVMe RAID1 pair" | `README.md:85` |
| Capacity | 130.2 GiB, ~90.5 GiB free | `pvesm status`, 2026-09-03 |
| RAID implementation | **not recorded** — mdraid, ZFS mirror and hardware RAID are all consistent with the phrase used | — |
| Device models / serials / `by-id` | **not recorded** | — |

Holds every guest root disk: five guests, 20 + 15 + 32 + 20 + 8 GiB.

### `archive-pool` — bulk storage

| | | Source |
|---|---|---|
| Type | ZFS, **3-way mirror**, two-disk fault tolerance | `README.md:86` |
| Capacity | 1.68 TiB usable, 0.01% used at cutover | `README.md:86`, `STORAGE.md:25` |
| PVE `content` | `images,rootdir` | `STORAGE.md:48-55` |
| Mountpoint | `/archive-pool` | `STORAGE.md:51` |
| Provisioning | thick — no `sparse` line, deliberate | `STORAGE.md:65-78` |
| `blocksize` | `8k`, set 2026-09-03, **cannot be changed after volume creation** | `STORAGE.md:80-88` |
| Member devices, per-disk capacity, models, serials | **not recorded** | — |
| Whether the three members are matched | **not recorded** | — |

A 3-way mirror of 1.68 TiB usable implies three ~2 TB-class devices, but that
is an inference from a rounded figure, not a reading. Do not plan against it.

Under sanoid: `minio-data`, `postgres-data`, `vm-104-disk-0` — 24 hourly / 30
daily / 6 monthly (`SANOID.md`).

> ⚠️ `archive-pool` holds `k3s-worker2`'s PGDATA zvol. Any pool work needs that
> VM stopped first (`README.md:119-122`, `STORAGE.md:125-128`).

### `/mnt/sas1` — the third location

| | | Source |
|---|---|---|
| Known contents | `tailscale-gateway-logs`, bind-mounted into CTID 100 | `STORAGE.md:416-427` |
| Purpose | Tailscale SSH session recordings | `STORAGE.md:424` |
| Underlying device / filesystem / pool | **not recorded** | — |
| Redundancy | **not recorded** | — |
| Snapshots | none — `SANOID.md` covers `archive-pool` only | `STORAGE.md:434-435` |

The name implies SAS, which would mean a controller and disks that appear in no
other document. It predates the GitOps migration and was set up by hand. **This
is the single largest unknown in the inventory** — it may be the free capacity a
new pool would use, or it may be a disk that is already full.

---

## What is not recorded anywhere

The gap, stated as questions with the reason each one matters:

| Unknown | Why it blocks something |
|---|---|
| Device models, capacities, serials, `/dev/disk/by-id` paths | A pool must be created against `by-id`, never `sdX` — names reorder when a disk is added (`STORAGE.md:189-190`) |
| Total bays and how many are **free** | Determines whether a new pool is possible at all, or whether it means replacing something |
| Storage controller(s) — onboard SATA, HBA, RAID card | Decides whether PCIe passthrough to a TrueNAS guest is even available, and at what granularity |
| Whether disks are behind a RAID card in IT or IR mode | A RAID card in IR mode makes ZFS-on-passthrough a bad idea regardless of everything else |
| What the NVMe "RAID1 pair" actually is | An mdraid pair and a ZFS mirror fail, resilver and monitor differently |
| Per-device SMART health, power-on hours, wear | Three-way mirrors bought together fail together; age is the input to "replace or expand" |
| What `/mnt/sas1` sits on | See above — possibly the answer to "where does the new pool go" |

---

## How to fill this in

Two routes. **Start with the first** — it needs no privilege change and no
console.

### Over the API (read-only) — from the dev VM, or from any tailnet device

`PVEAuditor` covers all of these; no `Sys.Modify`, no token widening. Set
`PROXMOX_VE_API_TOKEN` as in `tofu/README.md:293-307` first.

From a machine that is not on the LAN, confirm the subnet route is being accepted
before blaming the token — a refused connection here is a routing problem, not an
auth one:

```bash
tailscale status --json | jq '.Peer[] | select(.HostName=="tailscale-gateway") | .PrimaryRoutes'
#   -> ["192.168.50.0/24"]   ... and locally:  sudo tailscale set --accept-routes
```

```bash
# Every physical disk: path, size, model, serial, and what is using it
curl -sk -H "Authorization: PVEAPIToken=$PROXMOX_VE_API_TOKEN" \
  'https://192.168.50.101:8006/api2/json/nodes/pve/disks/list' \
  | jq -r '.data[] | [.devpath, .size, .model, .serial, (.used // "FREE"), (.health // "?")] | @tsv'

# ZFS pools as PVE sees them, then the member topology of one
curl -sk -H "Authorization: PVEAPIToken=$PROXMOX_VE_API_TOKEN" \
  'https://192.168.50.101:8006/api2/json/nodes/pve/disks/zfs' | jq .data
curl -sk -H "Authorization: PVEAPIToken=$PROXMOX_VE_API_TOKEN" \
  'https://192.168.50.101:8006/api2/json/nodes/pve/disks/zfs/archive-pool' | jq .data

# Configured storages, including whatever backs /mnt/sas1
curl -sk -H "Authorization: PVEAPIToken=$PROXMOX_VE_API_TOKEN" \
  'https://192.168.50.101:8006/api2/json/storage' | jq -r '.data[] | [.storage, .type, (.path // "-")] | @tsv'
```

### On the host console, as root

For what the API does not expose — controller identity, `by-id` paths, and what
`/mnt/sas1` really is:

```bash
lsblk -o NAME,SIZE,TYPE,MODEL,SERIAL,MOUNTPOINT
ls -l /dev/disk/by-id/ | grep -v part

zpool status -L -v archive-pool     # -L resolves to real device names
zpool list -v

lspci -nn | grep -iE 'sas|raid|sata|nvme'   # the controller question
findmnt /mnt/sas1                            # the /mnt/sas1 question
cat /proc/mdstat                             # is the NVMe pair mdraid?

smartctl -a /dev/<dev> | grep -iE 'model|serial|power_on|wear|health'
```

### Then

Record the results in the tables above — **with the date and the command**, in
the style `README.md:88-89` already uses. A figure here without provenance is
worse than an empty cell, because the empty cell is honest about being unknown.

---

## Related

- `STORAGE.md` — how the PGDATA zvol was created and guarded; §1 is the PVE-side
  pool configuration this file is the physical counterpart to
- `SANOID.md` — which datasets are snapshotted
- `README.md` — logical placement of every piece of data
- `tofu/README.md:196-322` — the API token, its privileges, and why it is
  read-only
