# GitOps migration — history

> 📦 **Archived 2026-09-16.** The homelab was moved to GitOps in seven phases
> between 2026-09-02 and 2026-09-04. All seven are complete. This is the
> timeline; the findings each phase produced now live in
> [`../GITOPS.md`](../GITOPS.md)'s per-tool sections, which is where a
> "see GITOPS.md Phase N" reference elsewhere in this repo should be read as
> pointing.

These headings are kept because other documents link to them by number —
`archive/STORAGE.md`, `SANOID.md`, `runbooks/RESTORE.md`, `tofu/README.md` and
three files in the separate `~/sunfire/` repo all say *"see GITOPS.md Phase
N"*.

## Phase 1 — Prerequisites ✅ *done 2026-09-02*

mise installed and pinning `kubectl`/`flux2`/`helm`/`sops`/`age`; all four
workload images moved off `:latest` onto `tag@sha256:digest`, resolved from the
digests **actually running** so adoption upgraded nothing by accident. The one
real change was `postgres:16` → `16.15`, because the running pod sat on an older
now-untagged 16.x. → GITOPS.md § Renovate, § mise

## Phase 2 — Secrets ✅ *done 2026-09-02*

All five secrets encrypted as `*.sops.yaml` with age; `.gitignore` set to refuse a
bare `secret.yaml` outright; `age.key` backed up to LastPass. One item deferred to
Phase 3 (the in-cluster `sops-age` Secret, which needs Flux to exist).
→ GITOPS.md § SOPS + age

## Phase 2b — Infisical ✅ *done 2026-09-04*

Cross-boundary secrets (`PGRST_JWT_SECRET`, four scoped MinIO Worker keys) moved
to Infisical as system of record, with the Infisical Operator reconciling them
into the cluster. `minio-worker-credentials` — a Secret no Deployment referenced,
sitting in the cluster purely as a filing cabinet — was moved and deleted, all
four values sha256-matched. → GITOPS.md § Infisical

## Phase 3 — Flux ✅ *done 2026-09-02*

`flux-operator` + a `FluxInstance` running four controllers, syncing
`kubernetes/flux/cluster` over SSH with a read-only deploy key. The live cluster
was **adopted**, not recreated: the NFS PVs were taken over in place. `prune: true`
followed on 2026-09-03 after clean reconciles. → GITOPS.md § Flux / flux-operator

## Phase 4 — Renovate ✅ *done 2026-09-03*

Self-hosted `renovatebot/github-action` on a daily cron, extended with
`home-operations/renovate-presets` so it parses `HelmRelease`, `OCIRepository` and
`Kustomization` files. `**/*.sops.*` excluded from scanning.
→ GITOPS.md § Renovate

## Phase 5 — Data protection ✅ *done 2026-09-04*

The largest phase. PostgreSQL became a CNPG `Cluster` with PGDATA on a 64 GiB zvol
on `archive-pool`; WAL archived continuously plus a daily base backup into MinIO
via `plugin-barman-cloud`; `sanoid` snapshotting all three ZFS datasets on `.101`.
cert-manager and Reloader were both pulled in as dependencies discovered along the
way.

**Two things were tested rather than assumed, which is the point of the phase:**

- **Restore drill** ([`../runbooks/RESTORE.md`](../runbooks/RESTORE.md)) —
  recovered into a scratch namespace in 56s, row counts matched exactly,
  `authenticator`'s SCRAM hash fingerprint was identical to the source, and PITR
  landed *between* two marker writes rather than merely somewhere after the base
  backup. Wrote nothing to the backup bucket and left no orphans.
- **Snapshot rollback** ([`../runbooks/SANOID-VERIFY.md`](../runbooks/SANOID-VERIFY.md))
  — both clone tests passed. The zvol clone returned the same filesystem UUID it
  was created with, and the `minio-data` clone contained the Postgres backups as
  well as the guide media.

PostgREST was cut over to `postgres-cnpg-rw` afterwards and verified end to end
(`HTTP 206`, `Content-Range: 0-0/57`; `401` anonymous), with no Cloudflare Worker
change required. The legacy `postgres` Deployment was retired later the same day —
scaled to zero, then deleted and pruned, at 0 PostgREST restarts.
→ GITOPS.md § CloudNativePG + plugin-barman-cloud, § sanoid (host), § k3s / storage substrate

## Phase 6 — Close the clickops gaps ✅ *done 2026-09-04*

Everything that lived in a web dashboard rather than in git. The cloudflared tunnel
became **locally managed** — which required minting a new tunnel, because
`config_src` is immutable after creation. Reloader was deployed. All five Proxmox
guests were imported into OpenTofu state without recreation, `0 to change, 0 to
destroy`, every body generated from the live guest and reviewed rather than
hand-written. The MinIO CORS Transform Rule was resolved by **deleting the
question**: it is vestigial, because no browser ever addresses
`minio-api.sunosrs.cc`. → GITOPS.md § cloudflared, § OpenTofu

## Phase 7 — Observability ✅ *done 2026-09-04*

kube-prometheus-stack in an `observability` namespace — 26/26 targets up, 222/222
rules healthy — plus Flux reconcile-failure alerting on two independent paths, and
Flux's own Grafana dashboards. Closed the last entry in "Known gaps".

Verified by **causing a failure**: a Kustomization pointed at a nonexistent path
produced `FluxKustomizationArtifactfailed` in Alertmanager within seconds, and put
`FluxReconciliationFailure` into `pending` on the same event. That test is what
surfaced two faults that every health signal called healthy — see
GITOPS.md § kube-prometheus-stack.

---

## Context that predates the migration

> **The Sun Clan Bingo app is decommissioned (2026-09-02)**, but MinIO and
> PostgreSQL were **kept** for a new Cloudflare Worker, rebranded `bingo`
> → `sunfire`. Namespaces cannot be renamed, so the namespace was deleted and
> recreated; node labels, the Postgres database, its owner, and
> `bingo_readwrite` → `sunfire_readwrite` moved with it.

> **Repository separation** *(settled 2026-09-02)*: three sibling trees under `/home/dev`, never nested.
>
> | Path | Repo | Role |
> |---|---|---|
> | `~/homelab/` | `lambo-n/homelab` (private) | GitOps source of truth — this repo |
> | `~/sunfire/` | `Sunfire-Team/sunfire` | Consuming app; cloned **for model context only**, read-only here |
> | `~/sunfire-backend/` | untracked, `chmod 600` | Pre-GitOps hand-applied manifests + plaintext secrets; rollback path |
>
> Chose `lambo-n` over the `Sunfire-Team` org: the cluster is personal infra, and
> org members would otherwise inherit access to the encrypted tunnel token and DB
> credentials.

**Superseded 2026-09-04:** `~/sunfire-backend/` no longer exists. Every value in
it was hash-verified against SOPS and Infisical first; the only two that were
irrecoverable were already dead (a token for the deleted tunnel, and a
pre-cutover `PGRST_DB_URI`). The rollback path is git history. `~/archive/` now
holds the decommissioned bingo assets, `chmod 700`.
