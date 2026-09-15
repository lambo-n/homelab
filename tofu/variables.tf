variable "cloudflare_api_token" {
  description = <<-EOT
    Cloudflare API token. NOT the wrangler OAuth token, NOT an Access service
    token, NOT the tunnel token -- none of those can manage configuration.
    Required scopes are in README.md.

    Leave this null and export CLOUDFLARE_API_TOKEN instead: the provider reads
    that natively, and the token then never lands on disk in terraform.tfvars.
    Set it here only if you have a reason to.
  EOT
  type        = string
  sensitive   = true
  default     = null
}

variable "cloudflare_account_id" {
  description = "Cloudflare account ID (the Sunfire account)."
  type        = string
  default     = "1b0e61d1024b78dd4bf289271823192f"
}

variable "cloudflare_zone_id" {
  description = "Zone ID for sunosrs.cc. Not secret; resolved 2026-09-04 once the token existed."
  type        = string
  default     = "23f3b72210cb478de18c5a8c4b75ae90"
}

variable "tunnel_id" {
  description = <<-EOT
    The tunnel both CNAMEs point at. THIS VALUE IS THE CUTOVER: changing it and
    applying moves live traffic from one tunnel to the other, because the DNS
    records' content is derived from it.

    Currently `sunfire-local`, the locally-managed tunnel created by
    scripts/cloudflared-new-local-tunnel.sh and cut over 2026-09-04.

    To move to another tunnel: create it, get its credentials into the cluster
    (SOPS -> Flux -> Reloader restarts the connector), and only then change this
    value and apply. Doing it in the other order points DNS at a tunnel with no
    connector on it.
  EOT
  type        = string
  # Cut over 2026-09-04 from b42c20c1-2d20-43ee-a17c-15f9849e5f13, the original
  # remotely-managed tunnel. That one was kept as the rollback path until the
  # Worker had verified upload/fetch/delete through the new one, then deleted --
  # so this id is no longer a two-way switch, it is the only tunnel that exists.
  default = "1ac59ce2-15bb-46df-967f-caa8b05881f7"
}

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
    never created (TRUENAS.md), so it is free; guests run .102-.106 today.
    Confirm nothing outside this repo answers on it before applying.
  EOT
  type        = string
  default     = "192.168.50.107/24"
}

variable "llm_ipv4_gateway" {
  description = "Default gateway for VM 105. Unverified in this repo -- check the router before the first apply."
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
