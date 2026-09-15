# GPU VM — Intel Arc Pro B70 passed whole to one LLM guest

> 📝 **Plan, written 2026-09-15. Nothing below has been run yet.** Every host
> step has to be run by hand as root on `192.168.50.101`, because SSH from the
> dev VM is refused and the tofu token is read-only (`tofu/README.md`, "The
> argument for read-only"). Tick each step off here as it's done, and record
> what the host actually printed. `HARDWARE.md` was built the same way.

## Decisions

| | Choice | Why |
|---|---|---|
| Workload | **Local LLM inference** | owner, 2026-09-15 |
| GPU mode | **Whole card to one VM** (`vfio-pci`), no SR-IOV split | owner. The host's `xe` currently runs the card as an SR-IOV PF (`HARDWARE.md`), and that mode goes away. |
| Model storage | **`llm-pool`, one ZFS disk on `sde`** (`…150584Y`), with **no redundancy** | Models can be downloaded again, so losing the disk costs a re-download, not data. `sas-pool` belongs to the NAS and `archive-pool` to the DB and object storage. |
| Spare | **`sdf` (`…1505850`) stays a cold spare** | owner |
| Root disk | 32 GiB on `local-lvm` | Matches the other guests. The thin pool has ~82 GiB free, so keep the root disk small. |
| Guest OS | Ubuntu 24.04 LTS on the **HWE kernel (≥ 6.17)** | The host's `6.17.2-1-pve` is known to drive this card, and Intel's GPU compute packages support this release best. |
| Snapshots | **None.** `llm-pool` stays out of `sanoid.conf` on purpose. | Snapshotting multi-GB model files would only use up space. |

---

## Phase A — preflight and storage (no reboot, no guest affected)

### A1. Read before writing

```bash
pvesh get /cluster/nextid                       # VMID to use below as $VMID (TRUENAS.md used 105 once)
qm list; pct list
nproc; lscpu | grep -E 'Model name|Socket|NUMA node'
cat /sys/bus/pci/devices/0000:53:00.0/numa_node # GPU's NUMA node; matters if 2 sockets
readlink /sys/bus/pci/devices/0000:54:00.0/iommu_group   # audio group, unrecorded in HARDWARE.md
lspci -nnk -s 53:00.0; lspci -nnk -s 54:00.0    # current drivers (expect xe / snd_hda_intel)
dmidecode -s system-product-name; dmidecode -s bios-version
pveversion
```

### A2. Prove `sde` is an orphan, then wipe it

`sdX` names move between boots (`HARDWARE.md`), so **use the by-id path only**:

```bash
D=/dev/disk/by-id/ata-HFS1T9G3H2X069N_ADB5N4365I150584Y
ls -l "$D"                   # confirm the serial ends 584Y
zpool status archive-pool    # 584Y must NOT be listed (members: 584Z, 5855, Micron 58D4)
zpool import                 # must NOT offer a pool built from this disk
zdb -l "${D}-part1"          # expect the OLD raidz2 pool's label, not a live pool
wipefs -a "$D"               # irreversible. Paste the path, don't type it.
```

### A3. Create `llm-pool` and register it with Proxmox

```bash
zpool create -o ashift=12 -O compression=lz4 -O atime=off llm-pool "$D"
pvesm add zfspool llm-pool --pool llm-pool --content images --blocksize 64k
pvesm status | grep llm-pool
```

- `ashift=12` because the SK hynix disks are 512e drives with 4K physical sectors. It can't be changed later.
- `blocksize 64k` sets the block size of each zvol Proxmox creates. Model files are large and read in long runs, so bigger blocks mean less metadata than the 16k default. It only applies to new zvols, so set it before creating the VM.
- `lz4` rather than `zstd`: model weights barely compress, and lz4 gives up quickly on data that doesn't.

### A4. PCI resource mapping

Proxmox only lets `root@pam` attach a raw `hostpci0: 0000:53:00.0`. A **mapping**
can be attached by any user or token that has `Mapping.Use`, so the VM is later expressible in tofu
without root:

```bash
pvesh create /cluster/mapping/pci --id arc-b70 \
  --description "Intel Arc Pro B70 32GB (ASRock) - whole card, LLM VM" \
  --map node=pve,path=0000:53:00.0,id=8086:e223,subsystem-id=1849:6025,iommugroup=9
pvesh get /cluster/mapping/pci/arc-b70
```

The UI equivalent is Datacenter → Resource Mappings → PCI Devices → Add.

---

## Phase B — ONE planned host reboot: `vfio-pci` binding + BIOS MMIO

Both jobs need a reboot, so do them together. **This reboot takes down the whole
cluster.** Shut down with `scripts/homelab-shutdown.sh` (dependency order, and it
refuses to hard-stop the DB VM). The Sunfire Worker serves a 503 while the cluster is down (`AGENTS.md`).

### B1. Bind the card to `vfio-pci` at boot (before the reboot)

The host driver has to let go of the card for passthrough. Proxmox can unbind `xe` when
the VM starts, but binding at boot is more reliable, and `xe` never loads SR-IOV
PF state it would then have to tear down.

```bash
cat > /etc/modprobe.d/vfio-arc-b70.conf <<'EOF'
# Intel Arc Pro B70 (53:00.0) + its HDMI audio (54:00.0) -> vfio-pci, see homelab/GPU-VM.md
options vfio-pci ids=8086:e223,8086:e2f7
softdep xe pre: vfio-pci
softdep i915 pre: vfio-pci
softdep snd_hda_intel pre: vfio-pci
EOF
printf 'vfio\nvfio_iommu_type1\nvfio_pci\n' >> /etc/modules
update-initramfs -u -k all
proxmox-boot-tool refresh   # harmless if not in use
```

Binding the audio function too means no host driver holds anything under the
card's bridges. That matters for the BAR resize in Phase D, which has to rearrange the
bridge windows the audio device also sits behind. The audio function itself doesn't go to the VM.

These IDs match only the Arc card. The host's own video is the Matrox G200 (`mgag200`), so
the host keeps a console.

### B2. Shut down and change BIOS settings

```bash
bash homelab-shutdown.sh --dry-run
bash homelab-shutdown.sh --yes --poweroff-host   # or reboot; from the console / LAN, not via Tailscale
```

> ❌ **This BIOS has no Resizable BAR option. Established 2026-09-15 by the
> owner, before this document existed** — the Dell EMC BIOS setup was searched,
> IOMMU settings were varied, and GRUB kernel parameters were tried across
> reboots. None of it made the resize succeed. **Do not spend another reboot
> looking for a ReBAR switch.**

While the host is down anyway, the two settings still worth confirming are under
**System BIOS → Integrated Devices** (they govern where the 64-bit MMIO window
lands, which is a different knob from ReBAR itself):

- **Memory Mapped I/O above 4 GB** → Enabled
- **Memory Mapped I/O Base** → the highest option offered (e.g. 56 TB / 12 TB rather than 512 GB)

Record what's actually there, including "no such option" — the names above are
from Dell 14G/15G setup and are unverified on this machine.

### B3. After boot, verify

```bash
lspci -nnk -s 53:00.0 | grep 'in use'    # -> vfio-pci
lspci -nnk -s 54:00.0 | grep 'in use'    # -> vfio-pci
zpool status -x                          # all pools healthy
lspci -vv -s 53:00.0 | grep -E 'Region 2|Resizable BAR' -A0
lspci -vvv -s 53:00.0 | sed -n '/Resizable BAR/,/^\t[A-Z]/p'
```

If **Region 2 is already `[size=32G]`**, ReBAR is solved: skip Phase D. If
it's still `[size=256M]`, continue to Phase C anyway. The VM works with a small BAR and only loads data onto the card more slowly.

Then start the guests as usual.

---

## Phase C — create the VM and install the guest

### C1. ISO

Get the current 24.04.x **live-server** ISO name from `https://releases.ubuntu.com/noble/`:

```bash
cd /var/lib/vz/template/iso && wget https://releases.ubuntu.com/noble/<ubuntu-24.04.N-live-server-amd64.iso>
```

### C2. Create

```bash
VMID=<from A1>
qm create $VMID --name llm --ostype l26 \
  --machine q35 --bios ovmf \
  --efidisk0 local-lvm:1,efitype=4m,pre-enrolled-keys=0 \
  --cpu host --sockets 1 --cores 8 \
  --memory 65536 --balloon 0 \
  --scsihw virtio-scsi-single \
  --scsi0 local-lvm:32,iothread=1,discard=on,ssd=1 \
  --scsi1 llm-pool:1400,iothread=1,discard=on,ssd=1,backup=0 \
  --net0 virtio,bridge=vmbr0 \
  --ide2 local:iso/<ubuntu-24.04.N-live-server-amd64.iso>,media=cdrom \
  --boot 'order=scsi0;ide2' \
  --agent enabled=1 \
  --hostpci0 mapping=arc-b70,pcie=1 \
  --onboot 0
```

| Setting | Why |
|---|---|
| `q35` + `ovmf` | PCIe passthrough, and a 64-bit MMIO window big enough for a 32 GiB BAR. SeaBIOS/i440fx, which the other guests use, is the wrong platform for this. |
| `cpu host` | Passes through the host's physical address width (46-bit on Ice Lake), which is what OVMF uses to size that window. It also gives llama.cpp's CPU fallback AVX-512 and AMX. |
| `memory 64 GiB`, `balloon 0` | A VM with a passthrough device pins **all** of its RAM, so ballooning can't work. 64 GiB is twice the VRAM, enough to page models through. 206 GiB is uncommitted. |
| `cores 8` | A starting point. If A1 shows two sockets, pin to the GPU's NUMA node (`--affinity` with that node's cores, `--numa 1`). |
| `scsi1 1400 GiB`, `backup=0` | Leaves ~20% of the 1.75 TiB pool free for ZFS. vzdump backups of re-downloadable models would waste space. |
| `pre-enrolled-keys=0` | Secure Boot off. It removes one failure mode with no security cost for this use. |
| no `x-vga`, `rombar` default | Compute only. The console stays on Proxmox's virtual display. |

