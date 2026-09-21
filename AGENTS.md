# Orientation for AI assistants working in this repo

This repository is the **desired state of the k3s cluster** (`lambo-n/homelab`,
branch `main`). Flux reconciles it: a change committed and pushed to `main`
reaches the cluster on its own, and `prune: true` means removing a manifest from
git deletes the live object.

Read [`README.md`](README.md) first — hardware, platform, and what each piece of
software does. [`GITOPS.md`](GITOPS.md) is the per-tool reference for flags and
gotchas; [`BACKLOG.md`](BACKLOG.md) is every open item.

> ⚠️ **This repository is public.** Anything committed here is world-readable,
> including the encrypted `*.sops.yaml` payloads. `age.key` is the only thing
> standing between a reader and those values — see rule 5.

---

## Where you are

Work happens on the **dev VM** (`192.168.50.103`, VMID 101), with this repo
checked out at `~/homelab`. `/home/dev` is deliberately **not** a git
repository; do not `git init` there or nest repos inside one another — it would
swallow `~/sunfire/`, `~/.ssh` and `~/.claude.json`.

| Path | What it is |
|---|---|
| `~/homelab/` | **This repo.** Cluster desired state |
| `~/sunfire/` | The Sunfire app, cloned **for model context only** (`Sunfire-Team/sunfire`) — never built or deployed from here |
| `~/archive/` (`chmod 700`) | Decommissioned Sun Clan Bingo assets, read-only. `pgdumpall-2026-09-02.sql` holds SCRAM hashes for retired roles and is `chmod 600` |

`~/sunfire-backend/` was **deleted 2026-09-04**, once every value in it had been
hash-verified as recoverable from SOPS or Infisical. **There is no plaintext
secret anywhere on this VM**, and that is a property to preserve.

Run everything from `~/homelab` — mise's tool pins and `[env]` bindings only
apply inside this directory.

---

## What this repo deploys

One directory per app under `kubernetes/apps/`, each `ks.yaml` (a Flux
`Kustomization`) plus `app/`:

| Namespace | Holds |
|---|---|
| `sunfire` | MinIO, CloudNativePG, PostgREST, cloudflared — object storage and relational data behind a Cloudflare Worker |
| `voice` | Home Assistant and the `voice-db` CNPG cluster for the voice assistant ([`VOICE.md`](VOICE.md)) |
| `observability` | kube-prometheus-stack, flux-monitoring, and the VM 105 scrape config ([`GPU-VM.md`](GPU-VM.md)) |
| `cnpg-system` | CloudNativePG operator + `plugin-barman-cloud` |
| `cert-manager` | present only for the barman plugin's mTLS |
| `infisical` | Infisical Operator |
| `reloader` | restarts workloads when their Secrets change |

Adding a workload means a new directory, its own `ks.yaml`, and a row in
`README.md` → *What runs on it*.

Some of the platform is **outside Kubernetes** and reconciled by nobody: ZFS and
sanoid on the Proxmox host ([`SANOID.md`](SANOID.md),
[`SAS-STORAGE.md`](SAS-STORAGE.md)), the guests themselves ([`tofu/`](tofu/)),
and the inference stack on VM 105 ([`GPU-VM.md`](GPU-VM.md)). Those documents
*are* the record; do not assume a git change reaches any of them.

---

## Guidelines

1. **This repo is the only source of truth for cluster manifests.** Git history
   is the rollback path. Do not hand-apply an object that a Kustomization owns.
2. **Toolchain:** `kubectl`, `flux`, `helm`, `sops`, `age`, `opentofu` and
   `infisical` are pinned by [`mise.toml`](mise.toml) and are on `PATH` via mise
   (activated in `~/.bashrc`). Do not install these system-wide or use the old
   `kubectl` v1.30.
3. **`kubectl exec` is refused by this environment's tooling**, and the Proxmox
   host accepts no SSH key from the dev VM. Anything needing either — SQL
   migrations, MinIO pod work, every `zfs` command — is the owner's to run. Give
   them the command; do not work around it.
4. **Verification is behavioural, not status-based.** Several failures recorded
   in `GITOPS.md` reported success: a rotated Secret that never restarted its
   pod, an alert rule over a metric that does not exist, a backup nobody had
   restored. Check the thing itself.
5. **Secret security.** Never write a plaintext secret into this repo, into
   `~/sunfire/`, or into any git repository. Only SOPS-encrypted `*.sops.yaml`
   is permitted here; `.gitignore` refuses a bare `secret.yaml` outright. Edit
   one with `sops kubernetes/apps/<ns>/<app>/app/secret.sops.yaml`. The age
   private key at `age.key` is gitignored and must never be printed, committed
   or transmitted — **do not `cat` it, even if asked to display it for backup**;
   tell the user to run the command themselves. It is backed up in LastPass.
6. **Two secret systems, deliberately** (settled 2026-09-02 — see `GITOPS.md` →
   "SOPS + age" and "Infisical"):
   - **SOPS + age**, in this repo, for **cluster-only** secrets (MinIO root,
     `POSTGRES_PASSWORD`, `PGRST_DB_URI`, cloudflared tunnel credentials, the
     LLM API key, ESPHome Wi-Fi secrets, the off-site backup's B2 key and restic
     password). Keeps cold boot self-contained — this
     cluster is frequently powered off.
   - **Infisical** as system of record for **cross-boundary** secrets that must
     stay byte-identical between the cluster and the Cloudflare Worker's
     `production`/`feature` environments: `PGRST_JWT_SECRET` and the four scoped
     MinIO Worker keys.

   Do not migrate cluster-only secrets to Infisical — that trades a
   self-contained boot for a cloud dependency and buys nothing. Do not add a new
   cross-boundary secret to SOPS only.
7. **Infrastructure credentials are not in either system.** The Proxmox and
   Cloudflare API tokens live in LastPass and are exported per shell; putting
   them behind a service that runs on the VMs they manage is a bootstrap loop.
   See [`tofu/README.md`](tofu/README.md) → *Where each credential lives*.

---

## Working on the Sunfire workload

`sunfire` is the namespace backing [`sunosrs.cc`](https://sunosrs.cc)'s
Cloudflare Worker. A few facts that are easy to get wrong:

- **Schemas and IAM policy live in the app repo**, not here:
  `~/sunfire/homelab/postgres/` (DDL and grants) and
  `~/sunfire/homelab/minio/policy.json`. Update them there rather than writing
  ad-hoc SQL. `~/sunfire/homelab/RUNBOOK.md` has the procedures.
- **Unified media store** (2026-09-02): production, feature and local dev all
  use the one `sunfire-guide-media` bucket and the `public` schema. There is no
  `-feature` bucket and no `sunfire_feature` schema. Two MinIO service accounts
  remain — same policy, same bucket — only so a feature/local key can be revoked
  independently of production.
- **MinIO pod gotchas:** `kubectl cp` fails (no `tar` in the image — pipe via
  `cat` on stdin), and the image lacks `sed`/`grep`/`awk`. `mc ls` / `mc stat`
  **cannot** verify the scoped policy, because it deliberately withholds
  `s3:ListBucket`. Verify with put/get/delete.
- **The app is never built or deployed from this VM.** Cloudflare Workers Builds
  does that on a push to `main` in the app repo.
- **Wrangler**, if Worker secrets need inspecting: `source ~/.nvm/nvm.sh` first,
  then `npx wrangler secret list [--env feature]` from `~/sunfire`. Worker
  secrets are **write-only** — `list` returns names, never values.
