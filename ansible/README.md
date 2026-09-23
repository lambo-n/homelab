# ansible/

The PVE host-config layer named in `GITOPS.md` → "Scope: Flux manages the
cluster, not the hypervisor": ZFS-adjacent host packages and config on
`192.168.50.101` that are not Kubernetes objects and not a Proxmox guest, so
neither Flux nor OpenTofu reconciles them.

**Applies are run by hand from the dev VM, never automatically.** Same model
as `tofu/`: edit a file here, run one command, the command makes `.101`
match it. Nothing polls git and applies on its own — no cron, no AWX/Tower.

## Connecting to `.101`

A dedicated key, `~/.ssh/id_ed25519_pve-hostconfig`, authenticates as root via
the `pve-hostconfig` alias in `~/.ssh/config` (per-machine, gitignored, not in
this repo). Kept separate from `id_ed25519_homelab` (the k3s/llm guests) since
`.101` is a materially more sensitive target. `inventory.ini` references the
alias by name only — no host, user, or key path is committed here.

## Running it

```bash
cd ~/homelab/ansible
ansible-playbook site.yml --check --diff   # review first, like `tofu plan`
ansible-playbook site.yml --diff           # apply
```

A `--check` run that proposes changes to `sanoid.conf` means the live file on
`.101` has drifted from what's in git — resolve that before applying anything.
An apply should be followed by a second `--check --diff`, which must report no
changes; that is the idempotency proof, not the first run.

## What's here

- `roles/sanoid/` — installs the `sanoid` package, renders
  `/etc/sanoid/sanoid.conf` from the config documented in `../SANOID.md`
  (tabs, not spaces — sanoid's parser silently ignores space-indented keys),
  and enables `sanoid.timer`.
