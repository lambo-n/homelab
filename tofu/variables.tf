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
  description = "Existing cloudflared tunnel. Unchanged by the local-management conversion."
  type        = string
  default     = "b42c20c1-2d20-43ee-a17c-15f9849e5f13"
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
