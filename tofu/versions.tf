# Toolchain and providers, pinned. `opentofu` itself is pinned in ../mise.toml.
#
# State lives on this VM and is NOT in git (see .gitignore). Applies are run by
# hand from here, never reconciled from inside the cluster -- that separation is
# the whole point of GITOPS.md's rejection of Crossplane/tofu-controller: a
# reconciler that can delete the VMs it runs on is a circular dependency on a
# single host.
terraform {
  required_version = "~> 1.12"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.24"
    }
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.113"
    }
  }
}
