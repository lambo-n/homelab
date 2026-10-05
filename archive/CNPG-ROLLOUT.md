# CNPG rollout, off-site backup and Reloader — dated findings

> 📦 **Archived 2026-10-05.** Verification runs, cutover findings and decisions
> from bringing up CloudNativePG, the off-site backup and Reloader. Current
> state: [../GITOPS.md](../GITOPS.md#cloudnativepg--plugin-barman-cloud),
> [Reloader](../GITOPS.md#reloader).

## 2026-09-08 — plugin chart 0.8.0: CRD templating, and what the upgrade did

> Moved from `GITOPS.md` → *CloudNativePG / Off-site backup / Reloader* in the 2026-10-05 docs pass, as it stood.

> **Plugin chart 0.8.0 landed 2026-09-08, and its CRD is templated, not shipped in
> `crds/`.** Both 0.7.1 and 0.8.0 carry `objectstores.barmancloud.cnpg.io` as an
> ordinary template (`templates/crds/crds.yaml`, gated on `.Values.crds.create`,
> default true) — confirmed by pulling both charts from ghcr. That matters because
> a templated CRD is part of the release manifest and Helm upgrades it normally, so
> **the `crds: CreateReplace` policy that kube-prometheus-stack needs would be a
> no-op here** and must not be copied over. The HelmRelease says so inline, since
> the asymmetry between the two files otherwise reads as an oversight. The CRD also
> carries `helm.sh/resource-policy: keep`, so uninstalling the plugin leaves it and
> every `ObjectStore` behind.
>
> Verified after the upgrade: `plugin-barman-cloud.v2` reports `Helm upgrade
> succeeded`, the pod is 1/1, and the Cluster's `ContinuousArchiving` condition
> still carries its original `2026-09-04` `lastTransitionTime` — it never flipped,
> so WAL archiving did not break across the upgrade. `Ready` and
> `ConsistentSystemID` did re-transition at 18:19, i.e. the database was briefly
> not-Ready while the plugin rolled. A *base* backup under 0.8.0 had not yet run at
> that point; `LastBackupSucceeded` was still 02:30, from before.

## 2026-09-04 — CNPG live and verified (not yet the cutover)

> Moved from `GITOPS.md` → *CloudNativePG / Off-site backup / Reloader* in the 2026-10-05 docs pass, as it stood.

> ✅ **CNPG is live and verified 2026-09-04.** Bootstrapped in 76 seconds from the
> live Deployment via `bootstrap.initdb.import` (monolith). Verified, not assumed:
>
> | Check | Result |
> |---|---|
> | Cluster phase | `Cluster in healthy state`, 1/1, primary `postgres-cnpg-1` |
> | Roles imported | all four, `authenticator` with `rolcanlogin=t rolinherit=f` |
> | Memberships | `authenticator → anon`, `authenticator → sunfire_readwrite` |
> | Table | `public.guide_media_assets`, owner `sunfire` |
> | PGDATA location | `/var/lib/rancher/k3s/storage/pvc-…` on `k3s-worker2` — **the zvol** |
> | WAL archiving | `archived_count=1`, `failed_count=0`, `ContinuousArchiving=True` |
> | Base backup | on-demand `Backup` completed; `LastBackupSucceeded=True` |
> | Objects in MinIO | `base/20260904T005414/{backup.info,data.tar.gz}` + 4 WAL segments |
>
> The kubelet's per-volume stats make the storage split visible: `pgdata` reports
> **62.44 GiB** capacity while the pod's other volumes report 17.83 GiB — the root
> disk. PGDATA genuinely is not sharing a filesystem with the OS.
>
> ⚠️ **This is not the cutover.** `PGRST_DB_URI` still names
> `postgres.sunfire.svc.cluster.local`, so PostgREST reads the *old* Deployment and
> the CNPG cluster sits idle apart from archiving. **Both databases are live and
> will now drift.** Repointing PostgREST at `postgres-cnpg-rw` is its own commit,
> and `runbooks/RESTORE.md` should run before it — the drill is what proves the new stack is
> recoverable, and it is far cheaper to find a problem while the old Deployment is
> still authoritative.

## 2026-09-04 — the bootstrap's dangling legacy Service

> Moved from `GITOPS.md` → *CloudNativePG / Off-site backup / Reloader* in the 2026-10-05 docs pass, as it stood.

> ⚠️ **The CNPG bootstrap still names the legacy Service, and that is not a live
> dependency — until it is.** `cluster.yaml` declares
> `externalClusters: postgres-legacy` at `postgres.sunfire.svc.cluster.local` and
> imports from it. That is read **once at cluster creation and never again**;
> `postgres-cnpg` is `Initialized`, so it will not reach for it. But deleting and
> recreating that Cluster from git — which is exactly what a naive "let Flux
> rebuild it" would do — would run the bootstrap against a hostname that no
> longer resolves, since the Service was deleted on 2026-09-04. **Rebuild from
> the barman backups instead**, which is the path with a passing restore drill
> behind it. Reviving the legacy source is now a git-history operation: recover
> `deployment.yaml` and `service.yaml` from the commit that removed them. The
> live Cluster is unaffected either way — verified `healthy` with the dangling
> reference in place.

## 2026-09-04 — the rollback value of the legacy database decays

> Moved from `GITOPS.md` → *CloudNativePG / Off-site backup / Reloader* in the 2026-10-05 docs pass, as it stood.

> ⚠️ **The rollback value decays, and the clock is now running.** The legacy data
> is frozen at the 2026-09-04 cutover. Every write CNPG takes since makes rolling
> back to it a data-loss event rather than a recovery, and at some point the
> honest recovery path is the backups, not this. That was theoretical while no
> successor Worker existed; **the Worker is live on `sunosrs.cc`**, so every write
> it takes moves this further past the point of being a recovery at all. This is
> the clock the PV/PVC item above was waiting on — it has arrived, and the
> retirement is now a decision to make rather than one to defer.

## 2026-09-21 — legacy PGDATA volume retired

> Moved from `GITOPS.md` → *CloudNativePG / Off-site backup / Reloader* in the 2026-10-05 docs pass, as it stood.

> ✅ **Retired 2026-09-21.** `postgres-pvc`/`postgres-pv` were deleted by hand
> (`sunfire-storage` never prunes) and removed from git. First the frozen PGDATA
> was compared row by row with CNPG, by starting `postgres:16.15` on a *copy*
> in a throwaway pod. The volume held only `sunfire`: one table, 58 rows, the
> same four roles, and **no bingo data**, which had been dumped separately on
> 09-02. 56 rows matched exactly, and row 30 was older than CNPG's copy (the
> soft-delete landed after the import). Row 58 was the one real gap:
> **`bomb.png` was uploaded at 00:58, after the import (~00:54) but before
> PostgREST was repointed**, so its row reached only the legacy database, and
> CNPG later reused id 58 for another upload. Its object is still in MinIO
> (`5f0a837a…5cc5e.png`, 22,824 B), but with no row the media route 404s. The
> owner judged it safe to lose. **The lesson for any future cutover: freeze
> writes on the source between the import and the repoint, or diff the two
> afterwards, because both "live" signals looked healthy throughout.**
> The ZFS dataset `archive-pool/postgres-data` is destroyed on the host
> separately (see `SANOID.md`).

## 2026-09-02 / 2026-09-21 — R2 rejected, then off-site backup decided

> Moved from `GITOPS.md` → *CloudNativePG / Off-site backup / Reloader* in the 2026-10-05 docs pass, as it stood.

**R2 rejected** — but note the original reasoning is now void. It was: the 10 GB free tier is
shared with the production bingo app's buckets, so backups would push it toward billing. **That app
is decommissioned (2026-09-02)**; there is no shared budget and no bingo-era gallery data to
protect. MinIO's two buckets today are `sunfire-guide-media` and
`sunfire-postgres-backups`, both created after that decision.

## 2026-09-21 — off-site backup revisited

> Moved from `GITOPS.md` → *CloudNativePG / Off-site backup / Reloader* in the 2026-10-05 docs pass, as it stood.

**Revisited and resolved 2026-09-21.** The standing reason to skip off-site backup was that no
successor app existed. Once the Worker went live on `sunosrs.cc`, that premise was spent. The
decision was remade on the data's value: a **monthly restic copy to Backblaze B2**, not R2 (see
*Off-site backup* below). Local backups (sanoid, barman) still all land in the same chassis. The
B2 copy is the only one that survives losing `.101`, and it trails by up to a month.

