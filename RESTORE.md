# Restore drill — CNPG + barman-cloud

Phase 5's last honest step. GITOPS.md states the reason in four words:
**untested backups aren't backups.** Everything else in Phase 5 produces
objects in a bucket; only this file proves those objects reconstruct a database.

Runs entirely against the Kubernetes API from the dev VM. Nothing here touches
`.101`, and nothing here writes to the live `sunfire` namespace.

> ✅ **Unblocked 2026-09-04.** Every precondition in §0 now holds: the CNPG cluster
> is healthy, `ContinuousArchiving=True`, and a completed base backup plus four
> WAL segments sit in `s3://sunfire-postgres-backups/`. The drill's PVC lands on
> the 64 GiB zvol (62 GiB free), not the root disk.
>
> Run this **before** PostgREST is cut over to the new cluster. While the old
> `postgres` Deployment is still authoritative, a failed drill costs nothing.

---

## 0. Preconditions

All four must hold, or the drill measures nothing:

```bash
# a backup exists and completed
kubectl -n sunfire get backups.postgresql.cnpg.io

# WAL is being archived (not just base backups)
kubectl -n sunfire get cluster postgres-cnpg \
  -o jsonpath='{.status.conditions[?(@.type=="ContinuousArchiving")]}{"\n"}'

# the plugin is registered and healthy
kubectl -n cnpg-system get pods -l app.kubernetes.io/name=plugin-barman-cloud

# the target node has room for a SECOND PGDATA
kubectl get --raw "/api/v1/nodes/k3s-worker2/proxy/stats/summary" \
  | python3 -c 'import json,sys;f=json.load(sys.stdin)["node"]["fs"];print(round(f["availableBytes"]/1024**3,2),"GiB free")'
```

A `Backup` in phase `completed` is the bar. `ContinuousArchiving=True` is the
one people skip, and it is the one that matters: a base backup with no WAL
behind it restores to exactly one frozen instant and cannot do PITR.

## 1. Why a scratch namespace, not a scratch cluster in `sunfire`

Two reasons, and the second is the sharp one:

1. It keeps every object of the drill inside one deletable boundary. Teardown is
   `kubectl delete ns`, with no risk of catching a live object in a label
   selector.
2. **Flux prunes `sunfire`.** `sunfire-postgres-cnpg` runs `prune: true`, so a
   hand-applied `Cluster` in that namespace is an object the Kustomization does
   not own — it survives, but every neighbouring object it might collide with
   *is* owned. Putting the drill somewhere Flux does not reconcile removes the
   whole question.

The scratch namespace is **deliberately not in git**. It is applied by hand,
verified, and destroyed. A drill that lives in the repo is a second production
database nobody remembers agreeing to.

## 2. The one trap: do not let the restored cluster archive

The restored cluster must **not** be a WAL archiver. If it is, it starts writing
into the same `s3://sunfire-postgres-backups/` destination and the catalogue now
has two writers.

CNPG namespaces the destination by `serverName`, which defaults to the cluster's
own name — so a differently-named scratch cluster writes to a different prefix
and would not literally overwrite the source. Do not rely on that. It is one
typo (`name: postgres-cnpg` copied verbatim into the scratch manifest) away from
a restored, diverged timeline archiving on top of the real one's WAL.

So: in the manifest below, the plugin appears **only** under
`externalClusters` — as a read path — and never under `spec.plugins`.

## 3. Apply the drill

```bash
kubectl create namespace pg-restore-drill
```

The credential and the ObjectStore both live in `sunfire` and are namespaced, so
the drill needs its own copies. The secret comes from the repo, decrypted
straight into the scratch namespace — it never lands on disk in plaintext:

```bash
cd ~/homelab
sops -d kubernetes/apps/sunfire/postgres-cnpg/app/objectstore-secret.sops.yaml \
  | sed 's/namespace: sunfire/namespace: pg-restore-drill/' \
  | kubectl apply -f -
```

