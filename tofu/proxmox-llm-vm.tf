# VM 105 -- `llm`, the Intel Arc Pro B70 guest. See ../GPU-VM.md for the whole
# plan; this file is Phase C2.
#
# THIS IS THE ONE GUEST AUTHORED IN TOFU RATHER THAN IMPORTED. The other four
# were generated from live machines because an import that proposes changes to
# a running database VM is a hazard (proxmox-vms.tf). 105 does not exist yet and
# holds nothing, so a wrong attribute costs a rebuild -- which is what makes
# authoring it safe, and worth doing for a machine with this many non-default
# settings.
#
# APPLY WITH THE SCOPED TOKEN, AND WITHOUT REFRESH:
#
#   export PROXMOX_VE_API_TOKEN='tofu@pve!llm=<uuid>'   # LastPass
#   export CLOUDFLARE_API_TOKEN='<token>'               # both providers configure every run
#   tofu plan  -refresh=false
#   tofu apply -refresh=false
#
# `-refresh=false` is not laziness: `tofu@pve!llm` is PVEAuditor at / plus write
# on /vms/105 only, and PVEAuditor cannot refresh a QEMU guest -- the provider
# re-resolves volumes through an endpoint PVE gates on VM.Config.Disk, a WRITE
# privilege (README.md, "The privilege that blocked the four VMs"). An
# unqualified apply 403s on VMs 101-104 before it reaches this one. Skipping
# refresh is safe for a create: there is no prior state to go stale. Do NOT
# "fix" it by granting this token VM.Config.Disk on the other guests.
#
# PREREQUISITES, none of which this file can create (they need Sys.Modify /
# Mapping.Modify / root, all deliberately ungranted -- GPU-VM.md A3-A5):
#
#   - ZFS pool `llm-pool` on sde, registered as a PVE zfspool storage
#   - PCI resource mapping `arc-b70` -> 0000:53:00.0 on node pve
#   - 0000:53:00.0 bound to vfio-pci (GPU-VM.md B1) -- the VM will not start otherwise
#   - the token above, and its ACLs on /vms/105

resource "proxmox_virtual_environment_download_file" "ubuntu_noble_cloud" {
  # Cloud image rather than an ISO install: it makes the guest reproducible from
  # this file plus cloud-init, with no console clicking. Ubuntu 24.04 because the
  # host drives this card on 6.17 and Intel's compute packages target this
  # release; the image ships the 6.8 GA kernel, so GPU-VM.md C3 installs the HWE
  # kernel on first boot before expecting `xe` to bind.
  #
  # `import`, not `iso`: PVE 9 refuses a disk `import_from` any volume of type
  # iso ("has wrong type 'iso' - needs to be 'images' or 'import'", first apply,
  # 2026-09-16). The `.qcow2` name is deliberate too -- Ubuntu's `.img` is a qcow2
  # file under a generic extension, and the import content type is recognised by
  # extension. Requires `import` in the `local` storage's content list (GPU-VM.md C1).
  content_type = "import"
  datastore_id = "local"
  node_name    = "pve"
  file_name    = "noble-server-cloudimg-amd64.qcow2"
  url          = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"

  # Ubuntu publishes SHA256SUMS beside the image and rewrites `current/` in
  # place on every respin. Without a checksum this resource would silently
  # import whatever is there on the day.
  checksum           = var.ubuntu_noble_image_sha256
  checksum_algorithm = "sha256"

  # 8 GiB of thin pool for a 600 MiB image would be wasteful, but `local` is the
  # directory store on pve-root, not local-lvm. Watch it anyway: pve-root is
  # 65.6 GiB and `local` was 11.73% full on 2026-09-09 (HARDWARE.md).
  overwrite = false
}

