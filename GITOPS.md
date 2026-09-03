# GitOps Migration — Homelab

Working notes and plan for moving the homelab to a GitOps model.

Reference repo: [perryhuynh/homelab](https://github.com/perryhuynh/homelab/tree/ce242cf4a572b025cf6400b23545f2a1a60a0cf3)
(`home-operations` / `onedr0p` cluster-template lineage — pinned at `ce242cf`)

---

## Current State

### Physical / hypervisor

| Item | Value |
|---|---|
| Proxmox host | `192.168.50.101` — **also the NFS server** (`/archive-pool`) |
| Guests | `.102` (vpn-gateway container), `.103` (this dev VM), `.104`–`.106` (k3s nodes) |
| VM disks | `local-lvm` (LVM-thin on an NVMe RAID1) — **130.2 GiB, 30.5% used, 90.5 GiB free** |
| `archive-pool` | 3-way mirror — **1.68 TiB usable, 0.01% used (102 MiB)**; two-disk fault tolerance |
| Worker root fs | **9.75 GiB each, ~2.7 GiB free** — see Phase 5 |

> Figures refreshed 2026-09-03 from `pvesm status` on `.101`. The pool rebuild in
> `POOL-DOWNSIZE.md` is **complete**: 5 × 1.92 TB raidz2 (5.03 TiB) became a
> 3-way mirror (1.68 TiB), freeing two drives. Earlier revisions of this table
> read "~14 TB, ZFS w/ redundancy", then "8.72 TiB raw / 5.03 TiB usable" — both
> are now historical.
>
> ⚠️ **The "no VM disk is on ZFS" invariant is being retired deliberately.**
> It appears in this file, `HOMELAB.md`, `POOL-DOWNSIZE.md` §1 and the
> assistant's stored memory, always as the reason `archive-pool` could be
> destroyed without touching a VM. Phase 5 puts PGDATA on a **zvol** on that
> pool, so from that point on: destroying, exporting or rebuilding
> `archive-pool` takes `k3s-worker2`'s data disk with it, and pool work requires
> the VM stopped first. Nothing else changes — the other four guests stay on
> `local-lvm`.

**Single host = single failure domain.** This constrains most decisions below.

### Cluster

- k3s v1.35.5+k3s1 — `k3s-control` (2 vCPU/8 GB), `k3s-worker1`/`worker2` (4 vCPU/128 GB each)
- Utilization ~1% CPU, <1% memory on workers — enormous headroom
- No taints, `cluster-admin` available from this VM
- Default SC `local-path`; two manual NFS PVs (`minio-pv` 1Ti, `postgres-pv` 100Gi, both `Retain`) — capacities are inert metadata on NFS PVs; the real cap is the ZFS dataset quota
- Gateway API + Traefik CRDs already installed by k3s
- Egress to `github.com` and `ghcr.io` confirmed working

### Workloads (`sunfire` namespace, renamed from `bingo`)

`minio`, `postgres`, `postgrest`, `cloudflared` — all plain Deployments, applied by hand from `~/sunfire-backend/` (manifests were relocated here from `~/sunfire/` when the consuming application repository was cloned into `~/sunfire/` for model context).

> **The Sun Clan Bingo app is decommissioned (2026-09-02)**, but MinIO and
> PostgreSQL are being **kept** for a new Cloudflare Worker, rebranded `bingo`
> → `sunfire`. Namespaces cannot be renamed, so the namespace is deleted and
> recreated; node labels, the Postgres database, its owner, and
> `bingo_readwrite` → `sunfire_readwrite` move with it. Sequence:
> `POOL-DOWNSIZE.md` §3/§5. Tunnel/zone swap: `sunfire/CUTOVER.md` and `sunfire/homelab/RUNBOOK.md`.
>
> **Ordering note for Phase 3.** These four Deployments are currently empty
> shells — zero buckets, zero tables. Porting them to Flux as-is has little
> value; standing the *new Worker's* stack up under Flux from day one has a lot.
> Prefer the latter ordering, and treat the `sunfire` rebuild as the natural
> moment to do it — the manifests are being rewritten anyway.

### Known gaps

- [x] ~~Cluster infrastructure not under version control~~ — now `lambo-n/homelab` (private), checked out at `~/homelab/`. `~/sunfire-backend/` is kept as the pre-GitOps origin/rollback path; `~/sunfire/` remains a separate clone for model context
- [x] ~~**Secrets are plaintext**~~ — all five encrypted as `*.sops.yaml` in `~/homelab/`. Plaintext copies still live in `~/sunfire-backend/` (`chmod 600`, untracked) until Flux reconciles
- [x] ~~`postgrest/postgrest:latest` unpinned~~ — all four images now `tag@sha256:digest`
- [ ] No backups of any kind (no snapshots, no logical DB dumps)
- [ ] No monitoring/observability
- [x] ~~`kubectl` v1.30 vs server v1.35~~ — mise pins `kubectl` 1.35.8
- [ ] cloudflared tunnel is **remote-managed** — ingress routing lives in the Cloudflare dashboard, outside git
- [ ] MinIO CORS handled by a Cloudflare Transform Rule — also clickops
- [x] ~~**Local dev inherits production vars but feature credentials**~~ — resolved 2026-09-02 by unifying the media store (below); local dev's feature credentials now authorize the one shared bucket. Original finding: (found 2026-09-02, lives in `sunfire/`, not this repo). `npm run preview` runs `wrangler dev` with **no `--env`**, so it takes top-level config — `MINIO_BUCKET=sunfire-guide-media`, `POSTGREST_SCHEMA=public`. But `.dev.vars` holds the **feature** MinIO keys, whose embedded policy allows only `sunfire-guide-media-feature/*`. After tunnel cutover that combination is a guaranteed `AccessDenied`. Masked today only because `MINIO_ENDPOINT` is `.invalid`. Fix is `wrangler dev --env feature` (preferred — local dev should not touch the production bucket), *not* swapping in prod keys
- [x] ~~**Unified media store — cluster not yet converted**~~ — converted and verified 2026-09-02 (policy re-scoped, `PGRST_DB_SCHEMAS=public`, `sunfire_feature` dropped, feature bucket removed)
- [ ] **`minio-worker-credentials` is a filing cabinet, not a workload secret** — verified 2026-09-02 that *no* Deployment references it; it sits in the cluster purely as a store for Cloudflare Worker keys. Moves to Infisical and is then deleted from the cluster
- [ ] **`PGRST_OPENAPI_SERVER_PROXY_URI` is stale** — the live `postgrest` Deployment still points at `https://db.sunfirebingo.com`; the production domain is `db.sunosrs.cc`. Ported verbatim into `~/homelab` (with a `TODO`) so adoption stays a no-op — fix it as a deliberate commit, not inside the migration

---

## Decisions

### Scope: Flux manages the cluster, not the hypervisor

Flux reconciles the Kubernetes API. Proxmox VMs, ZFS datasets, and PVE config are not Kubernetes
objects, so "Flux for the whole Proxmox server" needs a shim (Crossplane `provider-proxmox-bpg`,
or `tofu-controller`).

**Rejected for now.** On a single host it's circular: Flux runs on k3s → k3s runs on VMs on `.101` →
Flux would manage those VMs. A bad reconcile destroys the cluster running the reconciler, and `.101`
is also the NFS server, so the archival data path goes with it. Both shims are community-maintained
single-vendor projects — thin bus factor for something that can delete VMs.

Layer split:

| Layer | Tool | Why not Flux |
|---|---|---|
| PVE host config (ZFS, network, NFS exports, packages) | Ansible, manual | No declarative API; Flux can't reach it |
| VM / LXC lifecycle | OpenTofu + `bpg/proxmox` | Must survive the cluster being down |
| k3s workloads | **Flux** | This is what Flux is for |

**Revisit if a second Proxmox node appears** — that breaks the circular dependency and moves
Crossplane from footgun to reasonable.

### Flux install: `flux-operator`, not `flux bootstrap`

Install controlplane.io's `flux-operator` + a `FluxInstance` CR. Flux manages itself declaratively
and Renovate can bump it. Per the reference repo, install only:

```yaml
components:
  - source-controller
  - kustomize-controller
  - helm-controller
  - notification-controller
```

### Renovate owns all dependency updates — no Flux image automation

`image-reflector-controller` and `image-automation-controller` are **not** installed. They would
fight Renovate (both rewrite tags in git), require an `ImageRepository` + `ImagePolicy` per image
plus inline `# {"$imagepolicy": ...}` markers, and cover only container tags — not Helm charts,
GitHub Actions, mise tools, or OpenTofu providers.

Confirmed by the reference repo: zero `ImagePolicy` resources across 594 files.

Use the existing self-hosted `renovatebot/github-action`, extended with
[`home-operations/renovate-presets`](https://github.com/home-operations/renovate-presets), which
already parses Flux `HelmRelease` / `OCIRepository` / `Kustomization` files.

Also: **pin exact Helm chart versions.** A `HelmRelease` with a semver range (`version: "^15.0.0"`)
auto-upgrades at runtime with no git change — that's drift, and it defeats the point.

### Secrets: hybrid — SOPS + age for the cluster, Infisical for cross-boundary

*Settled 2026-09-02.* Two classes of secret with genuinely different needs, so two homes.

| Class | Keys | Home | Why |
|---|---|---|---|
| **Cross-boundary** | `PGRST_JWT_SECRET`, `{PROD,FEATURE}_MINIO_{ACCESS,SECRET}_KEY` | **Infisical** (free tier) | Must stay byte-identical across the cluster *and* two Cloudflare Worker envs. Four copies synced by hand today — a real, present failure mode |
| **Cluster-only** | `MINIO_ROOT_USER/PASSWORD`, `POSTGRES_PASSWORD`, `PGRST_DB_URI`, cloudflared `token` | **SOPS + age**, in git | Nothing outside the cluster consumes them |

**Why not route everything through Infisical.** This cluster is frequently powered
off. With SOPS the secrets live in git, so a cold boot is self-contained. Routing
cluster-only secrets through a cloud API adds a hard boot-time dependency on
`app.infisical.com` (and on a free tier staying free) in exchange for nothing —
no external system reads those keys.

**Infisical relocates the bootstrap problem, it does not remove it.** The
operator authenticates with a machine-identity client ID + secret that must
already exist as a Kubernetes Secret before it can fetch anything. That
credential is seeded via SOPS — so `age.key` stays alive, holding exactly one
secret. Accepted deliberately: the alternative (hand-applied bootstrap
credential) trades a 184-byte key for a manual step on every cluster rebuild.

`age.key` itself is the one secret that can live in **neither** system — it is
the key that decrypts the others, and any machine credential used to fetch it
would die with the VM it is stored on. It lives in a personal password manager
(LastPass), reachable by human login from any device. See "Phase 2".

Flux decrypts natively via `decryption.provider: sops`. One age keypair, key stored in-cluster only.

```yaml
# .sops.yaml
creation_rules:
  - path_regex: (bootstrap|kubernetes)/.*\.sops\.ya?ml
    encrypted_regex: "^(data|stringData)$"
    mac_only_encrypted: true
    age: "age1..."
```

External Secrets Operator + 1Password is what the reference repo layers on top — **not adopted**:
1Password needs a subscription. Infisical's own Kubernetes Operator covers the
cross-boundary class natively (no ESO, no `bitwarden-sdk-server` sidecar, no
cert-manager dependency), and its CLI is in mise's registry so it pins alongside
the rest of the toolchain.

> Bitwarden Secrets Manager was the runner-up and is also free, but ESO's
> Bitwarden provider requires a `bitwarden-sdk-server` sidecar over HTTPS
> (the Rust SDK is ~150MB) plus cert-manager. More machinery for the same job.
>
> HCP Vault Secrets was ruled out outright — decommissioned, EOL 2026-07-01.

### Unified media store — one bucket, one schema

*Settled 2026-09-02.* Production, feature and local dev share the
`sunfire-guide-media` bucket and the `public` Postgres schema. The
per-environment split (`sunfire-guide-media-feature` + `sunfire_feature`) is
retired.

Guide media is **content, not per-environment state** — the same image is served
whichever Worker asks for it, and all three environments reach it through the one
homelab tunnel regardless. The split bought isolation nothing could use, while
costing two buckets, two policies, two schemas and four secrets kept
byte-identical across the cluster and two Worker environments.

It was also actively wrong: `wrangler dev` runs with no `--env`, so local dev
took *production* vars while `.dev.vars` supplied *feature* credentials scoped to
the feature bucket — a guaranteed `AccessDenied`, masked only by the `.invalid`
endpoints.

**Two service accounts are kept**, against the same policy and the same bucket,
purely so a leaked feature/local key can be revoked without rotating production.
That also meant the conversion required **no Worker secret writes at all** — the
feature account is re-scoped by editing its policy, not by swapping credentials.

Done while both buckets and both schemas were empty and before tunnel cutover:
no data moved, and no application code changed (`MINIO_BUCKET` and
`POSTGREST_SCHEMA` were already config vars). This was the cheapest the change
could ever be; after cutover it would mean migrating live objects and rows.

**Versioning is enabled** on `sunfire-guide-media`. Feature and local dev hold
`s3:DeleteObject` on what is now the only copy of every guide image, and there
are still no backups (Phase 5). Versioning makes an overwrite or delete
recoverable; it is not a substitute for snapshots, and Phase 5 matters more now.

> ✅ **Cluster converted 2026-09-02**, all four steps applied and verified:
> feature service account re-scoped to `sunfire-guide-media/*` (policy edited,
> credential untouched — no Worker secret rotated); `PGRST_DB_SCHEMAS=public`
> (schema cache 2 relations → 1); `sunfire_feature` dropped via a guarded
> `DO` block that refuses on a non-empty table; feature bucket removed.
>
> End-to-end proof: the **feature** credential performs PutObject, GetObject
> (exact byte round-trip) and DeleteObject against `sunfire-guide-media`. Probe
> purged with `--versions --force`; bucket empty.
>
> Procedure retained in `sunfire/homelab/RUNBOOK.md` → "Unified media store —
> cluster conversion" for a rebuild. Two traps recorded there: `kubectl cp`
> fails on the MinIO pod (no `tar` — pipe via `cat` on stdin), and `mc ls`/`mc
> stat` **cannot** verify this policy because both need the deliberately-denied
> `s3:ListBucket` and return `Access Denied` for every bucket either way. Verify
> with put/get/delete, not with a listing.

### Backups: local only — no cloud

**R2 rejected** — but note the original reasoning is now void. It was: the 10 GB free tier is
shared with the production bingo app's buckets, so backups would push it toward billing. **That app
is decommissioned (2026-09-02)**; there is no shared budget and no gallery data to protect. Any
claim in this file that gallery pictures/videos live in MinIO is obsolete — MinIO has zero buckets.

The conclusion still stands, for a simpler reason: **there is currently nothing here worth backing
up off-site.** Revisit this properly when a successor app defines real data — at that point the
decision should be made on that data's value, not inherited from the bingo-era constraint.

ZFS redundancy + SMART already solve **drive failure**. They do not solve accidental deletion,
a bad Flux prune, or logical corruption — RAIDZ replicates a `DELETE` to every disk instantly and
the pool still scrubs clean. That risk goes *up* when automated reconciliation with `prune: true`
arrives, but it's covered locally:

- **`sanoid` ZFS snapshots** on `.101` for `archive-pool/minio-data` and `archive-pool/postgres-data`.
  Copy-on-write, single-digit GB against the pool's 1.68 TiB (measured post-rebuild). ~24 hourly / 30 daily
  / 6 monthly. **Set this up when the pool is recreated** — a fresh pool is the natural moment, and
  snapshots cover the accidental-delete case that ZFS redundancy does not.
- **CNPG → MinIO**, not R2. `endpointURL: http://minio.sunfire.svc.cluster.local:9000`, with ZFS
  snapshotting the dataset underneath. One-line change if offsite is ever wanted.

Accepted residual risk: host loss (PSU/HBA, pool corruption, fire/theft). Data is classified
non-essential archival; this is a deliberate decision, not an oversight. Cheap future options if
that changes: `zfs send` to an external USB drive rotated quarterly, or `syncoid` over Tailscale.

### Postgres: CloudNativePG, 1 instance

Replaces the hand-rolled Deployment. Worth it for declarative rolling upgrades, pooler, and health
checks Flux can gate on — not only backups. Note barman-cloud is now a **separate plugin**
(`plugin-barman-cloud`), not built into `spec.backup`.

`instances: 1` — three replicas on one hypervisor is theater.

### Repo structure

Follow the reference layout: `ks.yaml` + `app/` per workload, with `dependsOn` + `healthChecks` +
`healthCheckExprs` for ordering (matters for the Postgres → PostgREST pair).

> **Repository separation** *(settled 2026-09-02)*: three sibling trees under `/home/dev`, never nested.
>
> | Path | Repo | Role |
> |---|---|---|
> | `~/homelab/` | `lambo-n/homelab` (private) | GitOps source of truth — this plan, executable |
> | `~/sunfire/` | `Sunfire-Team/sunfire` | Consuming app; cloned **for model context only**, read-only here |
> | `~/sunfire-backend/` | untracked, `chmod 600` | Pre-GitOps hand-applied manifests + plaintext secrets; rollback path |
>
> **Do not `git init` in `/home/dev` itself** — it would swallow the `~/sunfire/`
> clone, `~/.ssh`, and `~/.claude.json`. Keeping `~/sunfire/` a sibling means the
> app repo and the infra repo can be committed and pushed independently, and the
> `~/homelab` `.gitignore` never has to reason about a nested working tree.
>
> Chose `lambo-n` over the `Sunfire-Team` org: the cluster is personal infra, and
> org members would otherwise inherit access to the encrypted tunnel token and DB
> credentials.

### Prune safety

- Start every Kustomization at `prune: false`; enable only after several clean reconciles.
- Annotate stateful resources: `kustomize.toolkit.fluxcd.io/prune: disabled`
- PVs are `Retain`, but a mislabeled prune deleting `postgres-pvc` / `minio-pvc` is the one thing
  that would actually hurt.

### mise

Reference repo uses it for env binding only:

```toml
[env]
KUBECONFIG = "{{config_root}}/kubeconfig"
SOPS_AGE_KEY_FILE = "{{config_root}}/age.key"
```

Also use `[tools]` to pin `kubectl`/`flux`/`helm`/`sops`/`age` — fixes the v1.30/v1.35 skew.
Renovate has a first-class `mise` manager (updates the *first* listed version per tool only).

---

## TODO

### Phase 1 — Prerequisites ✅ *done 2026-09-02*

- [x] Pin `postgrest/postgrest:latest` → `v16.2@sha256:8525…` (same digest as running)
- [x] Audit remaining images — `minio` → `RELEASE.2025-09-07T16-13-09Z`, `cloudflared` → `2026.8.3` (both same digest as running); `postgres:16` → `16.15`, the one real change, because the running pod sits on an older now-untagged 16.x
- [x] Install mise; `mise.toml` pins `kubectl`/`flux2`/`helm`/`sops`/`age` with `[env]` for `KUBECONFIG` + `SOPS_AGE_KEY_FILE`
- [x] Upgrade `kubectl` 1.30.14 → 1.35.8 (server v1.35.5)
- [x] Create private repo `lambo-n/homelab`; `kubernetes/apps/sunfire/...` tree built from `~/sunfire-backend/`

> **Pinned to what was running, not to latest.** Digests were read off the live
> pods (`.status.containerStatuses[].imageID`) and mapped back to version tags,
> so adoption is a no-op rather than a silent upgrade. `kubectl diff` against the
> cluster shows *only* the four image lines and the four prune annotations.

### Phase 2 — Secrets ✅ *done 2026-09-02 (one item deferred to Phase 3)*

- [x] Install `sops` 3.13.3 + `age` 1.3.2 via mise; keypair generated at `~/homelab/age.key` (`chmod 600`, gitignored)
- [x] `.sops.yaml` with `encrypted_regex: ^(data|stringData)$` + `mac_only_encrypted`
- [x] Encrypt all five secrets (incl. `worker-credentials.yaml`) → `*.sops.yaml`; 10 keys total, every payload `ENC[…]`, metadata left readable
- [x] ~~Load age key into cluster as `sops-age` secret in `flux-system`~~ — done in Phase 3 (2026-09-02), `age.agekey` key
- [x] Verify nothing plaintext is staged before the first commit

> Public recipient: `age1ncpf5hg778lpszpv0u9mm48k5sdlm4y4v4dfsnaqskuwtwfgn3eqkz25qt`
>
> Verification actually performed before committing: every `*.sops.yaml`
> round-trips to a value semantically identical to its plaintext original; every
> key under `data`/`stringData` is `ENC[…]`; and each staged blob was grepped for
> all 14 real secret values/fragments (plus the age private key) — zero hits.
>
> ✅ **`age.key` is backed up in LastPass** (secure note, human login from any
> device — deliberately *not* in Infisical, since a machine credential used to
> fetch it would die with the VM). Worth confirming LastPass PBKDF2 iterations
> read 600,000: many pre-2023 accounts were left at 5,000, and after the 2022
> vault exfiltration that setting plus master-password strength is the whole
> remaining defense. Anything added in 2026 was not in the 2022 snapshot.
>
> ⚠️ Original warning, kept for context: **`age.key` exists only on this VM and is gitignored.** Lose it and every
> secret in the repo is unrecoverable. Back it up off-VM.

### Phase 2b — Infisical (cross-boundary secrets)

Free tier: 5 identities, 3 projects, 3 environments, Kubernetes Operator included.
CLI pinned in `mise.toml` (`infisical = "0.43.128"`). Outbound reachability to
`app.infisical.com` confirmed from this VM (egress is unrestricted; the "locked
down" posture is inbound-only).

*Account setup is interactive and must be done by a human:*

- [x] Create Infisical account + project — `sunfire-homelab`, id `a47fcb88-5044-463e-a7c6-7119b4f3c89e`
- [x] Environments renamed from the defaults: `Production [prod]`, `Feature [feature]`; `staging` deleted
      *(the slug is what the CLI and operator key off — renaming the display name alone is a silent trap)*
- [x] Create a **machine identity** (Universal Auth) on the project
- [x] Push the 6 cross-boundary entries via `scripts/infisical-seed.py --apply`
- [x] Verify round-trip: all 6 re-exported from Infisical and hash-matched against
      `~/sunfire-backend/`; JWT confirmed byte-identical across both envs
- [ ] ~~Verify Wrangler's staged copies byte-match~~ — **impossible, see below**
- [ ] SOPS-encrypt the machine-identity client ID + secret as the one bootstrap
      credential (`kubernetes/apps/sunfire/infisical/app/secret.sops.yaml`)
- [ ] Deploy the Infisical Operator via Flux (after Phase 3) + an `InfisicalSecret`
      CR that materialises `postgrest-config`'s JWT key
- [ ] Delete `minio-worker-credentials` from the cluster — nothing consumes it
- [ ] Remove the now-duplicated cross-boundary keys from the SOPS files

> **Ordering:** populate and verify Infisical *before* removing anything from
> SOPS. Until the operator is proven, the SOPS copies are the working system.

> 🛑 **Decision (2026-09-02): the Infisical → Wrangler re-push is DECLINED.**
> Briefly approved, then withdrawn before execution — no Wrangler write ever
> ran. The Worker's secrets were staged by hand at 20:20Z and are working;
> re-pushing to *prove* a byte-match is not worth touching a live production
> credential path that nobody is asking to change. Wrangler's copies remain
> asserted-equal, and that is accepted. Revisit only at a genuine rotation.
>
> Corollary: **Infisical is a backup, not a source that pushes outward.**
> Nothing reads it yet. Widening it to more Worker secrets is additive and
> safe; pushing *from* it to Cloudflare is a separate, deliberate act.

> ⚠️ **Correction (2026-09-02): Cloudflare Worker secrets are write-only.**
> `wrangler secret list` returns names and types only — never values. So
> "verify Wrangler byte-matches Infisical" cannot be done, and this plan
> previously assumed it could. The *only* way to guarantee the match is to
> re-push from Infisical to Wrangler, making Infisical canonical in fact
> rather than in principle. Until that push happens, Wrangler's copies are
> asserted equal, not verified equal.

> 🔎 **Finding: three Worker secrets exist only in Cloudflare.**
> `wrangler secret list` shows `DISCORD_BOT_TOKEN`, `DISCORD_CLIENT_SECRET`
> and `SESSION_HASH_SECRET` beyond the cross-boundary set. Checked against
> `sunfire/.dev.vars` (gitignored, holds real values):
>
> | Secret | Local copy | If the CF account is lost |
> |---|---|---|
> | `SESSION_HASH_SECRET` | **real value present** | recoverable from `.dev.vars` |
> | `DISCORD_BOT_TOKEN` | placeholder only | regenerate in Discord dev portal |
> | `DISCORD_CLIENT_SECRET` | placeholder only | regenerate in Discord dev portal |
> | `CF_ACCESS_CLIENT_{ID,SECRET}` | placeholder only | not yet generated (pending cutover) |
>
> ⚠️ `SESSION_HASH_SECRET`'s only readable copy is in `.dev.vars`, and there is
> **no way to confirm it matches what is live** in either Worker env (Cloudflare
> is write-only). `.dev.vars` aligns with *feature* on every key that can be
> checked, but that is inference, not proof. Pushing that value to Wrangler
> would invalidate live sessions if it is wrong — so it must never be pushed,
> and if stored in Infisical it must be labelled unverified rather than
> presented as system-of-record.
>
> Not catastrophic — the Discord pair can be regenerated — but they currently
> have **no readable backup anywhere**. Since Cloudflare is write-only,
> Infisical would be the only readable copy. Argues for widening Infisical's
> remit from "cross-boundary" to "every Worker secret".
>
> Also confirmed: `.dev.vars` MinIO values hash-match the **feature** service
> account, and its `POSTGREST_JWT_SECRET` matches the cluster's — local dev,
> cluster, and Infisical all agree today. No drift.

### Phase 3 — Flux ✅ *done 2026-09-02 (last item deliberately held open)*

- [x] ~~Add a **deploy key** for `lambo-n/homelab`~~ — ed25519, **read-only**, GitHub key id `162121868`, titled `flux-homelab-deploy (k3s flux-system)`. Private half at `~/.ssh/flux-homelab-deploy` (`chmod 600`, never in git); in-cluster as Secret `flux-system` with `identity` / `identity.pub` / `known_hosts`
- [x] ~~Create the `sops-age` secret in `flux-system` from `~/homelab/age.key`~~ (carried over from Phase 2)
- [x] ~~Install `flux-operator` + `FluxInstance` (4 controllers, no image automation)~~ — chart `0.59.0` (appVersion `v0.59.0`), `FluxInstance` from `bootstrap/flux/flux-instance.yaml`; all four controllers Running, image automation absent as designed
- [x] ~~Port `sunfire-backend/` workloads to `ks.yaml` + `app/` structure~~ — written in Phase 1, **applied 2026-09-02**; `dependsOn` ordering already encoded
- [x] ~~Reconcile with `prune: false`; confirm adoption of the 4 running deployments~~ — all 6 Kustomizations Ready at `80f35c4`
- [x] ~~Add `dependsOn` ordering for Postgres → PostgREST~~ — `storage → {minio, postgres → postgrest} → cloudflared`
- [x] ~~Enable `prune: true` + `prune: disabled` annotations on stateful resources~~ — done 2026-09-03, see "Prune enabled" below

> **Adoption result.** The live cluster had been running four unpinned `:latest`
> tags; the repo carries digest pins, so adoption rolled all four Deployments —
> the Phase 1 pinning finally reaching the cluster. Verified after reconcile:
>
> - all four Deployments 1/1 Ready on the pinned digests
> - `postgres` took its intended patch upgrade **16 → 16.15**; the log shows a
>   clean `database system was shut down` → `ready to accept connections`, so the
>   NFS data directory replayed rather than reinitialised
> - `postgrest` reconnected and loaded its schema cache (1 relation)
> - `cloudflared` re-established the tunnel; all QUIC/TCP/API prechecks pass
> - **`minio-pv` / `postgres-pv` were not recreated** — both still carry their
>   original `07:05:44Z` creation timestamp, `Bound`, `Retain`
> - all five SOPS secrets decrypted in-cluster and applied
>
> **Prune enabled (2026-09-03).** `prune: true` on `sunfire-{minio,postgres,postgrest,cloudflared}`.
> `sunfire-storage` keeps `prune: false` permanently. Removing a manifest from
> git now deletes the live object.
>
> Before enabling, each Kustomization's inventory was dumped and matched against
> its git content — 6/2/4/3/3/4 objects, nothing unexpected adopted from the
> hand-applied era. That inventory check, not the reconcile count, is what makes
> this safe: prune only removes objects a Kustomization already owns and git no
> longer declares, so a correct inventory means enabling it is an immediate no-op.
>
> **Found while doing it:** the parent `flux-system` Kustomization was already
> running `prune: true` — flux-operator sets that on the sync Kustomization by
> default — and the `sunfire` Namespace sits in its inventory. Dropping
> `namespace.yaml` from git would therefore have deleted the namespace, and the
> Kubernetes garbage collector would have taken every object inside with it. The
> `prune: disabled` annotations on the PVCs do **not** stop that: they stop Flux,
> not the GC cascade. PVs are `Retain` so the data survives, but the claims would
> not. `namespace.yaml` now carries `prune: disabled` to close it. This hazard
> predated enabling prune on the app Kustomizations.

> **The `flux-operator` install is the one imperative step left.** It was applied
> with `helm upgrade --install ... --version 0.59.0` rather than from git, because
> it is the thing that *starts* the reconciler. The pinned version is recorded
> above so Phase 4 can hand it to Renovate; the `FluxInstance` it manages is
> already declarative.

### Phase 4 — Renovate ✅ *done 2026-09-03*

- [x] ~~Point existing GitHub Action at `home-operations/renovate-presets`~~ — `.renovaterc.json5` extends `home-operations/renovate-presets#8.1.0`; workflow adapted from `Sunfire-Team/sunfire`'s proven pattern (same SHA-pinned Actions)
- [x] ~~Add `ignorePaths: ["**/*.sops.*"]`~~ — in `.renovaterc.json5`
- [x] ~~Automerge rules: patch/minor for `cloudflared`, `postgrest`, `minio`; manual for Postgres majors~~ — `.renovate/autoMerge.json5` + `.renovate/allowedVersions.json5` (Postgres `<=17`, kubectl `~1.35`)
- [x] ~~Automerge GitHub Actions with `minimumReleaseAge: "3 days"`~~ — in `.renovate/autoMerge.json5`
- [x] ~~Install the GitHub App on `lambo-n/homelab`~~ — new personal App `homelab-renovate` (separate from the org-owned `sunfire-renovate`; org Apps cannot be installed on personal repos). Minutes bill to `lambo-n`'s personal 2,000/month free tier

> **Dry run passed 2026-09-03.** Daily cron (`0 0 * * *` UTC) will open the
> first real PRs on the next run. Workflow also triggers on push to `main`
> when Renovate config changes.

### Phase 5 — Data protection ← *in progress 2026-09-03*

- [ ] Install + configure `sanoid` on `.101` for both archive datasets — runbook written
      (`SANOID.md`); **yours to run**, this VM has no SSH key on `.101`
- [ ] Verify a snapshot rollback actually works before relying on it — `SANOID.md` §4
- [x] ~~Deploy CNPG operator + `plugin-barman-cloud`~~ — done 2026-09-03, plus cert-manager,
      which the plugin hard-requires
- [ ] Provision the PGDATA zvol on `archive-pool` and attach it to `k3s-worker2` — runbook
      written (`STORAGE.md`); **yours to run**, `.101` has no SSH key for this VM
- [ ] Migrate `postgres` Deployment → CNPG `Cluster` (`instances: 1`) — manifests written and
      validated against the live CRDs; **not wired into the root kustomization**, and blocked
      on the zvol above and the backup bucket below
- [ ] `ObjectStore` → local MinIO; daily `ScheduledBackup` — written; blocked on the bucket +
      scoped service account (`scripts/minio-barman-account.sh`, **yours to run**)
- [ ] **Test a restore into a scratch namespace** — untested backups aren't backups.
      Runbook written (`RESTORE.md`); blocked on the same disk finding, since the drill needs
      a second PGDATA on the same node
- [ ] ~~VolSync for the MinIO PVC~~ — **deferred, see below.** There is no destination for it
      on this cluster today that is not either the source volume or the source pool
- [ ] Pin `sanoid` in Ansible/host config once that layer exists — it is **host-level, not a
      Kubernetes object**, so neither Flux nor OpenTofu reconciles it

> 🛑 **Blocker found 2026-09-03: the worker root disks are 9.75 GiB.** Phase 5's
> central decision — move PGDATA off NFS onto `local-path` — quietly assumes the
> k3s nodes have room for it. They do not. Measured from the kubelet
> (`/api/v1/nodes/<node>/proxy/stats/summary`):
>
> | Node | Root fs | Used | **Available** |
> |---|---|---|---|
> | `k3s-control` | 9.75 GiB | 4.45 | 4.78 |
> | `k3s-worker1` (minio) | 9.75 GiB | 6.51 | 2.72 |
> | `k3s-worker2` (postgres) | 9.75 GiB | 6.54 | **2.69** |
>
> `cluster.yaml` originally asked for `storage: 20Gi` on `k3s-worker2`.
> **local-path does not enforce that number** — it provisions a directory, not a
> quota — so the PVC binds, reports 20Gi, and the real ceiling is 2.69 GiB shared
> with the OS and the container images. Nothing fails at apply time. The database
> is empty today, so bootstrap would *succeed*, and the misconfiguration would
> surface later as node-level `DiskPressure` on the node running Postgres,
> PostgREST and the kubelet's image store.
>
> The WAL case is what makes this urgent rather than untidy. CNPG keeps
> unarchived WAL in PGDATA until the archiver drains it, and this cluster is
> *frequently powered off* — so MinIO being down is the normal state, not the
> exception, and WAL accumulating against a 2.69 GiB ceiling is the expected
> path, not a tail risk. There is no CNPG knob that bounds it without also
> throwing away recoverability; the fix is a real device.
>
> ✅ **Resolved by the zvol decision below, not by growing the root disk.**
> Growing the root disk would have left the database sharing a filesystem with
> the OS and the image store — a bigger disk, same absent boundary. Putting
> PGDATA on its own block device makes the device the ceiling, and putting that
> device on `archive-pool` puts it on the storage that exists for exactly this.
> `storage:` is now `64Gi`, matching the zvol, so the manifest states a number
> something actually enforces. The root disks still grow to ~24 GiB, for
> container-image churn only. Host-side procedure: `STORAGE.md`.
>
> One thing this does *not* invalidate: the manifests are correct. All three
> objects pass
> `kubectl apply --dry-run=server` against the live CRDs, the `dependsOn` targets
> all exist, `sunfire/role: postgres` is on `k3s-worker2`, and the SOPS
> `authenticator` password was confirmed byte-identical to the one embedded in
> the live `PGRST_DB_URI`. The design is sound; the substrate was never sized
> for it.

> **VolSync is deferred, not scheduled** *(2026-09-03)*. The line item read
> "VolSync for the MinIO PVC (only non-DB stateful volume)" and never said where
> the replica would go. Working that through, there is no answer on this cluster:
>
> | Destination | Why not |
> |---|---|
> | MinIO itself (restic → `s3://…`) | The repository would live inside the volume being replicated. Circular |
> | A `local-path` PVC on a worker | 2.7 GiB free, per the blocker above |
> | A second NFS PV or zvol on `archive-pool` | Same pool sanoid already snapshots. A second copy that dies with the first |
>
> The PGDATA zvol decision below does not change this. It gives `archive-pool`
> a block-device path it did not have before, but VolSync's source here is
> MinIO's PV — which is already *on* `archive-pool`. A destination on the same
> pool replicates a volume onto itself at one remove.
>
> There is also no CSI snapshot support here (`local-path` and two manual NFS
> PVs; `volumesnapshotclass` is not even a resource type), so VolSync would be
> limited to `copyMethod: Direct` — reading a live MinIO data directory rather
> than a point-in-time image of it.
>
> What VolSync would genuinely add is a copy on *different media* in restic's
> file-level, verifiable format. That only becomes real when a destination exists
> that is not `.101` — which is the same condition already written into "Backups:
> local only": revisit when a successor app defines data whose value justifies
> going off-host. Until then this is machinery guarding a copy against nothing.
> `archive-pool/minio-data` gets sanoid, and after the CNPG cutover it holds the
> Postgres backups too — that is the dataset that matters, and `SANOID.md`
> already says so.

> **cert-manager is now a dependency, and that voids one earlier rejection.**
> CNPG deleted the in-tree `spec.backup.barmanObjectStore` in 1.28; this cluster
> would run 1.30, so `plugin-barman-cloud` is the only way to back the database
> up at all, and the plugin requires cert-manager for the operator↔plugin mTLS.
> "External Secrets Operator drags in cert-manager" therefore stops being an
> argument against ESO — that rejection now rests solely on 1Password needing a
> subscription. Nothing else in the cluster issues certificates; ingress TLS is
> terminated by Cloudflare at the edge.
>
> **Versions are pinned by *chart*, not by app version.** Both CNPG charts move
> independently of what they carry: `cloudnative-pg` 0.29.0 → operator 1.30.0,
> `plugin-barman-cloud` 0.7.1 → plugin v0.14.0 (upstream had tagged plugin
> v0.15.0 with no chart shipping it). The chart is what Flux installs. Also
> note cert-manager's chart defaults `crds.enabled` to **false** and templates
> the CRDs behind it, so accepting the default installs an operator with no API.

> **PGDATA moves off NFS onto a zvol on `archive-pool`** *(decided 2026-09-03;
> supersedes the `local-path` decision taken earlier the same day)*. The old
> Deployment kept its data directory on `.101:/archive-pool` over **NFS**. The
> CNPG Cluster keeps it on the same pool, but as a **block device**: a zvol
> attached to `k3s-worker2` as a virtual disk and mounted at
> `/var/lib/rancher/k3s/storage`, the path `local-path` already provisions into.
>
> **What the earlier decision got wrong.** It ranked "retires the single-writer
> NFS hazard" as the first and heaviest reason to abandon the pool. That is not
> what happened on 2026-09-02. Commit `6d51959` records the actual cause:
> `maxUnavailable` of 25% rounds down to 0 on `replicas: 1`, so Kubernetes
> started the replacement pod before stopping the old one and both mounted the
> same directory. That is **RollingUpdate on a ReadWriteMany volume** — it would
> occur on any RWX backend and has nothing to do with NFS semantics. It was
> already fixed by `strategy: Recreate` in that same commit, and CNPG does not
> use a Deployment at all, so it cannot recur under CNPG regardless of storage.
> The argument was retired twice over before it was written down.
>
> What survives is the second reason — **CNPG explicitly discourages NFS for
> PGDATA** (fsync and locking semantics). That is an objection to *NFS*, not to
> *archive-pool*, and a zvol answers it: it is block storage, single-writer by
> construction, with no network filesystem in the path.
>
> | | `local-path` on `local-lvm` | **zvol on `archive-pool`** |
> |---|---|---|
> | CNPG's NFS objection | avoided | avoided — block, not NFS |
> | Space | 90.5 GiB, shared with all five guests | **1.68 TiB, 0.01% used** |
> | Fault tolerance | RAID1, one disk | 3-way mirror, **two disks** |
> | sanoid snapshots of PGDATA | **none** | **yes** |
> | Enforced ceiling | the device | the device |
> | Kubernetes changes | none | none |
>
> The snapshot row carries the most weight. The `local-path` version explicitly
> accepted "losing `k3s-worker2` means restore-from-backup, not a snapshot
> rollback" as a cost; on a zvol that cost simply does not arise, and `SANOID.md`
> stops having a hole where the database used to be.
>
> **Three costs, stated plainly.** *(1)* It retires the "no VM disk is on ZFS"
> invariant — see the warning under "Current State"; pool work now requires
> `k3s-worker2` stopped. *(2)* SATA SSD mirror instead of NVMe, so higher fsync
> latency. For a guide-metadata table with near-zero write volume this is noise,
> but it is a real trade in the honest direction. *(3)* PGDATA and its barman
> backups now share a pool, where the `local-path` plan had them on different
> media. Both were always on the same *host*, which dominates the risk — but the
> separation is genuinely reduced, and the answer if that ever matters is the
> off-host option already named under "Backups: local only", not a different
> local disk.
>
> **`volblocksize=8K`, set at creation and immutable afterwards.** Postgres pages
> are 8K; recent ZFS defaults to 16K, and the mismatch is permanent write
> amplification. Keep `compression=lz4`; leave `sync=standard` — never
> `sync=disabled` under a database.
>
> Consequence for `SANOID.md`: `archive-pool/postgres-data` (the NFS dataset) is
> the **legacy** rollback path and stops changing at cutover, while the new zvol
> and `archive-pool/minio-data` are the two live datasets. `minio-data` still
> carries both the guide media and every Postgres backup, so it remains the one
> that matters most.
>
> The worker root filesystems are still growing 9.75 → ~24 GiB, but for
> **container-image churn only** — 6.5 of 9.75 GiB is already used. No database
> data lands there. See `STORAGE.md`.

> **Three steps are yours, not the assistant's** *(was two; the disk grow is
> new)*. `kubectl exec` against a pod is
> refused by this environment's tooling, and `.101` has no SSH key for the dev
> VM. So: `scripts/minio-barman-account.sh` (creates the backup bucket and a
> service account scoped to it, and writes the credential into the repo already
> SOPS-encrypted — the keys are generated in the pod, piped into `sops`, and
> never printed), and `SANOID.md` in full. The barman account deliberately
> **does** hold `s3:ListBucket`, unlike the Worker accounts one layer down —
> barman needs to list WALs and backups. Same reasoning, opposite answer; it is
> not a copy-paste slip.
>
> The third is **`STORAGE.md`** — creating the PGDATA zvol on `archive-pool`,
> attaching it to `k3s-worker2`, and growing the three root disks for image
> churn. Proxmox has no Kubernetes API to reach it through, and the zvol now
> gates the CNPG cutover. `RESTORE.md` is likewise yours to execute end to end;
> it is written and blocked on the same volume, since a restore drill needs a
> second PGDATA alongside the live one.

> **What `sanoid` does and does not cover.** It snapshots ZFS datasets, and the
> only ZFS on `.101` is `archive-pool` — i.e. exactly `archive-pool/minio-data`
> and `archive-pool/postgres-data`, which are the two NFS PVs. **The k3s VMs are
> not covered**: their disks are on `local-lvm` (LVM-thin) and the host has zero
> zvols (`zfs list -t volume` → *no datasets available*, `POOL-DOWNSIZE.md` §1).
> VM-level recovery is Proxmox `vzdump` or the OpenTofu rebuild in Phase 6 — not
> this line item. Do not let a green sanoid dashboard read as "the cluster is
> backed up".
>
> **A snapshot of a live Postgres is crash-consistent, not a backup.** Rolling
> one back is equivalent to yanking power: Postgres will WAL-replay and usually
> come up, but that is not PITR and it will not survive logical corruption. That
> asymmetry is exactly why CNPG + `plugin-barman-cloud` is in this same phase and
> not deferred — sanoid protects the *volume*, barman protects the *database*.
> Neither one substitutes for the other.

### Phase 6 — Close the clickops gaps

- [ ] Convert cloudflared to a **locally-managed** tunnel — `config.yaml` in a ConfigMap, ingress
      routing in git
- [ ] Deploy Reloader (`reloader.stakater.com/auto: "true"`) so secret rotation restarts pods
- [ ] OpenTofu module for Cloudflare: DNS, tunnel routes, the MinIO CORS Transform Rule
- [ ] Import the 5 existing Proxmox VMs into OpenTofu state **without recreating them**

> `opentofu` is now pinned in `mise.toml` (1.12.6). Until this phase it is an
> unused pin — the layer-split table under "Scope" named OpenTofu as the VM
> lifecycle tool while nothing in the toolchain provided it, so the row described
> an intention rather than a capability. State lives on this VM and is backed up
> with it; **applies are run by hand from here, never reconciled from inside the
> cluster** — that is the whole point of the rejection below.

### Phase 7 — Observability

- [ ] `kube-prometheus-stack` (128 GB/worker sitting idle)
- [ ] Flux reconcile-failure alerting (Flux ships Prometheus metrics + Grafana dashboards)

### Backlog / not now

- [ ] kubeconform or [`flux-schema`](https://github.com/fluxcd/flux-schema) validation in CI
      *(my own recommendation — the reference repo does **not** do this)*
- [ ] Talos Linux for the k3s nodes — the real endgame for declarative node config, but a rebuild
- [ ] Gateway API / Envoy Gateway instead of Traefik Ingress (CRDs already present)
- [ ] ~~External Secrets Operator~~ — superseded by the Infisical Operator for the cross-boundary class; SOPS keeps the cluster-only class

### Explicitly rejected

| Option | Why |
|---|---|
| Flux/Crossplane/tofu-controller for Proxmox | Circular dependency on a single host. Also dissolves a real boundary: the shim needs a Proxmox API token with `VM.Allocate` stored in-cluster, so cluster compromise would become hypervisor compromise — today the cluster cannot touch `.101` at all. **Revisit if** a second Proxmox node appears, *or* if a separate management cluster exists (k3s in an LXC on the host) so the reconciler no longer sits on its own substrate |
| Flux image automation controllers | Renovate is a strict superset; they'd conflict |
| R2 for backups | Original reason (shared 10 GB free tier) is void — app decommissioned. Still rejected: nothing here is worth off-siting yet. Revisit per successor app |
| CNPG `instances: 3` | False redundancy on one hypervisor |
| Cilium BGP / Multus | No network gear to peer with |
| `actions-runner-controller` | Another circular dependency on a single host |
| `HelmRelease` semver ranges | Runtime drift; git stops describing what's deployed |
| Per-environment Cloudflare Access service tokens | **Deliberate, decided 2026-09-02.** One `sunfire-worker` token is shared by the prod Worker, the feature Worker and local dev, per `ZEROTRUST.md`. Splitting it would allow revoking a leaked local/laptop token without taking production down — the same reasoning that keeps *two* MinIO service accounts one layer below. Rejected anyway: prod being down costs nothing and all stored data is non-critical, so the blast radius the split protects against is not worth the extra tokens to manage. **The asymmetry with MinIO is intentional — do not "fix" it.** Revisit only if this cluster ever stores something that matters |
