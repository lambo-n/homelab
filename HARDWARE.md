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
| Physical devices recorded | **9 disks + 1 zvol, all identified**; 1 GPU, Intel Arc Pro B70 (2026-09-15) |
| Free bays / unused devices | **1 × 1.92 TB SATA SSD, unallocated** (`sdf`); `sde` became `llm-pool` 2026-09-16 |
| Still unknown | SMART on the 6 SATA disks; BOSS mirror health; empty bay count |
| ~~Live hazard~~ | ✅ **Resolved 2026-09-09** — `/mnt/sas{1,2,3}` unmounted, fstab entries removed, host rebooted clean |

---

## The host

| | | Source |
|---|---|---|
| Proxmox VE | `192.168.50.101` (`pve`) | `README.md:83` |
| Also runs | NFS server exporting `/archive-pool` | `README.md:84` |
| Model | **Dell PowerEdge T550** (15G), BIOS **1.8.2** | `dmidecode`, 2026-09-16 |
| CPU | **Xeon Silver 4314** @ 2.40 GHz — 1 socket, 32 threads, **1 NUMA node** (`node0` = 0–31) | `lscpu`, 2026-09-16 |
| Proxmox VE | `pve-manager/9.1.1`, kernel `6.17.2-1-pve` | `pveversion`, 2026-09-16 |
| Kernel cmdline | `quiet intel_iommu=on iommu=pt pci=realloc,bridge_realloc pci=noiov`, plain GRUB (`/etc/default/grub`, no `grub.d` override). The `pci=` options are presumably left from the 2026-09-15 ReBAR attempts, which the docs had only as "GRUB kernel parameters tried"; **`bridge_realloc` and `noiov` are confirmed no-ops**: `PCI: Unknown option` for both in the 2026-09-16 02:12 boot log. `pci=noats` was added and accepted 2026-09-16 ([`GPU-VM.md`](GPU-VM.md) C2a). | `/proc/cmdline`, 2026-09-16 |
| Platform | Ice Lake generation — `fe:00.x Intel Ice Lake Ubox Registers`, Dell subsystem IDs `1028:*` on every controller | `lspci -nnk`, 2026-09-09 |
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
| `00:11.5` | Intel C620 sSATA [AHCI] `[8086:a1d2]` | `ahci` | **None** — motherboard ports empty |
| `00:17.0` | Intel C620 SATA [AHCI] `[8086:a182]` | `ahci` | **None** — motherboard ports empty |
| `c3:00.0` | Broadcom/LSI MegaRAID 12GSAS SAS38xx, subsystem **Dell PERC H355 Front** `[1028:2173]` | `megaraid_sas` | **All 8 front bays:** `archive-pool` (`sdb`, `sdc`, `sdg`), `llm-pool` (`sde`), cold spare (`sdf`), and `sas-pool` (`sdh`, `sdi`, `sdj`) |

Key architectural findings confirmed 2026-09-09:

- ⚠️ **The PERC H355 Front drives the entire front drive backplane.** Both the 5
  SATA SSDs and the 3 SAS SSDs attach via SCSI host `megaraid_sas`. The
  motherboard SATA controllers carry no drives.
- ❌ **PCIe passthrough of `c3:00.0` is not possible:**
  1. Unbinding `c3:00.0` detaches `archive-pool` along with the SAS drives.
  2. Dell BIOS defines a **Reserved Memory Region (RMRR)** on the Front PERC
     for out-of-band management, causing Linux VFIO to reject passthrough
     (`Firmware has requested this device have a 1:1 IOMMU mapping`).
- ✅ **Host-native ZFS (`sas-pool`):** The three SAS drives are configured
  directly on the Proxmox host as **`sas-pool`** in RAIDZ1 (6.85 TiB usable),
  protected by `sanoid` (`archival` template) and exported via Samba. See
  [`SAS-STORAGE.md`](SAS-STORAGE.md).

---

## GPU — Intel Arc Pro B70, installed 2026-09-15

Installed with a full power cycle of the homelab. Everything below is from the
host console the same day (`lspci -nnk`, `dmesg`, `/sys/kernel/iommu_groups`).
**Attached to VM 105 (`llm`, `192.168.50.107`) since 2026-09-16**, whole card via the `arc-b70` mapping. No k3s node sees it. Planned: whole
card to one LLM VM, models on `sde` as `llm-pool` — see [`GPU-VM.md`](GPU-VM.md).