Then the read-only ObjectStore and the recovery Cluster:

```bash
kubectl apply -f - <<'EOF'
---
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: postgres-backup-ro
  namespace: pg-restore-drill
spec:
  configuration:
    destinationPath: s3://sunfire-postgres-backups/
    endpointURL: http://minio.sunfire.svc.cluster.local:9000
    s3Credentials:
      accessKeyId:
        name: postgres-backup-s3
        key: ACCESS_KEY_ID
      secretAccessKey:
        name: postgres-backup-s3
        key: ACCESS_SECRET_KEY
---
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: pg-drill
  namespace: pg-restore-drill
spec:
  instances: 1
  # Must match the source cluster's image, or at least not be older than it.
  imageName: ghcr.io/cloudnative-pg/postgresql:16.15@sha256:34cd4159d07b3410a1b29da35072e2e927a0905e717a61afa3814624a2e8859a
  # Same node as the source. local-path is node-local, and on k3s-worker2 it
  # provisions into the archive-pool zvol (STORAGE.md) -- which is where the
  # free space in step 0 is actually being measured.
  affinity:
    nodeSelector:
      sunfire/role: postgres
  storage:
    size: 5Gi
    storageClass: local-path
  # NOTE: no `spec.plugins` block. See section 2 -- this cluster reads the
  # object store and must never write to it.
  bootstrap:
    recovery:
      source: source-backups
  externalClusters:
    - name: source-backups
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: postgres-backup-ro
          # The source cluster's name = its prefix under destinationPath.
          # Wrong value here fails as "no backup found", not as bad data.
          serverName: postgres-cnpg
EOF
```

Watch it come up. The recovery job pulls the base backup, then replays WAL:

```bash
kubectl -n pg-restore-drill get cluster pg-drill -w
kubectl -n pg-restore-drill logs -l cnpg.io/cluster=pg-drill --tail=50
```

`Cluster in healthy state` is the first half of the result. It is not the whole
result.

## 4. Verify the data, not the pod

A green `Cluster` proves Postgres started. It does not prove the *contents*
arrived. Compare the restored database against the live one, and check the roles
came with it — the role import is the part of this stack most likely to be
silently wrong, because `authenticator` without its password looks identical to
`authenticator` with it until PostgREST tries to log in.

```bash
# Row counts, restored vs. live. Run the same query against both.
kubectl -n pg-restore-drill exec -it pg-drill-1 -- \
  psql -U postgres -d sunfire -c \
  "select relname, n_live_tup from pg_stat_user_tables order by relname;"

kubectl -n sunfire exec -it $(kubectl -n sunfire get pod -l cnpg.io/cluster=postgres-cnpg \
  -o jsonpath='{.items[0].metadata.name}') -- \
  psql -U postgres -d sunfire -c \
  "select relname, n_live_tup from pg_stat_user_tables order by relname;"

# Roles and their attributes.
kubectl -n pg-restore-drill exec -it pg-drill-1 -- \
  psql -U postgres -c \
  "select rolname, rolcanlogin, rolinherit from pg_roles
     where rolname in ('sunfire','authenticator','anon','sunfire_readwrite')
     order by rolname;"

# Does authenticator actually authenticate? This is the real test.
kubectl -n pg-restore-drill exec -it pg-drill-1 -- \
  psql "postgres://authenticator:$(printf %s "$PW")@127.0.0.1:5432/sunfire" \
  -c "select current_user; set role sunfire_readwrite; select current_user;"
```

Expected: `rolcanlogin` true for `authenticator` only, `rolinherit` false for
`authenticator`, and the `SET ROLE` succeeding. Take `$PW` from
`sops -d kubernetes/apps/sunfire/postgres-cnpg/app/authenticator-secret.sops.yaml`
into a shell variable — do not paste it into a command line that lands in
history.

