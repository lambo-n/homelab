# Homelab

GitOps source of truth for the **Sunfire** k3s cluster (Proxmox `192.168.50.101`).

Planning notes, rationale, and the phased TODO live in [`GITOPS.md`](GITOPS.md).
This repo is the *executable* half of that plan.

Two runbooks cover the parts that cannot be reconciled from inside the cluster:
[`SANOID.md`](SANOID.md) (ZFS snapshots, on the Proxmox host) and
[`RESTORE.md`](RESTORE.md) (the CNPG restore drill).

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
bootstrap/flux/flux-instance.yaml   flux-operator FluxInstance
kubernetes/flux/cluster/            root sync target
kubernetes/apps/cert-manager/       cert-manager   (exists only for the barman plugin)
kubernetes/apps/cnpg-system/
  ├── cloudnative-pg/      CNPG operator
  └── plugin-barman-cloud/ Barman Cloud CNPG-I plugin (must share the operator's namespace)
kubernetes/apps/sunfire/
  ├── namespace.yaml
  ├── storage/       PV + PVC on NFS archive-pool  (prune permanently disabled)
  ├── minio/         S3 object storage             → minio-api.sunosrs.cc
  ├── postgres/      PostgreSQL 16                 (the live database)
  ├── postgres-cnpg/ CNPG Cluster + ObjectStore    (Phase 5, NOT yet wired in)
  ├── postgrest/     REST over Postgres            → db.sunosrs.cc
  └── cloudflared/   remote-managed tunnel
```

`postgres-cnpg/` is written and validated but is deliberately absent from
`kubernetes/apps/sunfire/kustomization.yaml`, so Flux does not see it. It stays
out until the two blockers in `GITOPS.md` Phase 5 clear — the backup bucket does
not exist yet, and the worker root disks are too small for the PGDATA it asks
for.

Each app is `ks.yaml` (a Flux `Kustomization`) + `app/` (the plain manifests).
Ordering is expressed with `dependsOn`:

```
storage ─┬─ minio ──────┬─ cloudflared
         └─ postgres ── postgrest ─┘

cert-manager ──────┬─ plugin-barman-cloud
cloudnative-pg ────┘
```

The two graphs are independent today. They join in Phase 5, when the `sunfire`
Postgres becomes a CNPG `Cluster` backed up by the plugin.

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

**`age.key` is backed up in LastPass** (secure note — human login from any device).
It is deliberately *not* in Infisical: a machine credential used to fetch it would
die with the VM it is stored on, which is precisely the disaster being insured
against. Without this key every secret here is unreadable.

**Never `cat` this file**, including to display it for backup — that puts it in
shell history and agent transcripts. The user copies it out themselves.

## Two secret systems

| Class | Keys | Home |
|---|---|---|
| Cluster-only | MinIO root, `POSTGRES_PASSWORD`, `PGRST_DB_URI`, tunnel token | **SOPS**, in this repo |
| Cross-boundary | `PGRST_JWT_SECRET`, 4× scoped MinIO Worker keys | **Infisical** (system of record) |

Cross-boundary keys must stay byte-identical across the cluster and two Cloudflare
Worker environments; they were synced by hand until Infisical. Cluster-only keys
stay in git so a cold boot needs no network — this cluster is often powered off.

Rationale and the migration checklist: `GITOPS.md` "Secrets: hybrid" and "Phase 2b".

## Unified media store

Production, feature and local dev share the `sunfire-guide-media` bucket and the
`public` Postgres schema — no `sunfire-guide-media-feature`, no `sunfire_feature`.
Two MinIO service accounts remain against the same policy and bucket, only so a
feature/local key can be revoked without rotating production.

**Applied to the live cluster 2026-09-02** and functionally verified: the
feature credential does PutObject / GetObject / DeleteObject against
`sunfire-guide-media`, PostgREST reports one relation instead of two, and both
the feature bucket and the `sunfire_feature` schema are gone. The `postgrest`
manifest here matches (`PGRST_DB_SCHEMAS=public`).

Versioning is enabled on the shared bucket — feature and local dev hold
`s3:DeleteObject` on the only copy of every guide image and Phase 5 backups do
not exist yet.

Procedure (kept for a cluster rebuild) and the container gotchas that bite when
running it: `sunfire/homelab/RUNBOOK.md` → "Unified media store — cluster
conversion". Rationale: `GITOPS.md` → "Unified media store".

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

Phases 1–4 complete (toolchain, pinning, repo, SOPS, Flux, Renovate); **Phase 5
— data protection — is in progress.** **This repo now drives the cluster.** `flux-operator` 0.59.0 runs the four controllers in `flux-system`,
syncing `kubernetes/flux/cluster` over SSH with a read-only deploy key; all six
Kustomizations reconcile Ready.

Adoption rolled the four Deployments off `:latest` onto the digest pins above,
including the `postgres` 16 → 16.15 patch upgrade. The NFS PVs were adopted in
place, not recreated. `~/sunfire-backend/` remains the rollback path.

`prune: true` on the four app Kustomizations as of 2026-09-03; `sunfire-storage`
stays `false` permanently. `namespace.yaml` and the PV/PVCs carry
`kustomize.toolkit.fluxcd.io/prune: disabled`. Removing a manifest from git now
deletes the live object.

Renovate runs daily at 10:00 UTC against `home-operations/renovate-presets`
(`.renovaterc.json5`), with `**/*.sops.*` excluded from scanning.

**Phase 5 (data protection) is where the work is.** cert-manager, the CNPG
operator and `plugin-barman-cloud` are installed and Ready. What remains is
blocked on three things that only a human can do, in this order:

1. **Grow the `k3s-worker*` VM disks on `.101`.** Each node has a 9.75 GiB root
   filesystem with ~2.7 GiB free, and the CNPG `Cluster` wants 20Gi of
   `local-path` on `k3s-worker2`. `local-path` provisions a directory rather
   than a quota, so that PVC would bind and then fill the node's OS disk.
2. **Run `scripts/minio-barman-account.sh`** — creates the backup bucket and a
   scoped service account, writing the credential into the repo already
   SOPS-encrypted. It needs `kubectl exec`, which the assistant's tooling
   refuses.
3. **Run `SANOID.md`** on `.101` in full, then the restore drill in
   `RESTORE.md`. Both are written; neither has been executed.

Only after 1 and 2 does `postgres-cnpg/ks.yaml` get added to
`kubernetes/apps/sunfire/kustomization.yaml`. Rationale, measurements and the
VolSync deferral: `GITOPS.md` Phase 5.