| | | Source |
|---|---|---|
| Model | **Intel Arc Pro B70** (ASRock) — `lspci` shows only the GPU family, "Battlemage G21" | owner, 2026-09-15 |
| Address | `53:00.0` — Intel Battlemage G21 `[8086:e223]`, subsystem **ASRock** `[1849:6025]` | `lspci -nnk` |
| Siblings | bridges `51:00.0` `[8086:e2ff]`, `52:01.0` `[8086:e2f0]`, `52:02.0` `[8086:e2f1]`; audio `54:00.0` `[8086:e2f7]` | `lspci -nn` |
| VRAM | **32 GiB** physical (`0x800000000`); **31.89 GiB usable** (`0x7f9000000`, 32 GiB − 112 MiB stolen), confirmed in VM 105; 256 MiB CPU-visible (`0x10000000`, small BAR). Small BAR limits CPU visibility, not what fits in VRAM | `dmesg` (host 2026-09-15; guest `xe` 2026-09-16) |
| Host driver | **`vfio-pci`** since 2026-09-16 (both `53:00.0` and `54:00.0`, bound in the initramfs). Was `xe` in SR-IOV PF mode. | `lspci -nnk`, 2026-09-16 |
| Resizable BAR capability | **Present.** `Physical Resizable BAR`, BAR 2 current 256MB, **supported 256MB – 32GB**; also a `Virtual Resizable BAR` (SR-IOV VFs) | `lspci -vvv`, 2026-09-16 |
| BIOS MMIO | *Memory Mapped I/O above 4 GB* **Enabled** (already); *Memory Mapped I/O Base* **56 TB** (was 12 TB) | owner at POST, 2026-09-16 |
| PCIe windows | Root port `50:02.0` → switch `51:00.0` → ports `52:01.0` (GPU) / `52:02.0` (audio). Prefetchable: root port **72G**, switch and GPU port **64G**; root bus `0000:50` 64-bit aperture `220000000000-22ffffffffff` = **1 TiB**. Nothing else under the root port | `lspci -vv`, `/proc/iomem`, 2026-09-16 |
| SR-IOV reservation | 7 VFs × 8G = **56G** of VF BAR 2 reserved in the GPU window (plus 112M VF BAR 0), `Number of VFs: 0`. No sysfs control to shrink it | `lspci -vvv`, sysfs, 2026-09-16 |
| Firmware | GuC 70.49.4 · HuC 8.2.10 · DMC 2.6 — all loaded | `dmesg` |
| Host kernel | `6.17.2-1-pve` | `uname -r` |
| Device nodes | `/dev/dri/card0`, `card1`, `renderD128` (`render` group) | `ls -l /dev/dri` |
| IOMMU group | **9 — `53:00.0` alone**; the audio function `54:00.0` is group **10** | `ls /sys/kernel/iommu_groups/9/devices/`; `readlink …/54:00.0/iommu_group`, 2026-09-16 |
| On-board video | `03:00.0` Matrox G200eW3 (`mgag200`), group 25 — iDRAC console | `lspci -nnk` |

- ✅ **Adding it moved no storage controller.** `05:00.0`, `00:11.5`, `00:17.0`,
  `c3:00.0` are unchanged, and `zpool status -x` reported all pools healthy.
- ✅ **Passthrough-eligible, unlike the PERC.** It is alone in its IOMMU group and
  neither RMRR in `dmesg` (`41fcd000–49fd4fff`, `69424000–69426fff`) covers it.
  Passing it to a VM means rebinding `53:00.0` from `xe` to `vfio-pci`, which
  also takes it away from the host. The audio function `54:00.0` is in a
  different group — **10**, read 2026-09-16 — so the card is assignable without
  it. `GPU-VM.md` B1 binds it to `vfio-pci` all the same, so that no host driver
  holds a device under the card's bridges during the Phase D BAR attempt; it is
  not attached to the VM.
