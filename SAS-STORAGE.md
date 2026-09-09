# SAS Pool Storage (`sas-pool`) — 6.85 TiB RAIDZ1 on Proxmox

This document details the architecture, ZFS pool layout, snapshot automation,
and Samba access for **`sas-pool`**, built on the three 3.84 TB Samsung SAS SSDs
on `192.168.50.101` (`pve`).

---

## Architecture & Topology

### 1. The Disks

Following [`SAS-RECLAIM.md`](SAS-RECLAIM.md), the three Samsung PM1633a 3.84 TB
SAS SSDs were freed from ext4, wiped with `wipefs -a`, and verified healthy:

| Device | `by-id` | Serial | Size | Role |
|---|---|---|---|---|
| `sdh` | `scsi-35002538a48872950` | `S3D9NX0K803377` | 3.49 TiB | `sas-pool` `raidz1-0` member |
| `sdi` | `scsi-35002538a48872700` | `S3D9NX0K803346` | 3.49 TiB | `sas-pool` `raidz1-0` member |
| `sdj` | `scsi-35002538a48872be0` | `S3D9NX0K803418` | 3.49 TiB | `sas-pool` `raidz1-0` member |

- **Physical Block Size:** 4096 bytes (512e). Formatted with **`ashift=12`**.
- **Compression:** `zstd` (high ratio, fast transparent compression).
- **Topology:** **RAIDZ1** (1-drive parity, 2-drive data) yielding **6.85 TiB usable** capacity.

### 2. Why Native Host ZFS Instead of a TrueNAS VM

During the 2026-09-09 TrueNAS VM deployment attempt, two critical hardware facts
surfaced regarding the **Dell PERC H355 Front** controller (`c3:00.0`):

1. **Shared Backplane Cabling:** In this Dell chassis, all 8 front drive bays
   (`sdb`–`sdj`) are cabled to the PERC H355 Front controller. This includes the
   three mirror members of `archive-pool`. Attempting PCIe passthrough of
   `c3:00.0` unbinds `archive-pool` from the hypervisor.
2. **Firmware RMRR (Reserved Memory Region Reporting):** Dell BIOS specifies an
   RMRR for the PERC controller (used by iDRAC for out-of-band management).
   Linux VFIO intentionally rejects passing through devices with active RMRR
   regions for memory isolation safety (`Firmware has requested this device have
   a 1:1 IOMMU mapping, rejecting configuring the device without a 1:1 mapping`).

**Result:** Hosting `sas-pool` directly on Proxmox VE natively provides maximum
performance, zero VM RAM overhead, uniform `sanoid` snapshot scheduling, and zero
device contention.

---

## Pool Configuration

Created on 2026-09-09:

```bash
zpool create -o ashift=12 -O acltype=posixacl -O xattr=sa -O compression=zstd sas-pool raidz1 \
  /dev/disk/by-id/scsi-35002538a48872950 \
  /dev/disk/by-id/scsi-35002538a48872700 \
  /dev/disk/by-id/scsi-35002538a48872be0

zfs create sas-pool/data
```

Status verification:
```
  pool: sas-pool
 state: ONLINE
config:

	NAME                        STATE     READ WRITE CKSUM
	sas-pool                    ONLINE       0     0     0
	  raidz1-0                  ONLINE       0     0     0
	    scsi-35002538a48872950  ONLINE       0     0     0
	    scsi-35002538a48872700  ONLINE       0     0     0
	    scsi-35002538a48872be0  ONLINE       0     0     0

errors: No known data errors
```

---

## Snapshot Protection (Sanoid)

`sas-pool/data` is protected under `/etc/sanoid/sanoid.conf` using the `archival`
template:

```ini
[sas-pool/data]
	use_template = archival
	recursive = yes
```

- Retention: 24 hourly / 30 daily / 6 monthly snapshots.
- Pruning and creation managed automatically by `sanoid.timer` (every 15 minutes).

---

## Remote Access (Samba / Tailnet)

Only one user accesses this storage. Because the client has:
```bash
sudo tailscale set --accept-routes
```
and `tailscale-gateway` (CTID 100) advertises `192.168.50.0/24`, access is direct
to `192.168.50.101` over the tailnet without public exposure or port forwarding.

### Samba Share Config (`/etc/samba/smb.conf`)

```ini
[data]
	comment = SAS Pool Storage
	path = /sas-pool/data
	browseable = yes
	read only = no
	guest ok = no
	valid users = lambo
	create mask = 0664
	directory mask = 0775
```

### Mounting from Clients

- **Windows:** `\\192.168.50.101\data`
- **Linux:** `smb://192.168.50.101/data` (or via `cifs` mount)
- **macOS:** `smb://192.168.50.101/data`
- **Auth:** Username `lambo`, with Samba credentials configured via `smbpasswd -a lambo`.
