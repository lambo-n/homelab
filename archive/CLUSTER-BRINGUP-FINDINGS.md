# Cluster bring-up findings — Flux, prune, cloudflared, MinIO

> 📦 **Archived 2026-10-05.** Drills, adoption results, cutovers and
> corrections from bringing the cluster under Flux (2026-09-02 to 2026-09-08).
> Current state: [../GITOPS.md](../GITOPS.md#flux--flux-operator).

## 2026-09-08 — push-to-apply drilled with a throwaway app

> Moved from `GITOPS.md` → *Flux / cloudflared / MinIO* in the 2026-10-05 docs pass, as it stood.

> **Push-to-apply drilled 2026-09-08.** A throwaway `gitops-canary` app — one
> `pause` pod in its own deliberately prunable namespace — was pushed to `main` and
> was Ready on the cluster in under a minute with no manual reconcile
> (`Applied revision: refs/heads/main@sha1:0e426d41`, pod 57s old before anything
> was forced). Reverting the commit pruned the Deployment *and* the namespace with
> no manual cleanup, which is the half that `prune: true` had never been shown to do
> for a whole app. Both commits stay in history: `0e426d4` and its revert `fd38c81`.
>
> `interval: 1m` was written into `flux-instance.yaml` after this drill. Until then
> the field was absent and the cluster ran on flux-operator's unstated default, which
> is why `README.md` had claimed the poll was 30m — that number is the app
> Kustomization interval, not the source's.

## 2026-09-02 / 2026-09-03 — adoption result, prune enabled, and the namespace-GC finding

> Moved from `GITOPS.md` → *Flux / cloudflared / MinIO* in the 2026-10-05 docs pass, as it stood.

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

## 2026-09-02 — correction: Worker secrets are write-only

> Moved from `GITOPS.md` → *Flux / cloudflared / MinIO* in the 2026-10-05 docs pass, as it stood.

> ⚠️ **Correction (2026-09-02): Cloudflare Worker secrets are write-only.**
> `wrangler secret list` returns names and types only — never values. So
> "verify Wrangler byte-matches Infisical" cannot be done, and this plan
> previously assumed it could. The *only* way to guarantee the match is to
> re-push from Infisical to Wrangler, making Infisical canonical in fact
> rather than in principle. Until that push happens, Wrangler's copies are
> asserted equal, not verified equal.

## 2026-09-04 — locally-managed tunnel: the 1002 error, the swap, and the verification

> Moved from `GITOPS.md` → *Flux / cloudflared / MinIO* in the 2026-10-05 docs pass, as it stood.

> ✅ **Locally-managed tunnel, done 2026-09-04 — and it took a new tunnel.**
> `config_src` is **immutable after creation**, which Cloudflare reports as
> `1002 Tunnel not found`. That error points at a wrong id or a bad token and is
> neither; isolating it took three calls on one token against one tunnel:
> `GET` succeeds, `PATCH {"name":…}` succeeds, `PATCH {"config_src":"local"}`
> returns 1002. Writes are permitted; that field is not editable. The
> configurations endpoint refuses the other route too — `source: "local"` with an
> empty config returns `1056 … doesn't contain any ingress rules`, insisting on
> rules even in the mode that ignores them.
>
> So the conversion was a **tunnel swap**: `scripts/cloudflared-new-local-tunnel.sh`
> creates `sunfire-local` with `config_src: "local"`, generates the secret, sends
> it once, pipes it into SOPS and never prints it. Flux applied the new
> credentials and ConfigMap, **Reloader restarted the connector** (installed
> earlier the same day for exactly this), and one pre-staged `tofu apply` moved
> both CNAMEs. End state: new tunnel `local`/`healthy`/4 connections, old tunnel
> `down`/0 and kept as the rollback path — until the verification below passed,
> at which point it was deleted and `cloudflared-token` left the repo with it.
>
> ✅ **Verified end to end by the Worker 2026-09-04**: upload, fetch and delete
> against MinIO all work through the new tunnel. That is the test that counts,
> since the Worker holds the Access service token and is the only client able to
> traverse edge → Access → tunnel → origin. The old tunnel was deleted only
> after that passed.
>
> Proof it is genuinely local: the connector's startup log has **no
> `Updated to new configuration` line**. That line is what a remotely-configured
> connector emits when the edge pushes its ingress map, and its absence is the
> only direct evidence that the file is what is being read.
>
> ⚠️ **A `403` from these hostnames is not a health check.** Cloudflare Access
> rejects at the edge *before* the tunnel — responses carry `cf-access-aud` and
> `server: cloudflare` with no origin fingerprint — so a `403` is returned
> whether the origin is healthy, broken, or absent. This file and
> `sunfire/CUTOVER.md` both treat `403` as the healthy signal; it only ever
> demonstrated that DNS resolves and the edge is up. The honest end-to-end test
> is the Worker itself, since it holds the Access service token and is the only
> client that can traverse the whole path.

## 2026-09-04 — local config does not beat remote config (before the swap)

> Moved from `GITOPS.md` → *Flux / cloudflared / MinIO* in the 2026-10-05 docs pass, as it stood.

> ⚠️ **Local config does not beat remote config — `config_src` decides**
> Converting cloudflared to local management is two
> changes, not one, and only the first is a Kubernetes change.
>
> The credential half went cleanly. The token decodes to `{a,t,s}`, which maps
> exactly onto `{AccountTag,TunnelID,TunnelSecret}` — so a `credentials.json`
> built from it runs the *same* tunnel, with no new tunnel, no DNS edit, no
> Access change and no Worker secret. `cloudflared-token` stays in git as the
> rollback path.
>
> The ingress half did not. Given a `--config` file containing `ingress` rules
> **and** a valid credentials file, cloudflared connects, then takes its routing
> from the edge anyway and logs nothing about it. The only tell is content: the
> config it logged carried `warp-routing`, which the local file does not. The
> deciding field is `config_src` on the tunnel object — `cloudflare` (dashboard)
> or `local` (YAML on the origin) — and it is set at the API, so no manifest in
> this repo can change it.
>
> Consequence for sequencing: **the ConfigMap is inert until `config_src`
> flips**, and it is worth flipping only with the local rules already verified,
> which they are (`ingress validate` → OK; `ingress rule` resolves both
> hostnames to the right services and everything else to the 404 catch-all).
> The tidiest way to do it is the OpenTofu module (see [OpenTofu](../GITOPS.md#opentofu)), whose
> `cloudflare_zero_trust_tunnel_cloudflared` resource takes `config_src` — that
> closes this item and the Cloudflare-clickops item together, rather than
> spending a manual dashboard action on it now.
>
> Verified unaffected throughout: both hostnames returned `HTTP 403` before and
> after (Access rejecting at the edge, which is the healthy signal — a broken
> origin map would be `502`/`1033`), and all four QUIC connections re-registered.

## 2026-09-02 — unified media store: done while empty

> Moved from `GITOPS.md` → *Flux / cloudflared / MinIO* in the 2026-10-05 docs pass, as it stood.

Done while both buckets and both schemas were empty and before tunnel cutover:
no data moved, and no application code changed (`MINIO_BUCKET` and
`POSTGREST_SCHEMA` were already config vars). This was the cheapest the change
could ever be; after cutover it would mean migrating live objects and rows.

## 2026-09-02 — versioning note, when there were no backups

> Moved from `GITOPS.md` → *Flux / cloudflared / MinIO* in the 2026-10-05 docs pass, as it stood.

**Versioning is enabled** on `sunfire-guide-media`. Feature and local dev hold
`s3:DeleteObject` on what is now the only copy of every guide image, and there
are still no backups (Phase 5). Versioning makes an overwrite or delete
recoverable; it is not a substitute for snapshots, and Phase 5 matters more now.

## 2026-09-02 — unified media store: cluster conversion verified

> Moved from `GITOPS.md` → *Flux / cloudflared / MinIO* in the 2026-10-05 docs pass, as it stood.

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

## 2026-09-02 — Sun Clan Bingo decommissioned; rebrand to sunfire

> Moved from `README.md` → *Overview / The host* in the 2026-10-05 docs pass, as it stood.

> **History.** The original consumer was *Sun Clan Bingo*, decommissioned
> 2026-09-02. MinIO and PostgreSQL were kept for the successor Worker and
> everything was rebranded `bingo` → `sunfire`. That Worker is live.
>
> ⚠️ Some standing decisions were sized for the gap between apps, when nothing
> stored here had value. **Off-site backup has since been re-decided**: a monthly
> restic copy to Backblaze B2, live and restore-tested since 2026-09-21. The one
> shared Access service token is still as it was; see [`GITOPS.md`](../GITOPS.md).

## 2026-09-09 — correction: local-lvm is a BOSS-S2, not NVMe; 10.47 TiB of SAS SSD was missing

> Moved from `README.md` → *Overview / The host* in the 2026-10-05 docs pass, as it stood.

> ⚠️ **Corrected 2026-09-09.** This table read "LVM-thin on an **NVMe** RAID1
> pair" until the devices were enumerated. It is neither NVMe nor an OS-level
> RAID: it is a Dell BOSS-S2 card presenting two M.2 SATA SSDs as one
> hardware-mirrored virtual disk. The distinction is operational, not pedantic —
> **the OS cannot see the member disks**: no `/proc/mdstat` entry, no
> `zpool status`, and `smartctl /dev/sda` reads the *virtual* disk. A failed half
> of the boot mirror surfaces only in iDRAC or the BOSS CLI. Nothing here checks
> either — node-exporter is a DaemonSet on the three k3s **nodes**, so the
> Proxmox host is not scraped at all; [`HOST-MONITORING.md`](../HOST-MONITORING.md)
> is the plan to change that. See
> [`HARDWARE.md`](../HARDWARE.md#sda--local-lvm--the-boot-device-and-a-correction).
>
> The same enumeration found **10.47 TiB of SAS SSD that this table never
> mentioned** — three disks that previously carried bare ext4 filesystems with no
> redundancy (reclaimed and wiped 2026-09-09 per [`archive/SAS-RECLAIM.md`](SAS-RECLAIM.md)).
