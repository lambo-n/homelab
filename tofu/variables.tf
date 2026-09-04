variable "cloudflare_api_token" {
  description = <<-EOT
    Cloudflare API token. NOT the wrangler OAuth token, NOT an Access service
    token, NOT the tunnel token -- none of those can manage configuration.
    Required scopes are listed in README.md.
  EOT
  type        = string
  sensitive   = true
}

variable "cloudflare_account_id" {
  description = "Cloudflare account ID (the Sunfire account)."
  type        = string
  default     = "1b0e61d1024b78dd4bf289271823192f"
}

variable "cloudflare_zone_id" {
  description = "Zone ID for sunosrs.cc. Look up once the token exists; there is no way to read it without one."
  type        = string
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
  description = "Proxmox API token, formatted user@realm!tokenid=uuid. Separate from the Cloudflare token and independently obtainable."
  type        = string
  sensitive   = true
  default     = ""
}
