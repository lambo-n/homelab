# PGDATA on a zvol — the decision record

> 📦 **Archived 2026-10-05.** How PGDATA came to live on a zvol on
> `archive-pool`: the worker-disk blocker, the `local-path` decision it
> superseded, the withdrawn fsync cost, and the hand-off steps. Host-side
> procedure: [STORAGE.md](STORAGE.md). Current state:
> [../GITOPS.md](../GITOPS.md#k3s--storage-substrate).

## 2026-09-03 — the storage substrate decision: blocker, superseded plan, costs and hand-off

> Moved from `GITOPS.md` → *k3s / storage substrate* in the 2026-10-05 docs pass, as it stood.

> Figures refreshed 2026-09-03 from `pvesm status` on `.101`. The pool rebuild is
> **complete**: 5 × 1.92 TB raidz2 (5.03 TiB) became a 3-way mirror (1.68 TiB),
> freeing two drives — one of which is now `llm-pool`, the other a cold spare
> ([`HARDWARE.md`](../HARDWARE.md)). Earlier revisions of this table read "~14 TB,
> ZFS w/ redundancy", then "8.72 TiB raw / 5.03 TiB usable" — both are now
> historical.
>
> ⚠️ **The "no VM disk is on ZFS" invariant is retired, deliberately.** It was
> repeated across older revisions of these documents as the reason
> `archive-pool` could be destroyed without touching a VM. PGDATA now sits on a
> **zvol** on that pool, so: destroying, exporting or rebuilding `archive-pool`
> takes `k3s-worker2`'s data disk with it, and pool work requires the VM stopped
> first. The other guests stay on `local-lvm`, except VM 105's models disk on
> `llm-pool`.

> ✅ **Blocker found and cleared 2026-09-03: the worker root disks were 9.75 GiB.**
> Phase 5's original decision — move PGDATA onto `local-path` — quietly assumed
> the k3s nodes had room for it. They did not. Measured from the kubelet
> (`/api/v1/nodes/<node>/proxy/stats/summary`):
>
> | Node | Root fs | Used | Available | After `lvextend` |
> |---|---|---|---|---|
> | `k3s-control` | 9.75 GiB | 4.45 | 4.78 | *not yet grown* |
> | `k3s-worker1` (minio) | 9.75 GiB | 6.51 | 2.72 | **17.83 GiB, 10.45 free** |
> | `k3s-worker2` (postgres) | 9.75 GiB | 6.54 | **2.69** | **17.83 GiB, 10.42 free** |
>
> The cause was the stock Ubuntu Server installer: an 18.22 GiB VG on `sda3`
> with only a 10 GiB root LV carved out of it. No Proxmox resize and no
> thin-pool space were needed — `lvextend -l +100%FREE` plus `resize2fs`, online,
> on each worker. `archive/STORAGE.md` §6 records it.
>
> Note `.status.allocatable.ephemeral-storage` still reports the pre-growth
> figure afterwards: kubelet caches it from cadvisor machine info and refreshes
> on restart. Eviction and `DiskPressure` use the live stats and were correct
> immediately, so this is cosmetic unless a pod declares an explicit
> `ephemeral-storage` request. Nothing here does.
>
> This did **not** make `local-path` on the root disk an acceptable home for
> PGDATA — a bigger shared filesystem is the same absent boundary. The zvol
> decision below stands on its own reasoning.
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
> unarchived WAL in PGDATA until the archiver drains it, and this cluster does not
> guarantee 100% uptime — power outages and by-hand maintenance both take it down,
> so MinIO being unreachable is an expected state rather than an exception, and WAL
> accumulating against a 2.69 GiB ceiling is a path to plan for, not a tail risk.
> There is no CNPG knob that bounds it without also throwing away recoverability;
> the fix is a real device.
>
> ✅ **Resolved by the zvol decision below, not by growing the root disk.**
> Growing the root disk would have left the database sharing a filesystem with
> the OS and the image store — a bigger disk, same absent boundary. Putting
> PGDATA on its own block device makes the device the ceiling, and putting that
> device on `archive-pool` puts it on the storage that exists for exactly this.
> `storage:` is now `64Gi`, matching the zvol, so the manifest states a number
> something actually enforces. The root disks still grow to ~24 GiB, for
> container-image churn only. Host-side procedure: `archive/STORAGE.md`.
>
> One thing this does *not* invalidate: the manifests are correct. All three
> objects pass
> `kubectl apply --dry-run=server` against the live CRDs, the `dependsOn` targets
> all exist, `sunfire/role: postgres` is on `k3s-worker2`, and the SOPS
> `authenticator` password was confirmed byte-identical to the one embedded in
> the live `PGRST_DB_URI`. The design is sound; the substrate was never sized
> for it.

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
> `k3s-worker2` stopped. *(2)* ~~SATA SSD mirror instead of NVMe, so higher fsync
> latency.~~ **Withdrawn 2026-09-09: this cost does not exist.** `local-lvm` is
> not NVMe — it is a Dell BOSS-S2 pair of M.2 **SATA** SSDs (`HARDWARE.md`), so
> both sides of this comparison are SATA and the fsync trade is a wash. The
> claim was inherited from `README.md`, which asserted NVMe until the devices
> were enumerated. *(3)* PGDATA and its barman
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
> data lands there. See `archive/STORAGE.md`.

> **Three steps are yours, not the assistant's** *(was two; the disk grow is
> new)*. `kubectl exec` against a pod is
> refused by this environment's tooling *(true when written; no longer true
> since at least 2026-09-21: see AGENTS.md rule 3)*, and `.101` had no SSH key
> for the dev VM either *(no longer true; scoped now to the Ansible host-config layer — see AGENTS.md rule 3)* <!-- doc-history:ignore -->. So: `scripts/minio-barman-account.sh` (creates the backup bucket and a
> service account scoped to it, and writes the credential into the repo already
> SOPS-encrypted — the keys are generated in the pod, piped into `sops`, and
> never printed), and `SANOID.md` in full. The barman account deliberately
> **does** hold `s3:ListBucket`, unlike the Worker accounts one layer down —
> barman needs to list WALs and backups. Same reasoning, opposite answer; it is
> not a copy-paste slip.
>
> The third is **`archive/STORAGE.md`** — creating the PGDATA zvol on `archive-pool`,
> attaching it to `k3s-worker2`, and growing the three root disks for image
> churn. Proxmox has no Kubernetes API to reach it through, and the zvol now
> gates the CNPG cutover. `runbooks/RESTORE.md` is likewise yours to execute end to end;
> it is written and blocked on the same volume, since a restore drill needs a
> second PGDATA alongside the live one.
