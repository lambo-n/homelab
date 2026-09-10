# TrueNAS SCALE — SAS Storage VM on `.107`

This runbook details the architecture, deployment, and configuration of a
**TrueNAS SCALE** guest on Proxmox VE (`192.168.50.101`), passing through the
dedicated **Dell PERC H355** controller (`c3:00.0`) carrying all three 3.84 TB
Samsung SAS SSDs.

> ⚠️ **Architecture Update (2026-09-09): Superseded by Native Host `sas-pool`.**
> During the passthrough attempt, two physical constraints were confirmed:
> 1. **Shared Backplane Cabling:** In this Dell chassis, all 8 front drive bays
>    (`sdb`–`sdj`, including the 3 members of `archive-pool`) are wired to the PERC
>    H355 (`c3:00.0`). Unbinding `c3:00.0` detaches `archive-pool`.
> 2. **Dell Firmware RMRR:** Dell BIOS assigns an RMRR region to the Front PERC,
>    which Linux VFIO rejects for security isolation.
>
> The three SAS SSDs were instead configured natively on the Proxmox host as
> **`sas-pool`** (6.85 TiB RAIDZ1) under `sanoid` and shared via Samba.
> See [`SAS-STORAGE.md`](SAS-STORAGE.md) for the active configuration.
> The material below is retained for reference.
>
> **The pool moved; the checklist did not.** Scheduled SMART long tests,
> scheduled scrubs, and a health UI were all reasons for this VM, and all three
> outlived it. They are re-homed on `smartd`, systemd timers and the existing
> Grafana stack — see [`HOST-MONITORING.md`](HOST-MONITORING.md).

---

## Architecture & Topology

### 1. The Controller & Disks

Following [`SAS-RECLAIM.md`](SAS-RECLAIM.md), the host `/etc/fstab` no longer
references `/mnt/sas{1,2,3}`, all three ext4 signatures were wiped, and CTID
100's SSH recordings were relocated to `archive-pool/ts-ssh-records`.

The controller is completely isolated:

| Component | Identifier | Details |
|---|---|---|
| **PCI Device** | `0000:c3:00.0` | Broadcom / LSI MegaRAID 12GSAS SAS38xx, subsystem **Dell PERC H355 Front** `[1028:2173]` |
| **IOMMU Group** | **Group 1** | Verified alone in group 1 (`/sys/kernel/iommu_groups/1/devices/0000:c3:00.0`). Clean passthrough without ACS overrides. |
| **Disks** | 3 × Samsung PM1633a | `MZILS3T8HMLH0D3`, 3.84 TB (3.49 TiB raw each). 512e / 4K physical (`ashift=12`). |
| **Drive Serials** | `S3D9NX0K803377`, `S3D9NX0K803346`, `S3D9NX0K803418` | All three verified: 0 grown defects, 0 uncorrected errors, 0% endurance used. |
| **Mode** | non-RAID / eHBA passthrough | Native SAS SMART exposed directly to guest OS. |

### 2. VM Identity & Resource Allocation

| Attribute | Value | Rationale |
|---|---|---|
| **VMID** | `105` | Next sequential ID after `k3s-worker2` (104). |
| **Name** | `truenas` | TrueNAS SCALE (Linux-based appliance). |
| **IP Address** | `192.168.50.107` | Gateway `192.168.50.1`, DNS `192.168.50.1`. |
| **vCPU** | 4 cores (`host` type) | Ample for SMB/NFS encryption and ZFS checksumming. |
| **RAM** | 32 GiB (ballooning off) | Proxmox has ~206 GiB unallocated. 32 GiB provides a healthy 20+ GiB ZFS ARC cache. |
| **Boot Disk** | 32 GiB on `local-lvm` | Stored on the Dell BOSS-S2 hardware RAID1 boot mirror (`sda`). |
| **Machine Type** | `q35` | Required for PCIe passthrough and UEFI. |
| **BIOS** | OVMF (UEFI) | Modern standard for SCALE. |
| **PCIe Device** | `hostpci0: 0000:c3:00.0,pcie=1` | Passes the entire PERC H355 and all attached SAS drives. |

### 3. Remote Access via Tailnet

There is only **one user** who needs access to this NAS.

Because your client workstation / laptop has route acceptance enabled:
```bash
sudo tailscale set --accept-routes
```
and `tailscale-gateway` (CTID 100) advertises the approved `192.168.50.0/24`
subnet route, **no public ports, port forwards, or Cloudflare tunnels are needed**:
- **TrueNAS Web UI:** `https://192.168.50.107` (directly over Tailscale)
- **SSH Admin:** `ssh root@192.168.50.107` (or configured admin user)
- **File Sharing (SMB):** `smb://192.168.50.107/<share>`
- **File Sharing (NFS):** `192.168.50.107:/mnt/<pool>/<dataset>`

