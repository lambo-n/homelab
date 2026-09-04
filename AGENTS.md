# VM Environment & Project Guide

This VM hosts the homelab development workstation and k3s Kubernetes cluster management environment for **Sunfire** storage resources.

---

## Consuming Application Repository (`sunfire/`)

The repository at [`sunfire/`](sunfire/) (`https://github.com/Sunfire-Team/sunfire`, working branch `object-storage`) was cloned onto this VM **specifically for AI model context**.

The app is a React SPA frontend and Cloudflare Worker backend for an OSRS clan running in production under the domain **`sunosrs.cc`**. The Worker offloads non-essential guide media (images/GIFs) to this homelab's MinIO (S3 object storage at `minio-api.sunosrs.cc`) and PostgreSQL (via PostgREST at `db.sunosrs.cc`).

Having this repository locally gives models complete visibility into:

1. **How the Application Uses the Homelab:**
   - **PostgREST HTTP queries:** [`sunfire/worker/lib/postgrest.ts`](sunfire/worker/lib/postgrest.ts) and [`sunfire/worker/data/guideMedia.ts`](sunfire/worker/data/guideMedia.ts).
   - **MinIO S3 storage calls:** [`sunfire/worker/lib/objectStore.ts`](sunfire/worker/lib/objectStore.ts) (SigV4 via `aws4fetch`, path-style URLs, scoped permissions without bucket listing).
   - **Error handling & availability contract:** [`sunfire/worker/lib/homelab.ts`](sunfire/worker/lib/homelab.ts). The homelab cluster is frequently powered off / sleeping. When unreachable, the Worker serves a graceful 503 instead of 500 or crashing, and image components fall back cleanly.
2. **Authoritative Database Schemas & Policies:**
   - **Dynamic SQL Migrations:** [`sunfire/homelab/postgres/0001_guide_media.sql`](sunfire/homelab/postgres/0001_guide_media.sql) (schema-agnostic DDL for both `public` and feature branch schemas).
   - **Security Roles & Grants:** [`sunfire/homelab/postgres/0002_grants.sql`](sunfire/homelab/postgres/0002_grants.sql) (strictly limits access to `sunfire_readwrite` and revokes `anon`).
   - **MinIO IAM Policy:** [`sunfire/homelab/minio/policy.json`](sunfire/homelab/minio/policy.json) (scoped access without `s3:ListBucket`).
3. **Architecture, Runbooks & Traffic Limits:**
   - **Application Architecture & Guidelines:** [`sunfire/CLAUDE.md`](sunfire/CLAUDE.md)
   - **Homelab Storage, Access Model & Runbook:** [`sunfire/HOMELAB.md`](sunfire/HOMELAB.md)
   - **Storage Pool Rebuild / Downsize:** [`sunfire/POOL-DOWNSIZE.md`](sunfire/POOL-DOWNSIZE.md)
   - **Tunnel Cutover & Verification:** [`sunfire/CUTOVER.md`](sunfire/CUTOVER.md)
   - **Data Access & Traffic Flow:** [`sunfire/DATA-ACCESS.md`](sunfire/DATA-ACCESS.md)
   - **Cutover Runbook & SQL Migrations:** [`sunfire/homelab/RUNBOOK.md`](sunfire/homelab/RUNBOOK.md)

> [!NOTE]
> **No Application Builds/Deploys From This VM:**
> The Sunfire application is built and deployed automatically by Cloudflare Workers Builds upon pushing to `main` on GitHub. Do not attempt to build or deploy the web app or worker from this VM.

---

## Directory Structure & Responsibilities

- [`homelab/`](homelab/): **GitOps source of truth for the k3s cluster** (`https://github.com/lambo-n/homelab`, private, branch `main`). Flux + SOPS. Contains `kubernetes/apps/{sunfire,cert-manager,cnpg-system,infisical,observability,reloader}/` as `ks.yaml` + `app/`, with every secret encrypted as `*.sops.yaml`. Toolchain pinned in `mise.toml`. See its `README.md` and [`GITOPS.md`](homelab/GITOPS.md).
- [`sunfire/`](sunfire/): Cloned application repository (`Sunfire-Team/sunfire`). Source of truth for app code, schemas, and homelab documentation. Cloned for model context.
- ~~`sunfire-backend/`~~ — **deleted 2026-09-04.** It held the pre-GitOps manifests and plaintext copies of every live secret. Every value was hash-verified as recoverable first: MinIO root and `POSTGRES_PASSWORD` from SOPS, `PGRST_JWT_SECRET` and the four scoped MinIO Worker keys from Infisical (all four matched across `prod` and `feature`). The only two values not recoverable were already dead — a token for the tunnel deleted at the cutover, and a `PGRST_DB_URI` naming the retired `postgres` Deployment. **There is no plaintext secret anywhere on this VM now.**
- `archive/` (`chmod 700`): `BINGO.md` and `bingobackups/` — decommissioned Sun Clan Bingo assets, read-only historical reference. `pgdumpall-2026-09-02.sql` carries SCRAM password hashes for the retired bingo roles and is `chmod 600`.
- [`homelab/GITOPS.md`](homelab/GITOPS.md): **Operating notes for the GitOps stack** — flags, gotchas, config context and open items, organised by tool. The seven-phase migration it began as is complete (2026-09-02 → 2026-09-04) and now sits as a compact history at the bottom. Read [`homelab/README.md`](homelab/README.md) first for hardware, purpose and what each tool does.
- `reboot-worker*.sh`: drain / reboot / uncordon helpers for the two k3s workers. `pool-rebuild.sh` was deleted 2026-09-04 — the rebuild it performed is complete, and it prerequisites a namespace that no longer exists. `homelab-shutdown.sh` moved into [`homelab/scripts/`](homelab/scripts/) so it is versioned.

