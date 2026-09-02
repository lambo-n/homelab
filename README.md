# homelab

GitOps source of truth for the **Sunfire** k3s cluster (Proxmox `192.168.50.101`).

Planning notes, rationale, and the phased TODO live in [`~/GITOPS.md`](../GITOPS.md)
on the dev VM. This repo is the *executable* half of that plan.

## Repository boundaries

Three trees on the dev VM, deliberately kept separate:

| Path | What it is | Git |
|---|---|---|
| `~/homelab/` | **This repo.** Cluster desired state. | `lambo-n/homelab` (private) |
| `~/sunfire/` | The consuming app (`Sunfire-Team/sunfire`), cloned **for model context only** | `Sunfire-Team/sunfire` |
| `~/sunfire-backend/` | Pre-GitOps hand-applied manifests + **plaintext** live secrets | untracked, `chmod 600` |

`~/sunfire/` is a separate clone and is **never** nested inside this repo — it is
read-only context describing how the app consumes MinIO and PostgREST. Nothing
here should ever be committed there, and no plaintext secret may be committed to
either. Do not `git init` in `/home/dev` itself; that would swallow `~/sunfire/`,
`~/.ssh`, and `~/.claude.json`.

`~/sunfire-backend/` remains the plaintext origin of the secrets encrypted here.
It is superseded once Flux reconciles, but is kept until then as the rollback path.

## Layout

```
bootstrap/flux/flux-instance.yaml   flux-operator FluxInstance (Phase 3, not yet applied)
kubernetes/flux/cluster/            root sync target
kubernetes/apps/sunfire/
  ├── namespace.yaml
  ├── storage/     PV + PVC on NFS archive-pool  (prune permanently disabled)
  ├── minio/       S3 object storage             → minio-api.sunosrs.cc
  ├── postgres/    PostgreSQL 16
  ├── postgrest/   REST over Postgres            → db.sunosrs.cc
  └── cloudflared/ remote-managed tunnel
```

Each app is `ks.yaml` (a Flux `Kustomization`) + `app/` (the plain manifests).
Ordering is expressed with `dependsOn`:

```
storage ─┬─ minio ──────┬─ cloudflared
         └─ postgres ── postgrest ─┘
```

## Secrets

SOPS + age. **Only `*.sops.yaml` may exist in this repo**; `.gitignore` refuses a
bare `secret.yaml` outright so a plaintext file cannot be staged by accident.

- Private key: `./age.key` (gitignored, `chmod 600`) — and in-cluster as the
  `sops-age` Secret in `flux-system`.
- Public recipient is in `.sops.yaml` and is safe to commit.
- `encrypted_regex: ^(data|stringData)$` — only payloads are encrypted, so
  resource metadata stays reviewable in diffs.

```bash
sops kubernetes/apps/sunfire/postgres/app/secret.sops.yaml          # edit in place
sops --decrypt <file>                                               # read
sops --encrypt --filename-override <dest>.sops.yaml <src> > <dest>  # encrypt new
```

> The `--filename-override` flag is required when the source file lives outside
> this repo — SOPS matches `creation_rules` against the *input* path.

**Back up `age.key` off this VM.** Without it, every secret here is unreadable.

## Toolchain

`mise.toml` pins everything; `kubectl` tracks the k3s server minor (v1.35.x).

```bash
mise install     # or: mise trust && mise install
```

`[env]` binds `KUBECONFIG` to `./kubeconfig` (a gitignored symlink to
`~/.kube/config`) and `SOPS_AGE_KEY_FILE` to `./age.key`, so `sops` finds the
key with no flags anywhere under this directory.

`~/.bashrc` puts `~/.local/share/mise/shims` on `PATH` **above** the
"if not running interactively, don't do anything" guard. That placement is
deliberate: without it, a non-interactive `bash -c kubectl ...` — which is how
scripts and agents invoke it — falls through to the stale system
`/usr/bin/kubectl` v1.30 and hits the version-skew error. The same block is
mirrored in `~/.profile` for login shells.

## Images

All four are pinned `tag@sha256:digest`, resolved from the digests **actually
running** at migration time, so adoption does not silently upgrade anything.
Renovate proposes bumps; nothing floats.

| Workload | Pin | vs. running |
|---|---|---|
| cloudflared | `2026.8.3` | identical digest |
| minio | `RELEASE.2025-09-07T16-13-09Z` | identical digest |
| postgrest | `v16.2` | identical digest |
| postgres | `16.15` | **patch upgrade** — running pod is an older, now-untagged 16.x |

## Status

Phases 1–2 complete (toolchain, pinning, repo, SOPS). **Flux is not installed and
nothing in this repo has been applied to the cluster.** The four Deployments are
still hand-applied from `~/sunfire-backend/`.

`kubectl diff` against the live cluster shows exactly two intended deltas: the
image pins above, and `kustomize.toolkit.fluxcd.io/prune: disabled` on the PV/PVCs.

Next: Phase 3 in `GITOPS.md` — install `flux-operator`, add a deploy key for this
private repo, reconcile with `prune: false`, confirm adoption.
