provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  # The PVE web certificate is self-signed. This is a LAN-local API call to a
  # host that is already the storage and hypervisor for everything here, so the
  # trust boundary is not meaningfully widened -- but it is a deliberate choice,
  # not a default.
  insecure = true
}
