# Homelab

GitOps source of truth for the **Sunfire** k3s cluster (Proxmox `192.168.50.101`).

Planning notes, rationale, and the phased TODO live in [`GITOPS.md`](GITOPS.md).
This repo is the *executable* half of that plan.

Three runbooks cover the parts that cannot be reconciled from inside the cluster:
[`STORAGE.md`](STORAGE.md) (the PGDATA zvol and worker disk growth, on the
Proxmox host), [`SANOID.md`](SANOID.md) (ZFS snapshots, same host) and
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
kubernetes/apps/reloader/         restarts workloads when their Secrets change
kubernetes/apps/observability/
  ├── kube-prometheus-stack/ Prometheus, Alertmanager, Grafana, exporters
  └── flux-monitoring/       PodMonitors, Flux alerts, Flux dashboards
kubernetes/apps/sunfire/
  ├── namespace.yaml
  ├── storage/       PV + PVC on NFS archive-pool  (prune permanently disabled)
  ├── minio/         S3 object storage             → minio-api.sunosrs.cc
  ├── postgres/      PostgreSQL 16                 (rollback path, still running)
  ├── postgres-cnpg/ CNPG Cluster + ObjectStore    (live since 2026-09-04)
  ├── postgrest/     REST over Postgres            → db.sunosrs.cc
  └── cloudflared/   locally-managed tunnel        (routing in configmap.yaml)
```

`postgres-cnpg/` went live 2026-09-04 and **is now the database PostgREST reads**.
Its PGDATA sits on a 64 GiB zvol on `archive-pool`, mounted at
`/var/lib/rancher/k3s/storage` on `k3s-worker2`; it archives WAL continuously plus
a daily base backup into MinIO, and a full restore drill (`RESTORE.md`) passed
before the cutover. The old `postgres` Deployment is still running as the rollback
path.

Each app is `ks.yaml` (a Flux `Kustomization`) + `app/` (the plain manifests).
Ordering is expressed with `dependsOn`:

```
storage ─┬─ minio ──────┬─ cloudflared
         └─ postgres ── postgrest ─┘

cert-manager ──────┬─ plugin-barman-cloud
cloudnative-pg ────┘