- ⚠️ **Resizable BAR is off — but the card supports it.** Confirmed 2026-09-16
  with `vfio-pci` holding the card: the `Physical Resizable BAR` capability lists
  every size from 256MB to **32GB**, so the limit is the missing resize, not the
  hardware. ❌ **The host-side resize to 32 GiB then failed with `-ENOSPC`**
  (2026-09-16, card unbound): the 56G SR-IOV VF reservation fills the 64G GPU
  window, and the kernel neither grew the windows nor dropped the VFs. **A 4 GiB resize
  works** (2026-09-16, verified in VM 105: CPU-accessible VRAM 256 MiB → 4 GiB).
  The kernel dropped the unused 56G VF BAR reservation to do it. Not yet
  persistent across host reboots. See [`GPU-VM.md`](GPU-VM.md) Phase D. Original finding:
  `Failed to resize BAR2 to 32768M (-ENOENT)` →
  `Small BAR device`: the CPU sees only 256 MiB of the 32 GiB at a time. It works,
  but compute and model loading that move lots of data to the card will be slower.
  ❌ **No fix available in firmware: this Dell EMC BIOS has no Resizable BAR
  option** (owner, 2026-09-15 — setup searched, IOMMU settings varied, GRUB
  kernel parameters tried; none helped) — **on BIOS 1.8.2**, the version running
  as of 2026-09-16. A Dell BIOS update is the only thing that could reopen this. One attempt remains, with the card
  unbound from `xe` and held by `vfio-pci`, since a bound driver makes the
  kernel refuse a resize outright — see [`GPU-VM.md`](GPU-VM.md) Phase D. Treat
  small BAR as permanent until that says otherwise.
- 🔴 **Passthrough with ATS enabled hard-locks the host.** First `qm start 105`
  on 2026-09-16: after `vfio-pci` reset the card, VT-d Device-TLB invalidations
  to `53:00.0` timed out (`DMAR: … Invalidation Time-out Error`, `QI PRIOR:
  Device-TLB Invalidation qw0 = 0x5300530000000003`), and 45 s later
  `watchdog: CPU13: Watchdog detected hard LOCKUP`. The whole host was down until
  a power cycle. **Fixed by `pci=noats`**, verified 2026-09-16 02:16 PDT: same
  reset sequence, no Device-TLB timeouts, `ATSCtl: Enable-` with the VM running,
  and the guest booted ([`GPU-VM.md`](GPU-VM.md) C2a). Removing that parameter
  brings the lockup back.
- ℹ️ `Cannot find any crtc or sizes` is only because no monitor is plugged in.

---

## Every block device

As read 2026-09-09. **`by-id` is the only name that should ever appear in a
command** — `sdX` reorders when a disk is added or the controller enumerates
differently (`STORAGE.md:189-190`).

| Dev | `/dev/disk/by-id/…` | Model | Serial | Size | Bus | Role |
|---|---|---|---|---|---|---|
| `sda` | `ata-DELLBOSS_VD_aa06e20941c90010` | `DELLBOSS VD` | `aa06e20941c90010` | 223.5 GiB | SATA (BOSS) | boot — `/boot/efi`, `pve-root`, `pve-swap`, `local-lvm` |
| `sdb` | `ata-HFS1T9G3H2X069N_ADB5N4365I150584Z` | `HFS1T9G3H2X069N` | `ADB5N4365I150584Z` | 1.75 TiB | SATA (PERC) | `archive-pool` `mirror-0` |
| `sdc` | `ata-MTFDDAK1T9TDT_222939CA58D4` | `MTFDDAK1T9TDT` | `222939CA58D4` | 1.75 TiB | SATA (PERC) | `archive-pool` `mirror-0` |
| `sdg` | `ata-HFS1T9G3H2X069N_ADB5N4365I1505855` | `HFS1T9G3H2X069N` | `ADB5N4365I1505855` | 1.75 TiB | SATA (PERC) | `archive-pool` `mirror-0` |
| `sde` | `ata-HFS1T9G3H2X069N_ADB5N4365I150584Y` | `HFS1T9G3H2X069N` | `ADB5N4365I150584Y` | 1.75 TiB | SATA (PERC) | **`llm-pool`** — single-disk ZFS, no redundancy, created 2026-09-16 ([`GPU-VM.md`](GPU-VM.md)) |
| `sdf` | `ata-HFS1T9G3H2X069N_ADB5N4365I1505850` | `HFS1T9G3H2X069N` | `ADB5N4365I1505850` | 1.75 TiB | SATA (PERC) | **FREE** — cold spare for `archive-pool` |
| `sdh` | `scsi-35002538a48872950` / `wwn-0x5002538a48872950` | `MZILS3T8HMLH0D3` | `S3D9NX0K803377` | 3.49 TiB | SAS (PERC) | `sas-pool` `raidz1-0` member |
| `sdi` | `scsi-35002538a48872700` / `wwn-0x5002538a48872700` | `MZILS3T8HMLH0D3` | `S3D9NX0K803346` | 3.49 TiB | SAS (PERC) | `sas-pool` `raidz1-0` member |
| `sdj` | `scsi-35002538a48872be0` / `wwn-0x5002538a48872be0` | `MZILS3T8HMLH0D3` | `S3D9NX0K803418` | 3.49 TiB | SAS (PERC) | `sas-pool` `raidz1-0` member |
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
> **Goals and runbook for closing that: [`HOST-MONITORING.md`](HOST-MONITORING.md)**
> (the BOSS mirror stays out of reach even then — it is iDRAC or nothing).

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