`--onboot 0` matches the other guests.

### C3. Install and verify inside the guest

Install Ubuntu onto the **32 GiB disk only** and leave the 1400 GiB disk untouched. Then:

```bash
sudo apt update && sudo apt install -y linux-generic-hwe-24.04 qemu-guest-agent && sudo reboot
uname -r                                   # >= 6.17
lspci -nnk | grep -A3 e223                 # Kernel driver in use: xe
ls -l /dev/dri                             # card*, renderD*
sudo dmesg | grep -iE 'xe .*(BAR|GuC|HuC)'
sudo lspci -vv -d 8086:e223 | grep Region  # 256M = small BAR, 32G = ReBAR working
```

Models disk. Address it by id, and use **`nofail`** (the SAS disks' old fstab lines were missing it, and would have dropped the host to an emergency shell; `HARDWARE.md`):

```bash
M=/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi1
sudo mkfs.ext4 -L models "$M"
sudo mkdir -p /models
echo 'LABEL=models /models ext4 defaults,noatime,nofail 0 2' | sudo tee -a /etc/fstab
sudo mount -a && df -h /models
```

Pick a static IP or DHCP reservation for the VM. The last known guest is `.106`.
Confirm the next free address on the router rather than assuming `.107`.

---

## Phase D — the one ReBAR attempt left, then stop

> The owner already tried BIOS setup, IOMMU variations and GRUB parameters on
> 2026-09-15, with `xe` driving the card. Nothing worked, and this BIOS has no
> ReBAR option. **Phase D is one attempt under a condition none of that
> testing had: the card unbound, with `vfio-pci` holding it instead of `xe`.**
> A BAR cannot be resized while a driver is bound — the kernel returns `-EBUSY`
> — so every earlier attempt from a running host with `xe` loaded was refused
> before it reached the hardware. This is the only reason to try once more.
>
> **If it fails here, ReBAR is closed on this hardware.** Small BAR is then the
> permanent condition, and the "Living with a small BAR" section below is the
> answer. Do not reopen it without new firmware from Dell.

A guest can only get the BAR size the host has given the card. QEMU doesn't let the guest resize it.
So the resize happens **on the host, while nothing is bound to the card, before the VM starts.**

```bash
# VM stopped
for f in 0000:53:00.0 0000:54:00.0; do echo $f > /sys/bus/pci/devices/$f/driver/unbind; done
cat /sys/bus/pci/devices/0000:53:00.0/resource2_resize   # bitmask of supported sizes
echo 15 > /sys/bus/pci/devices/0000:53:00.0/resource2_resize   # 2^15 MB = 32 GiB
lspci -vv -s 53:00.0 | grep 'Region 2'
for f in 0000:53:00.0 0000:54:00.0; do echo $f > /sys/bus/pci/drivers_probe; done
```

Reading the result:

- **It works** (`Region 2 [size=32G]`): start the VM and check the guest reports 32G too.
  Only then make it persistent, with a Proxmox hookscript (`pre-start`) or a systemd
  oneshot ordered before `pve-guests.service`. Never persist an untested resize —
  a failed one at boot leaves the card with no usable BAR at all.
- **`No space left on device` / `-ENOSPC`:** the window on the PCIe port above
  `51:00.0` (find it with `lspci -tv`) can't fit 32 GiB. That is firmware's
  allocation, and with no ReBAR option in setup there is nothing left to try
  here. Go to "Living with a small BAR".
- **`-ENOENT` again, or the file doesn't exist:** the card isn't offering a
  resize the kernel can use in this topology. Same conclusion.
- **The guest sees 32G but `xe` fails to map it:** that one is fixable — OVMF's
  64-bit window is too small. Add `args: -fw_cfg
  name=opt/ovmf/X-PciMmio64Mb,string=65536` to the VM config.

### Living with a small BAR

**This is very likely the outcome, and the VM is still worth building.** What
small BAR does and doesn't cost, for LLM inference specifically:

- **VRAM capacity is unaffected.** All 32 GiB is allocatable by the GPU. The
  256 MiB is only the window the *CPU* sees at any moment; the driver moves that
  window as needed. A 30 GiB model still fits.
- **Inference speed is largely unaffected.** Once weights are resident in VRAM,
  token generation reads them with the card's own memory bandwidth and never
  crosses that window.
- **Loading a model is slower**, because every GiB of weights is copied through a
  window the kernel has to keep re-pointing. Expect load times to hurt, not
  tokens/sec. Load a model once and keep the server process resident rather than
  starting it per request.
- **Avoid zero-copy / unified-memory paths** that map VRAM straight into host
  address space. Explicit copies (what llama.cpp SYCL and vLLM-XPU do by
  default) are the right pattern here.

> ⚠️ Unverified: the size of that penalty on this card has not been measured.
> Time one model load in the guest and write the number down here — it is the
> only figure that settles whether small BAR actually matters for this workload.

---

## Phase E — bring it under tofu, and update the docs

1. **Import the guest** the same way as the other four (`tofu/README.md`, "The sequence"): an `import`
   block for `pve/$VMID`, `-generate-config-out`, review, and `prevent_destroy`, with a short-lived
   `TofuDisk` grant. **On a branch** (`tofu/` change). Expect `hostpci { mapping = "arc-b70" }`
   in the generated config. The PCI mapping itself is cluster config and stays documented here.
2. `HARDWARE.md`: set `sde` to `llm-pool`, change the GPU section from "not attached" to the VMID, record the
   audio IOMMU group and the Phase B/D outcomes, and add `llm-pool` to "Free capacity".
3. `README.md`: add the new row to the Guests table.
4. `SANOID.md`: add one line saying `llm-pool` is deliberately not snapshotted.
5. `HOST-MONITORING.md`: add `sde` (by-id) to `smartd` if disks are listed one by one.

## Checklist

- [ ] A1 preflight read and recorded
- [ ] A2 `sde` proven orphan, wiped
- [ ] A3 `llm-pool` created, in `pvesm status`
- [ ] A4 `arc-b70` mapping exists
- [ ] B1 vfio config + initramfs
- [ ] B2 clean shutdown, BIOS MMIO/ReBAR settings recorded
- [ ] B3 both functions on `vfio-pci`, pools healthy, Region 2 size recorded
- [ ] C2 VM created
- [ ] C3 guest on `xe`, `/models` mounted
- [ ] D one unbound resize attempt made, result recorded — then closed either way
- [ ] D model load time in the guest measured and written down
- [ ] E tofu import clean, docs updated