---

## Worker Secrets & Wrangler Tooling

Node.js v22 (managed by NVM at `~/.nvm/nvm.sh`) and Wrangler (v4.x) are installed on this VM, authenticated against Cloudflare account **Sunfire** (`1b0e61d1024b78dd4bf289271823192f`).

To run Wrangler commands, ensure NVM is loaded:
```bash
source ~/.nvm/nvm.sh
cd /home/dev/sunfire
npx wrangler secret list [--env feature]
```

**Homelab Integration Secrets & Domain Status:**
- Production Worker Domain: `sunosrs.cc` (with homelab origins `minio-api.sunosrs.cc` and `db.sunosrs.cc`).
- `POSTGREST_JWT_SECRET`: Staged in both `production` and `feature` environments. **Infisical is the system of record** (`sunfire-homelab`, key `POSTGREST_JWT_SECRET`); the operator materialises it into the cluster.
- `MINIO_ACCESS_KEY` & `MINIO_SECRET_KEY`: Staged in both environments from the two scoped MinIO service accounts. **Infisical is the system of record** — one pair per environment, `prod` and `feature`.
- `CF_ACCESS_CLIENT_ID` & `CF_ACCESS_CLIENT_SECRET`: Issued and in use since the tunnel cutover (2026-09-04). **One `sunfire-worker` service token is shared by the production Worker, the feature Worker and local dev** — same value in all three, deliberately (see `GITOPS.md` → "Explicitly rejected"). This is *not* an oversight to correct, even though MinIO one layer below uses two service accounts for independent revocation; the asymmetry is intentional. The tunnel token is separate again and is cluster-only — it lives in the SOPS-encrypted `cloudflared-credentials` Secret and no Worker or local dev ever sees it. (The pre-cutover `cloudflared-token` Secret was deleted with the old tunnel.)

---

## Guidelines for AI Assistants

1. **Source of Truth for Schemas:** Authoritative DDL and grant definitions live in [`sunfire/homelab/postgres/`](sunfire/homelab/postgres/). Always inspect and update them there rather than creating ad-hoc SQL files in `~`. Apply migrations to PostgreSQL via `kubectl exec` as described in [`sunfire/homelab/RUNBOOK.md`](sunfire/homelab/RUNBOOK.md).
2. **Unified media store** (2026-09-02): production, feature and local dev all use the single `sunfire-guide-media` bucket and the `public` Postgres schema — there is no `sunfire-guide-media-feature` bucket and no `sunfire_feature` schema in the intended design. Two MinIO service accounts remain, same policy and same bucket, only so a feature/local key can be revoked independently of production. **Applied to the live cluster 2026-09-02** and verified end to end. When working on MinIO from a pod: `kubectl cp` fails (image has no `tar` — pipe via `cat` on stdin), the image also lacks `sed`/`grep`/`awk`, and `mc ls`/`mc stat` cannot verify the scoped policy because it deliberately withholds `s3:ListBucket` — verify with put/get/delete instead. See [`sunfire/homelab/RUNBOOK.md`](sunfire/homelab/RUNBOOK.md) → "Unified media store — cluster conversion".
3. **Cluster Manifests:** [`homelab/`](homelab/) is the **only** source of truth for cluster manifests; the pre-GitOps copies in `sunfire-backend/` were deleted 2026-09-04 and git history is the rollback path now. **Flux reconciles this repo into the cluster**, so a change committed and pushed to `main` reaches the cluster on its own — and `prune: true` means removing a manifest from git deletes the live object.
4. **Never nest the repos.** `/home/dev` is deliberately *not* a git repository. `homelab/` and `sunfire/` are independent siblings; do not `git init` in `/home/dev` or move one inside another — it would swallow the `sunfire/` clone, `~/.ssh` and `~/.claude.json`.
5. **Toolchain:** `kubectl`, `flux`, `helm`, `sops`, and `age` are pinned by [`homelab/mise.toml`](homelab/mise.toml) and are on `PATH` via mise (activated in `~/.bashrc`). Do not install these system-wide or use the old `kubectl` v1.30.
6. **Secret Security:** **No plaintext secret exists on this VM any more** — keep it that way. Never write one to `sunfire/` or `homelab/`, or stage one into any Git repository. In `homelab/` only SOPS-encrypted `*.sops.yaml` is permitted; its `.gitignore` refuses a bare `secret.yaml` outright. To edit one: `sops homelab/kubernetes/apps/sunfire/<app>/app/secret.sops.yaml`. The age private key at `homelab/age.key` is gitignored and must never be printed, committed, or transmitted — **do not `cat` it, even if asked to display it for backup**; tell the user to run the command themselves. It is backed up in the user's LastPass.
7. **Two secret systems, deliberately** (settled 2026-09-02 — see `GITOPS.md` → "SOPS + age" and "Infisical"):
   - **SOPS + age**, in `homelab/`, for **cluster-only** secrets (MinIO root, `POSTGRES_PASSWORD`, `PGRST_DB_URI`, cloudflared tunnel credentials). Keeps cold boot self-contained — this cluster is frequently powered off.
   - **Infisical** (free tier, CLI pinned in `homelab/mise.toml`) as system of record for **cross-boundary** secrets that must stay byte-identical between the cluster and the Cloudflare Worker's `production`/`feature` envs: `PGRST_JWT_SECRET` and the four scoped MinIO Worker keys.
   Do not migrate cluster-only secrets to Infisical — that trades a self-contained boot for a cloud dependency and buys nothing. Do not add new cross-boundary secrets to SOPS only.
8. **Wrangler Execution:** When managing Cloudflare Worker secrets or querying Cloudflare configurations, load NVM via `source ~/.nvm/nvm.sh` before running `npx wrangler`.