> ⚠️ **They still look like pool members, and the label says `archive-pool`.**
> Confirmed 2026-09-16 by `zdb -l` on `sde`: the residue is the old **5-disk
> raidz2**, `pool_guid 326662858968651967`, and it carries the *same pool name as
> the live pool*. A matching name is therefore not evidence of anything — the
> live `archive-pool` is a 3-way `mirror-0`, the label is `raidz`/`nparity: 2`
> over five children, and the guids differ. **Never `zpool import archive-pool`
> or `zpool import -f -a` on this host; resolve by guid.**
>
> `sde`'s partition table was wiped 2026-09-16 (the labels inside the old `part1`
> are still on the platter until `zpool create` overwrites them). **`sdf`
> (`…1505850`) is untouched and still carries the identical label.**
> Before using either, prove it is an orphan rather than trusting this file:
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

## SAS SSDs (`sdg`, `sdh`, `sdi`) — 10.47 TiB unallocated (reclaimed 2026-09-09)

The largest pool of capacity in the chassis. Previously mounted at `/mnt/sas1`,
`/mnt/sas2`, `/mnt/sas3` carrying ext4 filesystems with no redundancy. Reclaimed,
unmounted, and wiped on 2026-09-09 per [`SAS-RECLAIM.md`](SAS-RECLAIM.md).

| Device | `by-id` | Serial | Size | Previous Mount | Status |
|---|---|---|---|---|---|
| `sdg` | `scsi-35002538a48872950` | `S3D9NX0K803377` | 3.49 TiB | `/mnt/sas2` (empty) | **FREE** — wiped (`wipefs -a`) |
| `sdh` | `scsi-35002538a48872700` | `S3D9NX0K803346` | 3.49 TiB | `/mnt/sas3` (empty) | **FREE** — wiped (`wipefs -a`) |
| `sdi` | `scsi-35002538a48872be0` | `S3D9NX0K803418` | 3.49 TiB | `/mnt/sas1` (held 2.2 MB) | **FREE** — wiped (`wipefs -a`) |

> ✅ **Reclaimed 2026-09-09:** `/mnt/sas1`'s 2.2 MB of Tailscale session recordings
> were relocated to `archive-pool/ts-ssh-records` under sanoid, the three fstab
> lines were removed, and the host was rebooted clean. All three disks were
> wiped with `wipefs -a` by-id and are ready for PERC passthrough to TrueNAS.

Three Samsung PM1633a 3.84 TB SAS SSDs, **10.47 TiB raw**, ready for a ZFS pool.

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

> ⚠️ **The `sdX` names below are already stale.** On 2026-09-10 `smartd`
> enumerated `…803377` as `/dev/sdh`, not `sdg` — the whole SAS set moved up a
> letter, and `archive-pool`'s `…1505855` is `sde`, not `sdd`. One day, no
> hardware change. **Serials and `by-id` paths in this file are authoritative;
> the kernel names are a snapshot.** Address disks by `by-id` in any config that
> outlives a reboot — see [`HOST-MONITORING.md`](HOST-MONITORING.md) A1.

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
> (see [`TRUENAS.md`](TRUENAS.md)). **With the TrueNAS guest deferred, this is
> goal G1 in [`HOST-MONITORING.md`](HOST-MONITORING.md) — `smartd` on the host.**