## 2026-09-03 / 2026-09-21 — VolSync deferred, then dropped

> Moved from `GITOPS.md` → *CloudNativePG / Off-site backup / Reloader* in the 2026-10-05 docs pass, as it stood.

> **VolSync is deferred, not scheduled** *(2026-09-03)*. The line item read
> "VolSync for the MinIO PVC (only non-DB stateful volume)" and never said where
> the replica would go. Working that through, there is no answer on this cluster:
>
> | Destination | Why not |
> |---|---|
> | MinIO itself (restic → `s3://…`) | The repository would live inside the volume being replicated. Circular |
> | A `local-path` PVC on a worker | 2.7 GiB free, per the [worker-disk blocker](../GITOPS.md#k3s--storage-substrate) |
> | A second NFS PV or zvol on `archive-pool` | Same pool sanoid already snapshots. A second copy that dies with the first |
>
> The [PGDATA zvol decision](../GITOPS.md#k3s--storage-substrate) does not change this. It gives `archive-pool`
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
> that is not `.101` — the same condition as the off-site question above, which
> the live Worker has now put back on the table. Deferring VolSync and deferring
> off-site backup are one decision, not two: pick the destination first, and
> VolSync either becomes the mechanism or stays unnecessary.
>
> **Resolved 2026-09-21: it stays unnecessary.** The destination is B2, and the
> mechanism is a plain restic CronJob (below). It mirrors MinIO through the S3
> API rather than reading its data directory, so the live-directory problem
> above does not arise, and there is no VolSync operator to run.
> `archive-pool/minio-data` gets sanoid, and after the CNPG cutover it holds the
> Postgres backups too — that is the dataset that matters, and `SANOID.md`
> already says so.

## 2026-09-21 — off-site backup verified

> Moved from `GITOPS.md` → *CloudNativePG / Off-site backup / Reloader* in the 2026-10-05 docs pass, as it stood.

✅ **Verified 2026-09-21.** First snapshot `cd4a985a`, 84.9 MiB, and `restic
check` found no errors. A manual run of the CronJob then took the "0d old: not
due" path. `sunfire.dump` restored **from B2** into a throwaway
`postgres:16.15`: `pg_restore` exited 0, and all 58 rows hashed identically to
the live database.

## 2026-09-04 — Reloader deployed and proven, and the Flux/rollout-restart finding

> Moved from `GITOPS.md` → *CloudNativePG / Off-site backup / Reloader* in the 2026-10-05 docs pass, as it stood.

> ✅ **Reloader deployed and proven 2026-09-04** (Phase 6, pulled forward). Not
> assumed to work — tested the same way the backups were. A throwaway
> `reloader-drill` namespace held a Deployment reading one value from a Secret
> via `secretKeyRef`. Rotating the Secret `v1` → `v2`, **without touching the
> Deployment at all**, produced a new pod serving `value=v2` in ~33 seconds, and
> Reloader's own log named it:
>
> ```
> Changes detected in 'probe' of type 'SECRET' in namespace 'reloader-drill';
> updated 'probe' of type 'Deployment' in namespace 'reloader-drill'
> ```
>
> Namespace torn down afterwards. All four sunfire Deployments now carry the
> annotation, so the gap below is closed going forward.
>
> **Second-order finding: a manual `kubectl rollout restart` does not survive
> Flux.** The restart annotation lands on the pod *template*, which Flux owns via
> server-side apply — so the next reconcile strips it and rolls the Deployment
> back to the git spec, restarting the pod a second time. Harmless here (the
> Secret change is what actually persisted, and PostgREST came back on
> `postgres-cnpg-rw` either way), but it means a hand-rolled restart is a
> temporary state under GitOps, not a fix. With Reloader in place there is no
> longer a reason to reach for one.

## 2026-09-04 — the PostgREST cutover that silently no-opped

> Moved from `GITOPS.md` → *CloudNativePG / Off-site backup / Reloader* in the 2026-10-05 docs pass, as it stood.

> ⚠️ **A Secret change does not restart the pod — the cutover silently no-opped
> at first** *(found 2026-09-04)*. After the `PGRST_DB_URI` commit, Flux reported
> `sunfire-postgrest` Ready at the new revision and the in-cluster Secret held the
> new host — but `kubectl get pods` showed the PostgREST pod still **84 minutes
> old**. Env vars from `secretKeyRef` are read once at container start, so
> PostgREST was still connected to the *old* database while every status signal
> said the cutover had landed. A `kubectl rollout restart` fixed it, and the logs
> then named `postgres-cnpg-rw` explicitly.
>
> This is the sharpest argument yet for **Reloader**, which sits in Phase 6 as a
> convenience item. It is not a convenience: without it, every future secret
> rotation — the JWT signing key, the MinIO Worker credentials, the tunnel token —
> reports success and changes nothing until someone notices. Worth promoting.
> Until it lands, treat "rolled a Secret" as an incomplete action: check pod AGE,
> not Kustomization status.
>
> Cutover verification, for the record: PostgREST logs name
> `postgres-cnpg-rw.sunfire.svc.cluster.local:5432` and load a schema cache of 1
> relation; the CNPG cluster shows `authenticator` connected from the PostgREST
> pod; and a signed request returns `HTTP 206` with `Content-Range: 0-0/57` while
> an anonymous one returns `401`.
>
> **No Cloudflare Worker maintenance was required**, as predicted:
> `PGRST_JWT_SECRET` was untouched (sha256 identical before and after), and
> `POSTGREST_URL`, `POSTGREST_SCHEMA`, the Access service token and every
> `MINIO_*` value are unaffected. `PGRST_DB_URI` is cluster-only; the Worker never
> sees it. No Wrangler push, no app redeploy.