> ⚠️ **`kubectl exec` is refused by the assistant's tooling** (see the memory
> note and GITOPS.md → "k3s / storage substrate", "Three steps are yours").
> Every command in this
> section is yours to run.

## 5. PITR — the thing base backups alone cannot do

Worth doing once, because it is the only proof that WAL archiving works end to
end rather than just reporting `True`. Add a recovery target to the same
manifest and re-run with a fresh cluster name:

```yaml
  bootstrap:
    recovery:
      source: source-backups
      recoveryTarget:
        targetTime: "2026-09-04 03:00:00+00"
```

Pick a time *after* the base backup and *before* now. If the cluster reaches
that target and stops, PITR is real. If it can only ever restore to the base
backup's instant, WAL is not arriving and the ObjectStore's `wal:` block is
where to look.

## 6. Tear down

```bash
kubectl delete namespace pg-restore-drill
```

That deletes the Cluster, which deletes its PVCs through their
`ownerReferences`, which — because `local-path` reclaims `Delete` — deletes the
volume on the node. Confirm the disk actually came back, since that space is
scarce:

```bash
kubectl get --raw "/api/v1/nodes/k3s-worker2/proxy/stats/summary" \
  | python3 -c 'import json,sys;f=json.load(sys.stdin)["node"]["fs"];print(round(f["availableBytes"]/1024**3,2),"GiB free")'
```

Also confirm the drill left nothing in the bucket. It should not have written a
single object; if it did, section 2's rule was violated somewhere.

## 7. Record the result

Same discipline as `SANOID.md` §4. Write the date and the outcome into this
file when the drill passes:

| Date | Base backup restored | WAL replayed | PITR target hit | Roles verified |
|---|---|---|---|---|
| 2026-09-04 | ✅ 56s to healthy | ✅ | ✅ exact | ✅ hash-matched |

**2026-09-04 — first run, passed on every check.**

- `pg-drill` recovered from `s3://sunfire-postgres-backups/` and reached
  `Cluster in healthy state` in 56 seconds. Pod came up `1/1`, not `2/2` — no
  plugin sidecar, confirming §2's rule held: the drill never became an archiver.
- **Row counts matched exactly**: 57 in the restored database, 57 in the source.
- All four roles present with correct attributes, and the `SET ROLE` chain
  resolved `authenticator → sunfire_readwrite`.
- **`authenticator`'s password survived.** `pg_authid.rolpassword` is
  `SCRAM-SHA-256$…` in both, and the md5 fingerprints are identical
  (`a7080c9c9a705d645a62302e072aef79`), so it authenticates exactly as the source
  does. This was the check worth designing for — CNPG dumps roles without their
  hashes, so a NULL password here looks like a perfectly healthy cluster until
  PostgREST tries to connect. Verified by comparing fingerprints, never by
  handling the plaintext.
- **PITR proved exact**, not approximate. Two marker rows were written to a
  throwaway `pitr_test` schema at `01:06:20.46` and `01:06:41.07`, WAL was
  switched, and a second cluster (`pg-drill-pitr`) recovered with
  `targetTime: 01:06:30+00`. It came up holding **only** marker 1 — it stopped
  between the two writes. The first drill cluster, restored to an earlier point,
  correctly had no `pitr_test` schema at all. Two different recovery points from
  one catalogue, each landing where asked.
- **The drill wrote nothing.** The bucket contains only the `postgres-cnpg/`
  prefix; no `pg-drill*` objects exist.
- Teardown was clean: namespace deleted, no orphaned PVs, and the zvol went back
  to 62.01 GiB free of 62.44. The `pitr_test` schema was dropped from the source
  and `guide_media_assets` still reads 57 rows.

> The probe schema was deliberately **not** `public`. `PGRST_DB_SCHEMAS=public`,
> so a probe table in `public` would have entered PostgREST's schema cache and
> become visible over the tunnel the moment the cutover happened.

An untested backup is a belief. A backup tested once, a year ago, against a
schema that has since changed, is a slightly older belief.