resource "proxmox_virtual_environment_vm" "llm" {
  # 105 is new and empty today, so this guard protects nothing yet. It is here
  # from the first commit because the token that creates this VM also holds
  # VM.Allocate on /vms/105 -- which includes DELETE. The moment a model cache
  # or a fine-tune lives on the 1.4 TiB disk, this line is the only thing
  # standing between a bad diff and losing it.
  lifecycle {
    prevent_destroy = true
  }

  name        = "llm"
  description = "Intel Arc Pro B70 (32 GiB) passed whole. Local LLM inference. See GPU-VM.md"
  tags        = ["gpu", "llm"]
  node_name   = "pve"
  vm_id       = 105

  # q35 + OVMF, unlike the other four guests (SeaBIOS + i440fx). Both are
  # required here: PCIe passthrough needs the q35 topology, and the 64-bit MMIO
  # window that a 32 GiB BAR needs is an OVMF property. Changing either later
  # means rebuilding the guest, so it is not a default worth drifting into.
  machine       = "q35"
  bios          = "ovmf"
  scsi_hardware = "virtio-scsi-single"
  boot_order    = ["scsi0"]

  # Unlike the other guests, this one autostarts (owner, 2026-09-16). They are
  # brought up by hand because they depend on each other and on archive-pool's
  # NFS exports. This VM depends on nothing but the host: gpu-rebar.service runs
  # Before=pve-guests.service, so the BAR is resized before autostart can start it.
  # Its consumers (LAN apps, agents) depend on it, which puts it first on the way
  # up and after them on the way down (scripts/homelab-shutdown.sh).
  on_boot = true
  started = true

  operating_system {
    type = "l26"
  }

  efi_disk {
    datastore_id      = "local-lvm"
    file_format       = "raw"
    type              = "4m"
    pre_enrolled_keys = false # Secure Boot off -- one less failure mode, no security cost here
  }

  cpu {
    # `host` passes the physical address width through (46-bit on this Ice Lake
    # Xeon), which is what OVMF sizes its 64-bit MMIO window from -- the BAR
    # again. It also gives llama.cpp's CPU fallback AVX-512 (Ice Lake has no
    # AMX; that arrived with Sapphire Rapids).
    type    = "host"
    cores   = 8
    sockets = 1

    # numa/affinity deliberately unset until GPU-VM.md A1 reports socket count
    # and `cat /sys/bus/pci/devices/0000:53:00.0/numa_node`. On a 2-socket host,
    # pinning to the GPU's node is worth real bandwidth; guessing is worse than
    # leaving it.
  }

  memory {
    # A guest with a passthrough device pins ALL of its RAM -- ballooning cannot
    # work, so `floating = 0` is a statement of fact, not a tuning choice.
    # 64 GiB is 2x VRAM, enough to page a large model through. The host had
    # ~206 GiB uncommitted on 2026-09-09 (HARDWARE.md).
    dedicated = 65536
    floating  = 0
  }

  # THE POINT OF THE WHOLE EXERCISE.
  #
  # `mapping` rather than a raw `device = "0000:53:00.0"`: PVE only lets
  # root@pam attach a raw PCI address, so a raw device here would make this file
  # unappliable by any scoped token. The mapping is created once on the host
  # (GPU-VM.md A4) and used by name.
  #
  # No `xvga` -- this is compute, the console stays on the virtual display. The
  # card's audio function (54:00.0) is bound to vfio-pci to keep the host off
  # the card's bridges, but is not passed to the guest; nothing here needs it.
  hostpci {
    device  = "hostpci0"
    mapping = "arc-b70"
    pcie    = true
  }

  disk {
    # Root. Small on purpose: local-lvm is the thin pool shared by all guests and
    # had 82.12 GiB free on 2026-09-09. Models do NOT live here.
    datastore_id = "local-lvm"
    interface    = "scsi0"
    size         = 32
    file_format  = "raw"
    discard      = "on"
    ssd          = true
    iothread     = true
    cache        = "none"
    aio          = "io_uring"

    # Converts the cloud image into this disk on create.
    import_from = proxmox_virtual_environment_download_file.ubuntu_noble_cloud.id
  }

  disk {
    # Models. A single-disk ZFS pool on sde -- no redundancy, deliberately:
    # weights can be downloaded again, so a dead disk costs a re-download rather
    # than data. sdf stays a cold spare (GPU-VM.md, Decisions).
    #
    # 1400 of 1792 GiB leaves ZFS the free space it needs to stay fast.
    # backup = false: vzdump of re-downloadable weights would only burn space,
    # and nothing in this repo backs up 105 anyway.
    datastore_id = "llm-pool"
    interface    = "scsi1"
    size         = 1400
    file_format  = "raw"
    discard      = "on"
    ssd          = true
    iothread     = true
    backup       = false
    cache        = "none"
    aio          = "io_uring"
  }

  network_device {
    bridge = "vmbr0"
    model  = "virtio"
  }

  initialization {
    datastore_id = "local-lvm"

    ip_config {
      ipv4 {
        address = var.llm_ipv4_address
        gateway = var.llm_ipv4_gateway
      }
    }

    dns {
      servers = var.llm_dns_servers
    }

    user_account {
      username = "dev"
      keys     = var.llm_ssh_public_keys
      # No password attribute: keys only. A password here would land in state,
      # and state lives unencrypted on the dev VM.
    }
  }

  agent {
    # Was OFF at create, on purpose: Ubuntu's cloud image does not ship
    # qemu-guest-agent, and with `enabled = true` the provider waits for an
    # agent that cannot answer until the timeout expires.
    #
    # ON since 2026-09-16, once C3 installed the package in the guest. Ubuntu
    # only starts the agent when the virtio-serial channel exists, and this is
    # what creates it -- so enabling it here is what turns the installed agent
    # from `inactive` to running, via the reboot the provider performs
    # (`reboot_after_update`). That reboot resets the GPU; safe since pci=noats
    # (GPU-VM.md C2a).
    enabled = true
  }
}
