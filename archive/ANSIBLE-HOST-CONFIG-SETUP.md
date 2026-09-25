# Ansible host-config layer — setup, and reversing the no-SSH-key rule

> 📦 **Archived 2026-09-23.** How the PVE host-config layer named in
> `GITOPS.md` → "Scope: Flux manages the cluster, not the hypervisor" went
> from prose-only (`SANOID.md`) to an actual reconciled-by-hand layer, and why
> that required giving the dev VM its first SSH key onto `.101`. Current
> state: [`../ansible/README.md`](../ansible/README.md),
> [`../SANOID.md`](../SANOID.md).

## Why the no-SSH-key rule changed

`.101` never accepted an SSH key from the dev VM, by deliberate design — `zfs`,
`qm`, `pveum` and sanoid config all stayed console-only, hand-run commands.
That held as long as host config was *described* in git (`SANOID.md`'s prose)
rather than *applied from* git.

Once the decision was made to actually reconcile `sanoid.conf` from a file in
this repo — the same manual-apply shape as `tofu apply`, never automatic —
the rule stopped fitting: something has to be able to reach `.101` to apply
it, and that had to be the dev VM, since that's where every other tool in
this repo runs from.

## What was considered

Two options for the account the new key authenticates as:

| Option | Verdict |
|---|---|
| Root, directly | **Chosen.** Matches how every other host-level task on `.101` already works (the owner logs in as root for `zfs`/`qm`/`pveum`) — no new operational model to maintain. |
| Dedicated `ansible` user, sudoers-scoped to just the sanoid tasks | Rejected for now — smaller blast radius if the key leaks, but real scaffolding (a new user, a sudoers file to keep in sync as the role grows) for a single-host, manually-triggered layer. Revisit if the Ansible layer's scope grows past sanoid. |

The key (`id_ed25519_pve-hostconfig`) is unrestricted root once connected —
the same shell access `zfs`/`qm`/`pveum` already assume, not narrowed to
Ansible's own commands. Its `from="192.168.50.103"` restriction limits *where*
it can be used from, not *what* it can run.

## Setup

1. `ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_pve-hostconfig -N ""` on the dev
   VM — a key dedicated to this boundary, kept separate from
   `id_ed25519_homelab` (the k3s/llm guests) and `flux-homelab-deploy` (Flux's
   own deploy key).
2. `~/.ssh/config` got a `pve-hostconfig` Host block, direct — no `ProxyJump`,
   since the dev VM is already on the same LAN as `.101`.
3. The owner appended the public half to `/root/.ssh/authorized_keys` on
   `.101`, restricted with `from="192.168.50.103"` — the same pattern already
   used for `id_ed25519_homelab` on the guest VMs.
4. `ansible-core` pinned in `mise.toml` via the `pipx` backend (the same
   mechanism already used for `esphome`).
5. `ansible/` scaffolded: `inventory.ini` names the `pve-hostconfig` SSH
   alias only — no host, user, or key path committed, since those stay in the
   gitignored `~/.ssh/config`. `roles/sanoid/` installs the package, renders
   `sanoid.conf` from a Jinja template transcribed from what `SANOID.md`
   documented, and enables `sanoid.timer`.

## Verification (2026-09-22)

The role was written against a host that already had sanoid installed and
configured by hand (`SANOID-SETUP.md`), so the meaningful test was
idempotency, not "did it install something":

| Check | Result |
|---|---|
| `ansible proxmox -m ping` | `pong` |
| `ansible-playbook site.yml --check --diff` (before) | `changed=0` |
| `ansible-playbook site.yml --diff` (real apply) | `changed=0` |
| `ansible-playbook site.yml --check --diff` (after) | `changed=0` |
| `systemctl is-active sanoid.timer` | `active` |
| `zfs list -t snapshot -r archive-pool` | 132 snapshots, most recent hourly one from the same day — timer undisturbed |

Zero diff on every run means the Jinja-rendered config was already
byte-identical to what was live — the layer now *owns* config that already
matched, rather than having changed anything.

One environment quirk hit along the way, worth recording since it'll recur:
`ansible`/`ansible-playbook` refuse to run with `ERROR: Ansible requires
blocking IO on stdin/stdout/stderr` when invoked directly in the dev VM's
assistant shell (non-blocking stdout/stderr there, unrelated to Ansible or
`.101`). Redirecting output to a file and reading it back
(`cmd > file 2>&1; cat file`) works around it.

## What's still open

`~/homelab/ssh-config` (a *different*, gitignored file at the repo root,
distinct from `~/.ssh/config`) has an unused `proxmox-host` entry that
`ProxyJump`s through `tailscale-gateway` to `.101`, using a key
(`~/.ssh/id_ed25519`) that doesn't exist on the dev VM. It predates this work
and looks like a leftover draft from a different, never-adopted approach —
reaching `.101` from an external laptop over Tailscale, rather than directly
from the dev VM over the LAN. Not touched here; worth a decision from the
owner about whether to clean it up or finish it.