kube-prometheus-stack ── flux-monitoring
```

`reloader` and `kube-prometheus-stack` deliberately have no `dependsOn` at all:
nothing in the cluster depends on either, so neither can wedge the sunfire or
cnpg graphs. `flux-monitoring` depends on the stack only because `PodMonitor`
and `PrometheusRule` do not exist as kinds until its CRDs are registered.

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

**Phase 5 (data protection) is complete as of 2026-09-04.** cert-manager, the
CNPG operator and `plugin-barman-cloud` are installed; PostgreSQL runs as a CNPG
`Cluster` with PGDATA on a 64 GiB zvol on `archive-pool`; WAL is archived
continuously and a base backup runs daily into MinIO; `sanoid` snapshots all
three ZFS datasets on `.101`.

Two things were tested rather than assumed, which is the point of the phase:

- **Restore drill** (`RESTORE.md`) — recovered into a scratch namespace in 56s,
  row counts matched exactly, `authenticator`'s SCRAM hash fingerprint was
  identical to the source, and PITR landed *between* two marker writes rather
  than merely somewhere after the base backup. The drill wrote nothing to the
  backup bucket and left no orphans.
- **Snapshot rollback** (`SANOID.md` §4) — both clone tests passed. The zvol
  clone returned the same filesystem UUID it was created with, and the
  `minio-data` clone contained the Postgres backups as well as the guide media.

PostgREST was cut over to `postgres-cnpg-rw` afterwards, verified end to end
(`HTTP 206`, `Content-Range: 0-0/57`; `401` anonymous). **No Cloudflare Worker
change was needed** — `PGRST_DB_URI` is cluster-only, and the JWT signing key,
`POSTGREST_URL`, the Access service token and every `MINIO_*` value were
untouched.

> ⚠️ Phase 5 retired an invariant repeated across these docs: *"no VM disk is on
> ZFS, so `archive-pool` can be destroyed without touching a VM."* Now that the
> zvol exists, destroying or rebuilding that pool takes `k3s-worker2`'s database
> disk with it, and pool work needs the VM stopped first.

**Phase 6 is mostly done.** The cloudflared tunnel is now **locally managed**:
ingress routing lives in a ConfigMap reconciled by Flux, the credentials are
SOPS-encrypted, and the edge serves no ingress map at all. That required
swapping to a new tunnel (`sunfire-local`), because `config_src` is immutable
after creation — the old one is retained, `down`, as the rollback path. DNS for
both hostnames is managed in `tofu/`, applied by hand from this VM.

Reloader is deployed and proven — a Secret change now restarts the workloads
that reference it, which the CNPG cutover showed was a correctness gap rather
than a convenience.

The MinIO CORS Transform Rule turned out to be **vestigial**: no browser ever
addresses `minio-api.sunosrs.cc` — guide images are served same-origin by the
Worker, which is the only S3 client. Delete the rule in the dashboard; nothing
about it belongs in `tofu/`.

**Phase 6 is closed.** All five Proxmox guests are in OpenTofu state — four VMs
and the `tailscale-gateway` LXC — each body generated from the live guest and
reviewed rather than hand-written, each carrying `prevent_destroy`. The plan is
clean.

Getting there turned up one thing worth knowing before repeating it:
`PVEAuditor` cannot import a QEMU guest. The provider re-resolves every disk
through a storage endpoint that PVE gates on `VM.Config.Disk` — a *write*
privilege — even though the same disk string is already readable in the VM
config. It was granted as a one-privilege `TofuDisk` role stacked on
`PVEAuditor` for the generation and revoked immediately after; `VM.Allocate` was
never granted at all, so replacing a guest was never something the token could
do. `tofu/README.md` has the detail.

**Phase 7 (observability) is complete as of 2026-09-04**, which closes the last
entry in the `GITOPS.md` "Known gaps" list. kube-prometheus-stack runs in an
`observability` namespace with 26/26 targets up and 222/222 rules healthy.
Grafana is LAN-only at `grafana.homelab.lan` through the existing Traefik
LoadBalancer — add `192.168.50.104  grafana.homelab.lan` to `/etc/hosts`, and
read the admin password with `sops --decrypt
kubernetes/apps/observability/kube-prometheus-stack/app/grafana-admin.sops.yaml`.

Alerting is **in-cluster only, deliberately**. Alertmanager keeps the chart's
`null` receiver: alerts fire and are visible, nothing is pushed. This cluster is
powered on and off by hand, so a webhook would deliver a storm on every power
cycle. Add a receiver the day it is expected to stay up.

Flux reconcile-failure alerting runs on two paths that fail in opposite
directions — notification-controller pushing error *events* into Alertmanager,
and a `PrometheusRule` pulling resource *state*. It was verified by breaking a
Kustomization on purpose and watching the alert arrive, which is how two silent
faults surfaced: the `gotk_reconcile_condition` metric that every Flux alerting
guide is built on no longer exists in v2.9 (a rule over an absent metric reads
as healthy), and k3s serves the apiserver's metrics on the kubelet endpoint, so
43% of the TSDB was the control plane stored twice. Both are written up under
`GITOPS.md` Phase 7.

The legacy `postgres` Deployment was **scaled to zero on 2026-09-04** — the
reversible half of retiring it. Object, Service and PVC are all kept, so rolling
back is `replicas: 1` plus flipping `PGRST_DB_URI`. Note that the CNPG Cluster's
bootstrap still names that Service as an import source; it is read once at
creation and never again, but recreating the Cluster from git would run it
against a zero-replica source.

Deliberately still open, with reasoning in `GITOPS.md`: deleting the legacy
`postgres` Deployment and its NFS PV/PVC, VolSync is deferred for want of a
destination that is not the source pool, pinning `sanoid` in host config waits
for that layer to exist, and there is no log aggregation — Loki needs its own
storage answer before the third Flux dashboard is worth deploying.