*(Optional: TrueNAS SCALE also has a native Tailscale app in its catalog if you
ever want direct MagicDNS machine naming such as `truenas.tailnet-xyz.ts.net`).*

---

## ZFS Pool Topology Decision (3 × 3.84 TB SAS SSD)

With 3 identical enterprise SSDs (10.47 TiB raw), there are two sensible topologies:

### Option A: RAIDZ1 (Recommended for single-user capacity)
- **Usable Space:** **~6.98 TiB** (approx. 2 × 3.49 TiB usable).
- **Fault Tolerance:** 1 drive failure.
- **Resilver Speed:** On SAS SSDs, resilvering a replacement 3.84 TB SSD takes under 1 hour (unlike spinning rust which takes days).
- **Best For:** Media libraries, large backups, general storage where you want the majority of the 10.5 TiB capacity.

### Option B: 3-Way Mirror (Maximum resilience)
- **Usable Space:** **~3.49 TiB** (approx. 1 × 3.49 TiB usable).
- **Fault Tolerance:** Any 2 drive failures simultaneously.
- **Performance:** 3× sequential read speed, lowest latency.
- **Best For:** Mission-critical data with zero tolerance for downtime. Note that all 3 drives share the same manufacturer batch (wk 32 2018) and power-on hours (~50,000 hrs), so a 3-way mirror provides strong protection against correlated drive mortality.

> ⚠️ **Mandatory Pool Setting:**
> Always verify `ashift=12` (4096-byte sectors). The drives are 512e with 4K
> physical block sizes. TrueNAS SCALE defaults to `ashift=12`, but verify it
> during pool creation.

---

## Step-by-Step Deployment

**All host commands run on the Proxmox host `192.168.50.101` as root.**

### Step 1: Download TrueNAS SCALE ISO to Proxmox

Check available storage on `local` for ISOs, then fetch the latest stable
TrueNAS SCALE release (or upload via PVE Web UI: `local` -> `ISO Images`):

```bash
# On 192.168.50.101:
cd /var/lib/vz/template/iso/
# Download TrueNAS SCALE ISO
wget -O TrueNAS-SCALE.iso "https://download.truenas.com/TrueNAS-SCALE-Cobia/23.10.2/TrueNAS-SCALE-23.10.2.iso"
```

### Step 2: Create the VM on Proxmox

Create VM 105 with `q35`, UEFI, 4 vCPUs, 32 GiB RAM, and bridge `vmbr0`:

```bash
qm create 105 \
  --name truenas \
  --machine q35 \
  --bios ovmf \
  --cpu host \
  --cores 4 \
  --memory 32768 \
  --balloon 0 \
  --net0 virtio,bridge=vmbr0,firewall=0,macaddr=BC:24:11:AA:7D:5B \
  --scsihw virtio-scsi-single \
  --efidisk0 local-lvm:0,efitype=4m,pre-enrolled-keys=1 \
  --scsi0 local-lvm:32,discard=on,ssd=1 \
  --ide2 local:iso/TrueNAS-SCALE.iso,media=cdrom \
  --boot order=ide2;scsi0 \
  --onboot 1
```

### Step 3: Attach the PERC H355 via PCIe Passthrough

Attach `0000:c3:00.0` as `hostpci0` with PCIe express enabled:

```bash
qm set 105 -hostpci0 0000:c3:00.0,pcie=1
```

Confirm configuration:
```bash
qm config 105
```

Expect to see:
```ini
bios: ovmf
boot: order=ide2;scsi0
cores: 4
cpu: host
efidisk0: local-lvm:vm-105-disk-0,efitype=4m,pre-enrolled-keys=1
hostpci0: 0000:c3:00.0,pcie=1
machine: q35
memory: 32768
name: truenas
net0: virtio=...,bridge=vmbr0
onboot: 1
scsi0: local-lvm:vm-105-disk-1,discard=on,ssd=1
scsihw: virtio-scsi-single
```

### Step 4: Install TrueNAS SCALE

1. Start the VM:
   ```bash
   qm start 105
   ```
2. Open the Proxmox web console (`https://192.168.50.101:8006/#v1:0:=qemu/105:4:13:console`).
3. Follow the installer:
   - Select the 32 GiB `QEMU HARDDISK` (the virtual disk) as the installation target.
   - **Do NOT install onto any of the 3.84 TB Samsung drives!**
   - Set administrative password.
   - Boot via UEFI.
