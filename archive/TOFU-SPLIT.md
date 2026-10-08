# OpenTofu root split

> 📦 **Archived 2026-10-08.** How the single OpenTofu root became two. Current
> state: [../tofu/README.md](../tofu/README.md) → *Layout*, and
> [../GITOPS.md](../GITOPS.md#opentofu).

## 2026-10-08 — one root, two providers, split in two

**Why.** The Cloudflare and Proxmox providers shared one root and one state, so a
Proxmox-only plan also refreshed the two DNS records and failed with
`9106 Missing X-Auth-Key` without a Cloudflare token. `-refresh=false` was the
workaround, which also turned off drift detection for everything.

**What was done.**
- Files moved with `git mv` into `tofu/cloudflare/` and `tofu/proxmox/`;
  `providers.tf`, `variables.tf`, `versions.tf` and the lock file were divided by
  provider.
- State moved with `tofu state mv -state=… -state-out=…`, one resource at a
  time: 2 to `cloudflare/`, 7 to `proxmox/`. The pre-split state file was copied
  to `terraform.tfstate.pre-split` first (gitignored).

**Checks.**
- `cloudflare/`: a full-refresh plan against the live API showed no drift beyond
  `include_shadow_metadata = false`, a client-side attribute the 5.27 provider
  added. It was applied once; the next plan said "No changes", and both
  hostnames still resolved to Cloudflare edge addresses.
- `proxmox/`: `tofu plan -refresh=false` said "No changes" for all seven
  resources. No full refresh was run, since the read-only token cannot refresh the
  four imported VMs.

**Left as it was.** `-refresh=false` remains the everyday Proxmox command, for
the `VM.Config.Disk` reason in `tofu/README.md`, not for the old Cloudflare one.
