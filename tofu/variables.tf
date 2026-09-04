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

    Currently the original remotely-managed tunnel. After
    scripts/cloudflared-new-local-tunnel.sh has created the locally-managed
    replacement and the cluster is running its credentials, set this to the new
    id and apply -- that is the moment routing changes hands.
  EOT
  type        = string
  # Cut over 2026-09-04 from b42c20c1-2d20-43ee-a17c-15f9849e5f13 (the original
  # remotely-managed tunnel, kept alive as the rollback path) to the
  # locally-managed replacement created by
  # scripts/cloudflared-new-local-tunnel.sh.
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
