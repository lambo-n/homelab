# SAS Pool Storage (`sas-pool`) — 6.85 TiB RAIDZ1 on Proxmox

This document details the architecture, ZFS pool layout, snapshot automation,
and Samba access for **`sas-pool`**, built on the three 3.84 TB Samsung SAS SSDs
on `192.168.50.101` (`pve`).

> ❗ **`sas-pool` is NOT IMPORTED as of 2026-09-16, and everything below
> describes a pool the host cannot currently see.** Found incidentally while
> running [`GPU-VM.md`](GPU-VM.md) A2 — `zpool import` offered it, and
> `zpool status sas-pool` returns `cannot open 'sas-pool': no such pool`.
>
> - All three members read **ONLINE and importable**. This is an import
>   problem, not a disk failure; no data is implicated.
> - `/sas-pool` exists as an **empty directory**, so **`smbd` has been serving an
>   empty `[data]` share** rather than failing visibly.
> - `sanoid.timer` is firing every 15 minutes with a `[sas-pool/data]` section
>   ([`SANOID.md`](SANOID.md) line 48) for a dataset that does not exist, so
>   **there have been no snapshots of this pool** for as long as it has been gone.
> - `smbd` has been up since the host booted for the GPU install
>   (2026-09-15 14:20 PDT), so the pool has been missing **at least since that
>   reboot**. Whether it ever survived one is unknown — §3's `zpool create` was
>   never followed by a reboot test, and this document says nothing about the
>   cachefile or `zfs-import-cache.service`.
>
> ```bash
> zpool import 5068010059978323696      # by id, not by name
> zfs list -r sas-pool; ls /sas-pool/data
> systemctl status zfs-import-cache.service; journalctl -b -u zfs-import-cache
> zpool get cachefile sas-pool
> ```
>
> **Add a reboot-survival check to this document once it is back** — a pool that
> two services depend on silently should not be taken on trust a second time.

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

> **The unbind really did fault the pool — evidence recovered 2026-09-10.** Point 1
> above was written as a constraint discovered by reasoning about the cabling. ZED
> had in fact logged it happening: three `ZFS device fault for pool archive-pool`
> events at **15:53:45** and a `ZFS resilver_finish` at **15:57:42** on 2026-09-09,
> during the passthrough attempt. `archive-pool` lost its members, faulted, and
> resilvered itself in four minutes once they came back — short because nothing had
> changed in the interval.
>
> **Nobody saw any of it for hours.** The notifications were found sitting in the
> postfix queue while fixing an unrelated mail problem
> ([`HOST-MONITORING.md`](HOST-MONITORING.md) A1) — `/etc/aliases.db` had never been
> built, so every message this host ever generated was deferred, unread.
>
> Two things worth keeping from that. ZED's side worked perfectly: the pool holding
> the live MinIO data and the Postgres NFS PV faulted, and the host said so
> immediately, in detail, to an address that could not receive it. **The detection
> was never the missing piece — the delivery was.** And a documented risk had
> already become a logged event without anyone noticing, which is the strongest
> available argument for Part B of `HOST-MONITORING.md`.

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

