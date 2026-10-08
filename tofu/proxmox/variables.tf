variable "proxmox_endpoint" {
  description = "Proxmox API endpoint. Port 8006 is reachable from this VM; 2049/111 are not."
  type        = string
  default     = "https://192.168.50.101:8006/"
}

variable "proxmox_api_token" {
  description = <<-EOT
    Proxmox API token, formatted user@realm!tokenid=uuid. Separate from the
    Cloudflare token and independently obtainable.

    Same advice: leave null and export PROXMOX_VE_API_TOKEN.
  EOT
  type        = string
  sensitive   = true
  default     = null
}

# --- VM 105, the GPU/LLM guest (proxmox-llm-vm.tf, ../GPU-VM.md) ---

variable "llm_ssh_public_keys" {
  description = <<-EOT
    SSH public keys for the `dev` account on VM 105, seeded by cloud-init.
    There is no password on that account, so an empty list makes the guest
    unreachable over SSH -- the Proxmox console would be the only way in.

    No default deliberately: this VM does not exist yet, and no key on this
    workstation is the right one to bake in. `~/.ssh/flux-homelab-deploy` is
    Flux's deploy key and must not be reused for host login.
  EOT
  type        = list(string)
}

variable "llm_ipv4_address" {
  description = <<-EOT
    CIDR address for VM 105. `.107` was reserved for the TrueNAS guest that was
    never created (homelab/archive/TRUENAS.md), so it is free; guests run .102-.106 today.
    Confirm nothing outside this repo answers on it before applying.
  EOT
  type        = string
  default     = "192.168.50.107/24"
}

variable "llm_ipv4_gateway" {
  description = <<-EOT
    Default gateway for VM 105. Verified 2026-09-16: `ip route show default` on
    the dev VM (.103) reports `default via 192.168.50.1 dev ens18 proto static`,
    and the owner confirmed it. Every guest sits on the same flat 192.168.50.0/24.
  EOT
  type        = string
  default     = "192.168.50.1"
}

variable "llm_dns_servers" {
  description = "Resolvers for VM 105. Defaults to the gateway; switch to the tailnet resolver if that is preferred."
  type        = list(string)
  default     = ["192.168.50.1"]
}

variable "ubuntu_noble_image_sha256" {
  description = <<-EOT
    SHA256 of noble-server-cloudimg-amd64.img, from
    https://cloud-images.ubuntu.com/noble/current/SHA256SUMS

    Required, with no default: Ubuntu rewrites `current/` in place on every
    respin, so a missing checksum means importing whatever happens to be there
    on the day. Re-read it if the download resource ever replaces itself.
  EOT
  type        = string
}
