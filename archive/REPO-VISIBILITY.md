# Repository visibility — history

> 📦 **Archived 2026-09-21.** Why `lambo-n/homelab` is public and what was
> checked before that was confirmed. Current state: [`../AGENTS.md`](../AGENTS.md).

## 2026-09-21 — confirmed public

Until that day, several documents called the repo private. One decision
depended on that belief: `platformAutomerge` was left off because branch
protection was thought unavailable on a private repo, and that cost PR #15
nine days (`GITOPS.md` → Renovate). `gh repo view` showed `PUBLIC`.

The owner decided to keep it public. Before recording that, the full history
(`git log --all`) was scanned. Only counts and paths were printed, never the
matched text:

| Check | Result |
|---|---|
| `AGE-SECRET-KEY-1`, `BEGIN … PRIVATE KEY` | 0 commits |
| GitHub (`ghp_`, `github_pat_`), AWS (`AKIA…`), Slack (`xox?-`) tokens | 0 commits |
| Proxmox `PVEAPIToken=…=<uuid>`, k3s join token (`K…::server:`) | 0 commits |
| Every `kind: Secret` manifest in any revision | all 13 paths SOPS-encrypted in every revision |
| `esphome/secrets.sops.yaml` | SOPS-encrypted in every revision |

What is public, and accepted as such: the topology (IPs, hostnames, ports,
firewall rules, where each credential lives) and the SOPS ciphertext. The
ciphertext can be attacked offline forever by anyone who has cloned the repo,
which is acceptable only as long as `age.key` never leaks. If it ever does,
rotating the key is not enough: every value encrypted to it must be rotated too.