4. Once installation finishes, shut down the VM, remove the ISO, and set boot order to disk:
   ```bash
   qm set 105 --delete ide2
   qm set 105 --boot order=scsi0
   qm start 105
   ```

### Step 5: Network & Static IP Setup

1. In the TrueNAS console menu, configure network interface:
   - Interface: `vtnet0` (or `ens18` / `eth0` depending on naming)
   - IPv4 Address: `192.168.50.107/24`
   - IPv4 Default Gateway: `192.168.50.1`
   - Nameserver: `192.168.50.1`
2. Test network connectivity from dev VM or laptop:
   ```bash
   ping -c 3 192.168.50.107
   curl -k -I https://192.168.50.107
   ```

### Step 6: Create the ZFS Pool in TrueNAS Web UI

1. Log into TrueNAS Web UI at `https://192.168.50.107`.
2. Navigate to **Storage** -> **Create Pool**:
   - **Pool Name:** `tank` (or `sas-pool`)
   - Confirm that all three Samsung SSDs (`sdg`, `sdh`, `sdi` / by serial) appear under Available Disks.
   - Layout:
     - For **~7 TiB usable:** Select **RAIDZ1** (3 disks).
     - For **~3.5 TiB usable:** Select **Mirror** (3-way mirror).
   - Encryption: Optional (leave off for simplicity unless required).
3. Create the pool. TrueNAS applies `ashift=12` automatically for 4K physical sectors.

### Step 7: Configure Scheduled SMART Tests & Scrubs

As noted in [`HARDWARE.md:320-324`](HARDWARE.md), these SAS disks previously had
no automated self-tests:

1. **SMART Tests:**
   - Go to **Data Protection** -> **S.M.A.R.T. Tests** -> **Add**.
   - Type: `LONG`
   - Schedule: Monthly (e.g. 1st of the month at 02:00).
   - Disks: All 3 SAS SSDs.
2. **ZFS Scrub:**
   - Go to **Data Protection** -> **Scrub Tasks**.
   - Schedule: Bi-weekly or Monthly.

### Step 8: Set Up Datasets & Sharing (SMB / NFS)

1. **Create Datasets:**
   - `tank/data` (generic personal storage)
   - `tank/backups` (client backups)
2. **Create User:**
   - Under **Credentials** -> **Local Users**, create your user account.
3. **SMB Share (for macOS / Windows / Linux):**
   - Under **Shares** -> **Windows Shares (SMB)** -> **Add**.
   - Path: `/mnt/tank/data`
   - Restart SMB service.
   - Test connecting: `smb://192.168.50.107/data` using your user credentials over Tailscale.

---

## OpenTofu Reconciliation

Once VM 105 is verified and running, import its configuration into OpenTofu state
to maintain GitOps consistency with the other VMs (`dev`, `k3s-control`,
`k3s-worker1`, `k3s-worker2`).

In `tofu/proxmox-vms.tf`:

```hcl
import {
  to = proxmox_virtual_environment_vm.truenas
  id = "pve/105"
}

resource "proxmox_virtual_environment_vm" "truenas" {
  node_name = "pve"
  vm_id     = 105
  name      = "truenas"

  # Hardware configuration matching qm config 105
  machine       = "q35"
  bios          = "ovmf"
  cpu {
    type  = "host"
    cores = 4
  }
  memory {
    dedicated = 32768
    floating  = 32768
  }

  hostpci {
    device = "hostpci0"
    id     = "0000:c3:00.0"
    pcie   = true
  }

  lifecycle {
    prevent_destroy = true
  }
}
```

Verify with:
```bash
export PROXMOX_VE_API_TOKEN='tofu@pve!import=<uuid>'
cd ~/homelab/tofu && tofu plan -target=proxmox_virtual_environment_vm.truenas
```
Confirm `0 to add, 0 to change, 0 to destroy`.

---

## Verification & Rollback Checklist

- [ ] IOMMU group isolated: `0000:c3:00.0` alone in group 1
- [ ] VM 105 boots TrueNAS SCALE from 32 GiB virtual disk on `local-lvm`
- [ ] TrueNAS detects all three Samsung SAS SSDs with native serials and SMART
- [ ] ZFS pool created with `ashift=12` (RAIDZ1 or 3-way mirror)
- [ ] Web UI and shares accessible at `192.168.50.107` via Tailscale subnet route
- [ ] Automated SMART test and scrub tasks configured
- [ ] OpenTofu definition committed and plan verified with 0 changes
