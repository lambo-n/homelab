# OpenTofu findings — first apply, privsep, and drift

> 📦 **Archived 2026-10-05.** Dated narrative from bringing `tofu/` into use.
> Current state: [../tofu/README.md](../tofu/README.md).

## 2026-09-04 — first Cloudflare apply

> Moved from `README.md` → *Proxmox* in the 2026-10-05 docs pass, as it stood.

> **Applied 2026-09-04. State is real.** `serial: 4`, two managed resources —
> `cloudflare_dns_record.minio_api` and `cloudflare_dns_record.db`. Both were
> imported from the live zone rather than created, and the apply that moved
> `var.tunnel_id` to `1ac59ce2-15bb-46df-967f-caa8b05881f7` is what cut live
> traffic onto the locally-managed tunnel.
>
> **Only Proxmox is left**, and it needs a token this operator can issue
> themselves. Skip to "Proxmox" at the bottom.

## 2026-09-04 — the import token started as --privsep 0

> Moved from `README.md` → *Proxmox* in the 2026-10-05 docs pass, as it stood.

`--privsep 0` makes the token inherit the user's privileges — which were
auditor-only at the time, so this was not a widening.

## 2026-09-16 — `!import` switched to --privsep 1 before the user was widened

> Moved from `README.md` → *Proxmox* in the 2026-10-05 docs pass, as it stood.

> 🔴 **That stopped being safe on 2026-09-16.** `tofu@pve` has to gain write
> roles on `/vms/105` and the storages for the `!llm` token to work at all — a
> privsep token's rights are the **intersection** of its own ACLs and its user's,
> so a token cannot exceed its user ([`../archive/GPU-VM-BUILD.md`](GPU-VM-BUILD.md) §A5). With
> `--privsep 0`, `!import` would inherit every one of those write roles and stop
> being read-only. ✅ **Done 2026-09-16** — switched to `--privsep 1` with its own
> `PVEAuditor` grant at `/`, *before* the user was widened:
>
> ```bash
> pveum user token modify tofu@pve import --privsep 1
> pveum acl modify / --tokens 'tofu@pve!import' --roles PVEAuditor
> pveum user permissions 'tofu@pve!import' --path /vms/105   # audit only
> ```
>
> Verified afterwards: that last command returns the seven auditor privileges
> only, although `tofu@pve` itself now holds `TofuVM` on `/vms/105`. Switching
> the flag does **not** regenerate the secret, so the LastPass copy stays valid.
