# Hardware — the physical storage inventory

Every other document here describes storage **logically**: pools, datasets, PVs,
quotas, what data lives where. None of them names a device. `README.md` says
`archive-pool` is a "ZFS 3-way mirror, 1.68 TiB usable" without recording what
the three members are; `STORAGE.md` sets `blocksize` on a pool whose disks it
never identifies.

That was survivable while the answer to every storage question was "put it on
`archive-pool`". It stops being survivable the moment a question needs a
**device**: adding a pool, replacing a failed member, passing a controller
through to a guest, or deciding whether there is physical room for any of it.

This file is the one place that records the metal.

> ✅ **Filled in 2026-09-09** from a root console on `192.168.50.101`, while
> scoping a TrueNAS guest. Source commands: `pvesm status`, `zpool status -v`,
> `lsblk -o NAME,SIZE,MODEL,SERIAL,TYPE,MOUNTPOINT`, `ls -l /dev/disk/by-id/`,
> `lspci -nnk`, `findmnt /mnt/sas1`, `free -g`. Every figure below carries the
> date and the command that produced it, because nothing inside the cluster can
> re-derive one later.

> ⚠️ **Two access paths, and they answer different questions.** `192.168.50.101`
> accepts no SSH key from the dev VM or from a laptop (`tofu/README.md:200`), and
> the dev VM has no route to the *pool* itself (`STORAGE.md:4-5`). But the
> Proxmox **API on `:8006`** is reachable from the dev VM and — via the approved
> `192.168.50.0/24` subnet route — from any tailnet device running
> `tailscale set --accept-routes` (see [`GITOPS.md`](GITOPS.md#tailscale-host)).
> Capacities and disk lists can be re-read from either. **Controller topology,
> `by-id` paths and SMART cannot** — those need the console.

---

## Status

| | |
|---|---|
| Created | 2026-09-09 |
| Filled in | 2026-09-09, host console |
| Physical devices recorded | **9 disks + 1 zvol, all identified** |
| Free bays / unused devices | **2 × 1.92 TB SATA SSD, unallocated** (`sde`, `sdf`) |
| Still unknown | SMART on the 6 SATA disks; BOSS mirror health; empty bay count |
| ⚠️ Live hazard | `/mnt/sas{1,2,3}` are in `/etc/fstab` **without `nofail`** — see the SAS section |

---

## The host

| | | Source |
|---|---|---|
| Proxmox VE | `192.168.50.101` (`pve`) | `README.md:83` |
| Also runs | NFS server exporting `/archive-pool` | `README.md:84` |
| Platform | Dell, Ice Lake generation — `fe:00.x Intel Ice Lake Ubox Registers`, Dell subsystem IDs `1028:*` on every controller | `lspci -nnk`, 2026-09-09 |
| RAM | **503 GiB total**, 35 GiB used, 467 GiB free | `free -g`, 2026-09-09 |
| Swap | 8 GiB, on `pve-swap` (LVM, on the boot device) | `lsblk`, 2026-09-09 |

RAM committed to guests today is 1 + 32 + 8 + 128 + 128 = **297 GiB of 503**,
leaving ~206 GiB unallocated. Compute is not the scarce resource here and never
has been (`README.md:111-113`); **disk is**, and this file is why.

---

## Storage controllers — the topology that decides passthrough

Four controllers, and **which disks hang off which one is the single most useful
fact in this file**. It determines what can be handed to a guest without taking
something else with it.

| Address | Controller | Driver | Disks behind it |
|---|---|---|---|
| `05:00.0` | Marvell 88SE9230, subsystem **Dell BOSS-S2 Adapter** `[1028:2010]` | `ahci` | `sda` — the boot device |
| `00:11.5` | Intel C620 sSATA [AHCI] `[8086:a1d2]` | `ahci` | some of `sdb`–`sdf` |
| `00:17.0` | Intel C620 SATA [AHCI] `[8086:a182]` | `ahci` | the rest of `sdb`–`sdf` |
| `c3:00.0` | Broadcom/LSI MegaRAID 12GSAS SAS38xx, subsystem **Dell PERC H355 Front** `[1028:2173]` | `megaraid_sas` | `sdg`, `sdh`, `sdi` — **and nothing else** |

Three consequences, all of them load-bearing:

- ✅ **The PERC H355 carries only the three SAS SSDs.** `archive-pool` and the
  boot device are on entirely different controllers. PCIe passthrough of
  `c3:00.0` to a guest therefore takes `/mnt/sas1`, `/mnt/sas2` and `/mnt/sas3`
  and **nothing the cluster depends on**. This was assumed to be the opposite
  before it was measured.
- ❌ **Neither Intel SATA controller can be passed through.** `archive-pool`'s
  three members and the two free SSDs share them. Which of `sdb`–`sdf` sits on
  `00:11.5` versus `00:17.0` was not recorded and does not matter: passing
  either one risks taking a live pool member. Free SATA disks go to a guest
  **per device by `by-id`**, never by controller.
- ⚠️ **`/mnt/sas1` is bind-mounted into CTID 100** (`tofu/proxmox-container.tf`,
  `STORAGE.md` appendix). Passing the PERC through removes that path from the
  host and breaks the Tailscale SSH session recordings. See
  [Before anything claims the SAS disks](#before-anything-claims-the-sas-disks).

---

## Every block device

As read 2026-09-09. **`by-id` is the only name that should ever appear in a
command** — `sdX` reorders when a disk is added or the controller enumerates
differently (`STORAGE.md:189-190`).

| Dev | `/dev/disk/by-id/…` | Model | Serial | Size | Bus | Role |
|---|---|---|---|---|---|---|
| `sda` | `ata-DELLBOSS_VD_aa06e20941c90010` | `DELLBOSS VD` | `aa06e20941c90010` | 223.5 GiB | SATA (BOSS) | boot — `/boot/efi`, `pve-root`, `pve-swap`, `local-lvm` |
| `sdb` | `ata-HFS1T9G3H2X069N_ADB5N4365I150584Z` | `HFS1T9G3H2X069N` | `ADB5N4365I150584Z` | 1.75 TiB | SATA | `archive-pool` `mirror-0` |
| `sdc` | `ata-MTFDDAK1T9TDT_222939CA58D4` | `MTFDDAK1T9TDT` | `222939CA58D4` | 1.75 TiB | SATA | `archive-pool` `mirror-0` |
| `sdd` | `ata-HFS1T9G3H2X069N_ADB5N4365I1505855` | `HFS1T9G3H2X069N` | `ADB5N4365I1505855` | 1.75 TiB | SATA | `archive-pool` `mirror-0` |
| `sde` | `ata-HFS1T9G3H2X069N_ADB5N4365I150584Y` | `HFS1T9G3H2X069N` | `ADB5N4365I150584Y` | 1.75 TiB | SATA | **FREE** — stale ZFS labels |
| `sdf` | `ata-HFS1T9G3H2X069N_ADB5N4365I1505850` | `HFS1T9G3H2X069N` | `ADB5N4365I1505850` | 1.75 TiB | SATA | **FREE** — stale ZFS labels |
| `sdg` | `scsi-35002538a48872950` / `wwn-0x5002538a48872950` | `MZILS3T8HMLH0D3` | `S3D9NX0K803377` | 3.49 TiB | SAS | ext4 → `/mnt/sas2` |
| `sdh` | `scsi-35002538a48872700` / `wwn-0x5002538a48872700` | `MZILS3T8HMLH0D3` | `S3D9NX0K803346` | 3.49 TiB | SAS | ext4 → `/mnt/sas3` |
| `sdi` | `scsi-35002538a48872be0` / `wwn-0x5002538a48872be0` | `MZILS3T8HMLH0D3` | `S3D9NX0K803418` | 3.49 TiB | SAS | ext4 → `/mnt/sas1` |
| `zd0` | — | — | — | 64 GiB | — | `archive-pool/vm-104-disk-0`, the PGDATA zvol |

Sizes are as `lsblk` reports them (TiB). The marketing capacities are 1.92 TB
for the SATA SSDs and 3.84 TB for the SAS SSDs.

**Model families, decoded from the model string** — confirm with `smartctl -a`
before ordering a replacement, these are inferences from the part number:

| Model string | Almost certainly | Notes |
|---|---|---|
| `HFS1T9G3H2X069N` | SK hynix data-centre SATA SSD, 1.92 TB | `HFS` = SK hynix SSD, `1T9` = 1.92 TB |
| `MTFDDAK1T9TDT` | Micron 5400-series SATA SSD, 1.92 TB | `MTFDDAK` = Micron 2.5" SATA |
| `MZILS3T8HMLH0D3` | Samsung PM1633a SAS 12 Gb/s SSD, 3.84 TB | `MZILS` = Samsung SAS SSD, `3T8` = 3.84 TB |
| `DELLBOSS VD` | Dell BOSS-S2 — 2 × M.2 SATA in **hardware** RAID1 | The mirror is the Marvell card's, not the OS's |

---

## `sda` / `local-lvm` — the boot device, and a correction

| | | Source |
|---|---|---|
| Device | `DELLBOSS VD`, 223.5 GiB, single virtual disk | `lsblk`, 2026-09-09 |
| Layout | `sda1` 1007K (BIOS boot) · `sda2` 1 GiB `/boot/efi` · `sda3` 222.5 GiB LVM PV | `lsblk`, 2026-09-09 |
| LVM | `pve-swap` 8 GiB · `pve-root` 65.6 GiB · `pve-data` thin pool 130.2 GiB | `lsblk`, 2026-09-09 |
| `local-lvm` | 130.22 GiB total, **48.10 GiB used (36.94%)**, 82.12 GiB free | `pvesm status`, 2026-09-09 |
| `local` (dir, on `pve-root`) | 64.04 GiB total, 7.51 GiB used (11.73%) | `pvesm status`, 2026-09-09 |

Holds every guest root disk: `vm-100` 8 GiB, `vm-101` 32 GiB, `vm-102` 15 GiB,
`vm-103` 20 GiB, `vm-104` 20 GiB.

> ⚠️ **`README.md:85` is wrong, twice.** It calls this "LVM-thin on an NVMe
> RAID1 pair". It is neither NVMe nor an OS-level RAID: it is a **Dell BOSS-S2**
> card presenting two M.2 **SATA** SSDs as one hardware-mirrored virtual disk.
> `HARDWARE.md`'s own earlier row ("mdraid, ZFS mirror and hardware RAID are all
> consistent with the phrase used") resolves to **hardware RAID**.
>
> This matters operationally, not pedantically: **the OS cannot see the member
> disks.** There is no `/proc/mdstat` entry, no `zpool status`, and `smartctl`
> on `/dev/sda` reads the *virtual* disk. Health lives in iDRAC or the BOSS CLI,
> and **nothing checks either today**.
>
> Worth being precise about why, because it is a wider gap than this one disk:
> the observability stack runs *inside* the cluster and node-exporter is a
> DaemonSet on the three k3s **nodes** (`kube-prometheus-stack/ks.yaml`). The
> Proxmox host is not a scrape target at all, so no host disk — this mirror,
> `archive-pool`, or the SAS SSDs — is monitored by anything in this repo.

> ⚠️ **Thin-pool free space is falling.** 90.5 GiB free on 2026-09-03, **82.12
> GiB on 2026-09-09** — the `lvextend`/`resize2fs` work in `STORAGE.md` §6 wrote
> real blocks into the thin pool, as thin provisioning means it would. `local-lvm`
> is shared by all five guests and **a full thin pool breaks every guest at
> once** (`STORAGE.md:306-308`). Watch `Data%` in `lvs`.

---

## `archive-pool` — bulk storage, and the only redundant pool

```
archive-pool                               ONLINE
  mirror-0                                 ONLINE
    ata-HFS1T9G3H2X069N_ADB5N4365I150584Z  ONLINE     sdb
    ata-HFS1T9G3H2X069N_ADB5N4365I1505855  ONLINE     sdd
    ata-MTFDDAK1T9TDT_222939CA58D4         ONLINE     sdc
```

| | | Source |
|---|---|---|
| Topology | one `mirror-0` vdev, **3-way**, two-disk fault tolerance | `zpool status -v`, 2026-09-09 |
| Health | `ONLINE`, **no known data errors** | `zpool status -v`, 2026-09-09 |
| Capacity | 1721.0 GiB (1.68 TiB) total, **66.23 GiB used (3.85%)**, 1654.8 GiB free | `pvesm status`, 2026-09-09 |
| Members | 3 × 1.92 TB SATA SSD — **2 × SK hynix + 1 × Micron** | `zpool status -v`, 2026-09-09 |
| PVE `content` | `images,rootdir` · mountpoint `/archive-pool` · thick · `blocksize 8k` | `STORAGE.md:48-88` |

**The members are deliberately not matched, and that is worth keeping.** Two SK
hynix and one Micron means the vdev does not share a firmware revision or a
manufacturing batch across all three. The four SK hynix units in this chassis
carry near-consecutive serials (`…584Y`, `…584Z`, `…5850`, `…5855`) — one batch,
correlated wear, correlated failure modes. The Micron is the reason a batch-wide
defect cannot take the whole mirror. **Replace a failed SK hynix with a
different vendor**, not with one of the spares below.

Almost all of the 66.23 GiB used is the PGDATA zvol's 66.0 GiB `refreservation`
(`STORAGE.md:8`). The actual NFS payload — `minio-data`, `postgres-data` — is
small enough to disappear into the rounding.

Under sanoid: `minio-data`, `postgres-data`, `vm-104-disk-0` — 24 hourly / 30
daily / 6 monthly (`SANOID.md`).

> ⚠️ Holds `k3s-worker2`'s PGDATA zvol (`zd0`). Any pool work needs that VM
> stopped first (`README.md:119-122`, `STORAGE.md:125-128`).

---

## `sde` and `sdf` — the two free SSDs

The leftovers from the downsize. `POOL-DOWNSIZE.md:3-4` records it exactly:
5-disk raidz2 (5.03 TiB) → 3-way mirror (1.73 TiB), **"two 1.92 TB SSDs
freed"**. These are those two.

| | |
|---|---|
| Devices | `ata-HFS1T9G3H2X069N_ADB5N4365I150584Y` (`sde`), `ata-HFS1T9G3H2X069N_ADB5N4365I1505850` (`sdf`) |
| Size | 1.75 TiB each (1.92 TB) |
| State | **not in any pool, not mounted, not in `pvesm status`** |
| Residue | both still carry `part1` + `part9` — the ZFS data + 8 MiB reserved pair, left from the raidz2 |

A mirror of the two gives **1.75 TiB usable**, which is the additive,
non-disruptive capacity available today with no purchase and no migration.

> ⚠️ **They still look like pool members.** The ZFS partitions were never wiped,
> so anything that auto-imports could try. Before using them, prove they are
> orphans rather than trusting this file:
>
> ```bash
> zpool import                 # must NOT offer a pool built from sde/sdf
> zdb -l /dev/sde1             # read the label; expect the old pool's name/GUID
> zdb -l /dev/sdf1
> ```
>
> Only then `wipefs -a /dev/disk/by-id/ata-HFS1T9G3H2X069N_ADB5N4365I150584Y`
> (and `…1505850`). `wipefs` on the wrong `by-id` is unrecoverable — paste the
> serial, do not type it.

---

## `/mnt/sas1`, `/mnt/sas2`, `/mnt/sas3` — 10.5 TiB with no redundancy

The largest pool of capacity in the chassis, and the least protected thing in it.

| Mount | Device | `by-id` | Serial | Size | Used | Contents |
|---|---|---|---|---|---|---|
| `/mnt/sas1` | `sdi` | `scsi-35002538a48872be0` | `S3D9NX0K803418` | 3.49 TiB | **2.2 MB** | `tailscale-gateway-logs` |
| `/mnt/sas2` | `sdg` | `scsi-35002538a48872950` | `S3D9NX0K803377` | 3.49 TiB | **20 K** | **empty** — `lost+found` only |
| `/mnt/sas3` | `sdh` | `scsi-35002538a48872700` | `S3D9NX0K803346` | 3.49 TiB | **20 K** | **empty** — `lost+found` only |

*`df -h` and `du -xh --max-depth=2`, 2026-09-09.* All three are ext4,
`rw,relatime,stripe=2` on `/mnt/sas1`.

> ✅ **Measured 2026-09-09: there is nothing here to migrate.** `/mnt/sas2` and
> `/mnt/sas3` contain a `lost+found` directory and nothing else — they were
> formatted and mounted and never used. `/mnt/sas1` holds 2.2 MB of Tailscale
> session recordings. **10.47 TiB of SAS SSD is carrying 2.2 MB of data**, and
> the entire migration cost of repurposing all three disks is copying that
> 2.2 MB somewhere redundant.
>
> This was the single largest unknown in the inventory. It is now the cheapest
> capacity in the chassis.

Three Samsung PM1633a 3.84 TB SAS SSDs, **10.47 TiB raw**, each carrying a plain
ext4 filesystem **on the raw device with no partition table** — the same
whole-device style as `STORAGE.md` §3.

### ✅ The PERC passes these disks through — confirmed 2026-09-09

`smartctl -a /dev/sdg` returned a **full native SAS SMART page with no
`-d megaraid,N` needed**, and `/sys/block/sdg/device/vendor` reads `SAMSUNG`,
not `DELL`:

```
Vendor:               SAMSUNG            <- the drive, not the controller
Product:              MZILS3T8HMLH0D3
Transport protocol:   SAS (SPL-4)
SMART support is:     Available - device has SMART capability
Logical Unit id:      0x5002538a48872950 <- the drive's own WWN
```

A RAID virtual disk would report the controller as vendor and hide SMART behind
`-d megaraid`. It does neither. **The H355 is in non-RAID / eHBA passthrough
mode, and TrueNAS would receive real disks with working SMART and scrubs.**
That was the last architectural question blocking a TrueNAS guest.

### All three read 2026-09-09 — every one clean

| | `sdg` | `sdh` | `sdi` |
|---|---|---|---|
| Serial | `…803377` | `…803346` | `…803418` |
| Health | ✅ `OK` | ✅ `OK` | ✅ `OK` |
| Endurance used | ✅ 0% | ✅ 0% | ✅ 0% |
| **Grown defect list** | ✅ **0** | ✅ **0** | ✅ **0** |
| Uncorrected errors | ✅ 0/0/0 | ✅ 0/0/0 | ✅ 0/0/0 |
| Temperature | 41 °C | 41 °C | 41 °C |
| Lifetime writes | 222 TB | 23.9 TB | 9.4 TB |
| Lifetime reads | 587 TB | 411 TB | 405 TB |
| **Power-on** | 49957:31 | 49957:42 | 49957:35 |
| Manufactured | wk 32 2018 | wk 32 2018 | wk 32 2018 |
| Non-medium errors | 10 | 10 | 8 |

**No drive has a single grown defect or uncorrected error.** Endurance is 0% on
all three — even `sdg`, the most-written, has taken only ~58 drive-writes in its
life (≈0.03 DWPD). As media, these are effectively new.

**The power-on times are within 11 minutes of each other**, on drives
manufactured in the same week of 2018. They have been powered together for their
entire 5.7-year life. That is a genuinely matched set, and it *sharpens* the
correlated-failure argument rather than softening it: whatever eventually
reaches one is likely reaching the others at the same time.

**The near-identical non-medium counts (10 / 10 / 8) are reassuring, not
concerning.** Three drives independently arriving at the same small number
points at shared bus events — link resets on the backplane or controller, most
likely at boot — rather than anything happening on the media. Media problems do
not correlate across drives like that.

**Their write histories do not match, though** — 222 TB / 23.9 TB / 9.4 TB. They
were not mirrored together in a previous life; they had separate roles before
landing here. "Matched set" applies to their age and power-on hours, not their
usage.

> ⚠️ **Last self-test was at lifetime hour 2** on `sdg` — i.e. when it was new,
> and never since. Whatever owns these disks next should run a scheduled long
> test; TrueNAS does this natively, which is one of the better arguments for it
> (see `TRUENAS.md`).

**The wear is negligible and the age is not.** 0% endurance used after 222 TB
written means the NAND has barely been touched; these were enterprise drives
that spent five years mostly idle. But eight years from manufacture is eight
years of power-loss-protection capacitors ageing, and all three serials
(`…803346`, `…803377`, `…803418`) are one batch — the same correlated-failure
argument that applies to the four SK hynix units in `archive-pool`.

Read as a risk for a *new* pool: fine for bulk data with a backup, and **not**
where the only copy of something should live.

> 📋 **`sdh` and `sdi` have not been read.** One drive's SMART is not three.
> Before committing a pool to these disks:
>
> ```bash
> for d in sdg sdh sdi; do
>   echo "== $d"
>   smartctl -a /dev/$d | grep -E 'Health|endurance|power on|defect|Non-medium|Serial'
> done
> ```

### One number that decides a pool setting

```
Logical block size:   512 bytes
Physical block size:  4096 bytes
```

512e with 4K physical. Any ZFS pool built on these must be created with
**`ashift=12`**. ZFS usually infers it, but it is unchangeable after creation —
the same class of permanent, one-shot decision as the `blocksize 8k` in
`STORAGE.md` §1, and it is worth stating explicitly rather than trusting
autodetection on a 512e drive.

State this plainly, because no other document does:

- **There is no redundancy of any kind.** Not RAID, not ZFS, not a mirror.
  Three independent filesystems on three independent disks. Any one failure
  loses that disk's contents outright — today that means the SSH recordings.
- **There are no snapshots.** `SANOID.md` covers `archive-pool` only.
- **They are in no backup.** Not barman, not vzdump, not sanoid.
- **Nothing monitors them.** No reconciler, no alert, no PVE storage entry —
  they do not appear in `pvesm status` at all, so even the capacity graphs miss
  them.

`/mnt/sas1` holds `tailscale-gateway-logs`, bind-mounted into CTID 100 as
`/var/log/ts-ssh-records` — the Tailscale SSH session recordings, and a security
control with no reconciler and no alert (`STORAGE.md` appendix).

`/mnt/sas2` and `/mnt/sas3` appear in **no other document in this repo** and
hold nothing. All three were formatted together on 2026-06-12 and only the first
was ever used.

### What is actually on `/mnt/sas1` — listed 2026-09-09

```
drwx------  2 root   root   16384 Jun 12 16:08 lost+found
drwxrwx---+ 2 100102 100004  4096 Jun 12 21:22 tailscale-gateway-logs
```

**88 KB** of session recordings — `df` reports 2.2 MB, but that is filesystem
overhead; `du` puts the payload at 88 K. Roughly 1 KB/day since 2026-06-12. At
that rate the 3.49 TiB filesystem holds about ten thousand years of recordings.

Two details that matter when this directory moves:

- **`100102:100004` is the unprivileged LXC's UID mapping** — container UID 102 /
  GID 4 seen from the host (`unprivileged = true`,
  `tofu/proxmox-container.tf`). Preserve it, or the container loses write access
  and recording stops silently.
- **The `+` means a POSIX ACL is set**, and the ACL is what actually grants the
  container access. A plain `cp` drops it. Use `cp -a` (which implies
  `--preserve=all`) or `rsync -aAX`, and verify with `getfacl` on both sides
  rather than assuming it came across.

### ⚠️ All three are in `/etc/fstab` without `nofail`

```
UUID=76d1c54b-47a2-486d-bd36-eb0678090b70 /mnt/sas1 ext4 defaults 0 2
UUID=6db19b6a-3eeb-427f-bec5-fda18c5450ae /mnt/sas2 ext4 defaults 0 2
UUID=5a93d776-ed8e-44d6-adc3-0cc75fe473e7 /mnt/sas3 ext4 defaults 0 2
```

`defaults` with a non-zero fsck pass and **no `nofail`**. These devices disappear
from the host the moment the PERC is passed through to a guest — and a missing
non-`nofail` mount does not boot past it. systemd waits on the device, times
out, and drops the host into an **emergency shell**.

**`192.168.50.101` accepts no SSH key from the dev VM**, so recovery from that
state needs iDRAC or a physical console. This is the same failure `STORAGE.md`
§5c already guards the PGDATA mount against, and the reason `nofail` is on that
fstab line.

**Removing these three lines is therefore a hard prerequisite of passthrough,
not a tidy-up afterwards.** Do it, reboot, and confirm the host comes back
before the controller is touched.

---

## Free capacity today

| Where | Amount | Cost to claim it |
|---|---|---|
| Three SAS SSDs | **10.47 TiB raw** → 3.49 TiB as a 3-way mirror, or ~6.98 TiB as raidz1 | **relocate 2.2 MB** of SSH recordings and repoint one LXC bind mount |
| `sde` + `sdf`, mirrored | **1.75 TiB usable** | none — wipe the stale ZFS labels and go |
| `archive-pool` free space | 1.61 TiB | none, but it is the *redundant* pool and already holds PGDATA + MinIO |
| `local-lvm` | 82.12 GiB | guest root disks only; falling |

Measured 2026-09-09. **The largest block of free capacity is also the cheapest
to claim** — which was not true when this file was written eight hours earlier,
and is the reason the order of these rows changed.

---

## Before anything claims the SAS disks

Passing `c3:00.0` through, or rebuilding those three disks into a pool, is the
attractive option — 10.47 TiB raw, real disks, its own controller. Four things
have to happen first, and none is optional:

1. ✅ **Done 2026-09-09 — `/mnt/sas2` and `/mnt/sas3` are empty.** The
   migration cost is 2.2 MB, all of it on `/mnt/sas1`.
2. ✅ **Done 2026-09-09 — recordings relocated to `archive-pool/ts-ssh-records`.**
   ACL and UID mapping reproduced, dataset under sanoid. See `SAS-RECLAIM.md` §2–§3.
3. ✅ **Done 2026-09-09 — fstab lines removed, host rebooted clean.** Backup at
   `/etc/fstab.bak-2026-09-09`. All three ext4 superblock signatures wiped
   (`wipefs -a` by `by-id`). See `SAS-RECLAIM.md` §4.
4. ✅ **Done 2026-09-09 — `mount_point.volume` reconciled in OpenTofu.**
   `tofu plan` confirmed 0 changes. `prevent_destroy` stayed on; the change was
   made on the host (`pct set`) because `volume` is `ForceNew` in bpg/proxmox.
   See `SAS-RECLAIM.md` §5.
5. ✅ **Done 2026-09-09 — the PERC passes the disks through.** Native SAS SMART
   with no `-d megaraid`, vendor `SAMSUNG`. See the section above. (`perccli` is
   not installed and was not needed; `lsscsi` is not installed either.)
6. ✅ **Done 2026-09-09 — all three read, all three clean.** Zero grown
   defects, zero uncorrected errors, 0% endurance on every drive.

Also worth knowing before betting on passthrough: IOMMU must be on and the PERC
must sit in a usable IOMMU group (`dmesg | grep -e DMAR -e IOMMU`,
`find /sys/kernel/iommu_groups -type l`). And PVE gates raw device attachment on
`root@pam`; PCIe devices have the newer cluster **resource mappings**
(`/cluster/mapping/pci`, privilege `Mapping.Use`) as the non-root path, which
bpg exposes as `proxmox_virtual_environment_hardware_mapping_pci`.

---

## Still unknown

| Unknown | Why it matters | How to close it |
|---|---|---|
| SMART on the 6 SATA disks — all 3 SAS disks are done | Four SK hynix from one batch age together; wear decides replace-vs-expand | `smartctl -a /dev/sdX` |
| BOSS-S2 mirror health | A failed M.2 is invisible to every monitor here | iDRAC, or the BOSS CLI |
| ~~PERC H355 personality~~ | ✅ **Closed 2026-09-09** — non-RAID passthrough, native SMART | — |
| Which of `sdb`–`sdf` is on `00:11.5` vs `00:17.0` | Only matters if SATA controller passthrough is ever reconsidered | `ls -l /sys/block/sd*/device` |
| Total bays, and how many are physically empty | Whether expansion means buying disks or also buying a chassis | Front-panel count, or iDRAC |

---

## Related

- `STORAGE.md` — how the PGDATA zvol was created and guarded; §1 is the PVE-side
  pool configuration this file is the physical counterpart to
- `SANOID.md` — which datasets are snapshotted, and which are not
- `README.md` — logical placement of every piece of data
- `sunfire/POOL-DOWNSIZE.md` — the raidz2 → 3-way-mirror rebuild that freed
  `sde` and `sdf`
- `tofu/README.md:196-322` — the API token, its privileges, and why it is
  read-only