**The wear is negligible and the age is not.** 0% endurance used after 222 TB
written means the NAND has barely been touched; these were enterprise drives
that spent five years mostly idle. But eight years from manufacture is eight
years of power-loss-protection capacitors ageing, and all three serials
(`…803346`, `…803377`, `…803418`) are one batch — the same correlated-failure
argument that applies to the four SK hynix units in `archive-pool`.

Read as a risk for a *new* pool: fine for bulk data with a backup, and **not**
where the only copy of something should live.

> ✅ **SMART confirmed clean on all three drives 2026-09-09** (see table above).
> Zero defects, zero uncorrected errors, 0% endurance used across `sdg`, `sdh`, and `sdi`.

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

> ⚠️ **Prior state (resolved 2026-09-09):** Prior to [`SAS-RECLAIM.md`](SAS-RECLAIM.md),
> the three disks carried bare ext4 filesystems with no redundancy, no snapshots,
> and no backups. `/mnt/sas1` carried 88 KB of SSH recordings bind-mounted into
> CTID 100, while `/mnt/sas2` and `/mnt/sas3` were empty. All three were in
> `/etc/fstab` with `defaults 0 2` and **no `nofail`**, which would have dropped
> the host into an emergency shell upon controller passthrough.
>
> All of this was resolved on 2026-09-09:
> 1. Recordings were moved to `archive-pool/ts-ssh-records` preserving ACL/ownership,
>    and added to sanoid (`archival` template).
> 2. CTID 100's bind mount was repointed on the host and reconciled in OpenTofu.
> 3. The three fstab lines were removed (backed up to `/etc/fstab.bak-2026-09-09`).
> 4. Host was rebooted clean, and all three disks were wiped with `wipefs -a`.

---

## Free capacity today

| Where | Amount | Cost to claim it |
|---|---|---|
| `sas-pool` free space | **6.85 TiB** less ~140 GiB in use | none — native ZFS RAIDZ1, exported via Samba ([`SAS-STORAGE.md`](SAS-STORAGE.md)). ⚠️ It failed to import on the 2026-09-15 boot and was recovered 2026-09-16; `zfs-import-scan` is now enabled. **Confirm with `zpool list` after any reboot** — `zpool status -x` will not show an absent pool. |
| `llm-pool` on `sde` | **1.68 TiB usable**, 1400 GiB earmarked for VM 105's models | claimed 2026-09-16 — single disk, **no redundancy and deliberately not snapshotted** ([`SANOID.md`](SANOID.md)); losing it costs a re-download ([`GPU-VM.md`](GPU-VM.md)) |
| `sdf`, unallocated | 1.75 TiB | none — cold spare for `archive-pool`, still carries the old raidz2 label |
| `archive-pool` free space | 1.61 TiB | none, but it is the *redundant* pool and already holds PGDATA + MinIO |
| `local-lvm` | 82.12 GiB | guest root disks only |

---

## Before anything claims the SAS disks

All six preconditions were completed 2026-09-09:

1. ✅ **Done 2026-09-09 — `/mnt/sas2` and `/mnt/sas3` are empty.** The
   migration cost was 2.2 MB, all of it on `/mnt/sas1`.
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

> ✅ **Outcome 2026-09-09:** PCIe passthrough of `c3:00.0` was rejected by VFIO
> due to Dell BIOS RMRR, and discovered to carry all 8 front-bay drives (including
> `archive-pool`). The three SAS disks were instead configured natively on the
> host as **`sas-pool`** (RAIDZ1, 6.85 TiB usable) under `sanoid` and exported
> via Samba (`[data]`). See [`SAS-STORAGE.md`](SAS-STORAGE.md).

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
- [`SAS-RECLAIM.md`](SAS-RECLAIM.md) — the completed runbook freeing the three SAS disks from ext4
- [`TRUENAS.md`](TRUENAS.md) — TrueNAS SCALE guest architecture, PCIe passthrough, and pool setup
- [`HOST-MONITORING.md`](HOST-MONITORING.md) — the SMART/scrub/visibility goals that
  outlived the TrueNAS guest, and who owns each one
