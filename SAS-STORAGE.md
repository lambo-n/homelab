# SAS Pool Storage (`sas-pool`) — 6.85 TiB RAIDZ1 on Proxmox

This document details the architecture, ZFS pool layout, snapshot automation,
and Samba access for **`sas-pool`**, built on the three 3.84 TB Samsung SAS SSDs
on `192.168.50.101` (`pve`).

> ⚠️ **`zpool status -x` cannot detect an unimported pool — check `zpool list`
> after every host reboot.** `sas-pool` is host-native, not a PVE storage, so
> nothing owns its import the way `pvestatd` owns `archive-pool`'s. It went
> missing for a full day in 2026-09-15/16 while every dependant (`smbd`,
> `sanoid`) reported healthy against an absent pool. The fix —
> `systemctl enable zfs-import-scan` — is in place and has been proven across
> one real reboot. Confirm all three pools (`archive-pool`, `sas-pool`,
> `llm-pool`) are present by name before trusting `/sas-pool/data` or the
> `[data]` share. Full incident record:
> [`archive/SAS-STORAGE-INCIDENT.md`](archive/SAS-STORAGE-INCIDENT.md).

---

## Architecture & Topology

### 1. The Disks

Following [`archive/SAS-RECLAIM.md`](archive/SAS-RECLAIM.md), the three Samsung PM1633a 3.84 TB
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

> ⚠️ **Unbinding the controller really did fault `archive-pool`, briefly** — it
> resilvered clean in four minutes once the drives came back, and the incident
> went unnoticed for hours only because host mail delivery was silently broken
> at the time. See [`archive/SAS-STORAGE-INCIDENT.md`](archive/SAS-STORAGE-INCIDENT.md)
> for the full account and why it argues for [`HOST-MONITORING.md`](HOST-MONITORING.md).

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

### Host Firewall (`/etc/pve/nodes/pve/host.fw`)

Proxmox VE's host firewall operates on default drop. Ports 445 (SMB) and 139 (NetBIOS)
are explicitly permitted from the LAN / Tailscale subnet `192.168.50.0/24`:

```ini
[RULES]
IN ACCEPT -source 192.168.50.0/24 -p tcp -dport 445 -log nolog # Samba SMB
IN ACCEPT -source 192.168.50.0/24 -p tcp -dport 139 -log nolog # NetBIOS SMB
```

Reloaded via `pve-firewall compile && pve-firewall restart`.

### Mounting from Clients

- **Windows:** `\\192.168.50.101\data`
- **Linux (Nemo / GNOME Files / Dolphin):** `smb://192.168.50.101/data` (Connect as Registered User)
- **macOS:** Finder -> `Cmd+K` -> `smb://192.168.50.101/data`
- **Auth:** Username `lambo`, with Samba credentials configured via `smbpasswd -a lambo`.

