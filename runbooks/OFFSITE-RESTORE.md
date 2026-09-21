# Off-site restore drill — restic on Backblaze B2

> 🔁 **Standing runbook — meant to be re-run.** Run it after anything that
> touches the off-site path: the CronJob, the restic or Postgres image, the B2
> bucket or key, or the secret. Log each run in §4 rather than overwriting the
> last one. Same principle as [`RESTORE.md`](RESTORE.md): untested backups
> aren't backups.

The `offsite-backup` CronJob (`kubernetes/apps/sunfire/offsite-backup/`) puts a
monthly, client-side-encrypted copy of the `sunfire` database and the guide
media into B2. Design and trade-offs: `GITOPS.md` → CloudNativePG →
*Off-site backup*. This file proves that the copy restores.

Two procedures: §2 is the routine drill, run from the dev VM against the live
cluster, which reads B2 and writes nothing live. §3 is the real thing, for
when the chassis is gone.

---

## 1. What is in a snapshot

Paths inside a snapshot are **relative to `/work/data`**, even though
`restic snapshots` lists them as `/work/data/…`:

```
/postgres/sunfire.dump   pg_dump -Fc of the sunfire database (no roles)
/media/<sha256>.<ext>    every object in sunfire-guide-media
```

`--include /postgres` works; `--include /work/data/postgres` silently restores
0 files. That cost one failed attempt on the first drill.

Roles are **not** in the dump. They come from `postgres-cnpg/app/cluster.yaml`
(`managed.roles`) and the grants in `sunfire/homelab/postgres/0002_grants.sql`.

## 2. Routine drill (in-cluster, from the dev VM)

Restores the dump from B2 into a throwaway Postgres pod and compares it row by
row with the live database. Uses the `offsite-backup` Secret, so no credential
leaves the cluster.

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: { name: offsite-restore-test, namespace: sunfire }
spec:
  restartPolicy: Never
  initContainers:
    - name: restore
      image: docker.io/restic/restic:0.19.1
      command: ["/bin/sh", "-c"]
      args:
        - restic restore latest --tag monthly --include /postgres
            --target /r --no-cache && ls -l /r/postgres
      env:
        - name: RESTIC_REPOSITORY
          valueFrom: { secretKeyRef: { name: offsite-backup, key: RESTIC_REPOSITORY } }
        - name: RESTIC_PASSWORD
          valueFrom: { secretKeyRef: { name: offsite-backup, key: RESTIC_PASSWORD } }
        - name: AWS_ACCESS_KEY_ID
          valueFrom: { secretKeyRef: { name: offsite-backup, key: B2_KEY_ID } }
        - name: AWS_SECRET_ACCESS_KEY
          valueFrom: { secretKeyRef: { name: offsite-backup, key: B2_APP_KEY } }
      volumeMounts: [{ name: r, mountPath: /r }]
  containers:
    - name: pg
      image: docker.io/library/postgres:16.15-alpine
      env: [{ name: POSTGRES_HOST_AUTH_METHOD, value: trust }]
      volumeMounts: [{ name: r, mountPath: /r }]
  volumes: [{ name: r, emptyDir: {} }]
EOF
```

Pin the images to the digests in `cronjob.yaml` when you run this. Then:

```bash
T='kubectl -n sunfire exec offsite-restore-test -c pg --'
L='kubectl -n sunfire exec postgres-cnpg-1 -c postgres --'
$T createdb -U postgres sunfire
$T pg_restore -U postgres -d sunfire --no-owner \
  --no-privileges /r/postgres/sunfire.dump
Q="select id::text||' '||md5(t::text)
   from public.guide_media_assets t order by id"
$T psql -U postgres -d sunfire -AtX -c "$Q" | md5sum
$L psql -U postgres -d sunfire -AtX -c "$Q" | md5sum
kubectl -n sunfire delete pod offsite-restore-test
```

**Pass:** `pg_restore` exits 0 and the two hashes match. A mismatch is not
automatically a failure: the snapshot is up to 30 days old, so rows written
since then differ. Compare counts and the newest `uploaded_timestamp` before
calling it broken.

## 3. Disaster restore (host gone)

From any machine with `restic`. Needs the **restic password from LastPass**
and a B2 key for the bucket. Create a fresh read-only key in the Backblaze
console if the one in the SOPS secret is out of reach.

```bash
export RESTIC_REPOSITORY='s3:https://<endpoint>/<bucket>/sunfire'
export AWS_ACCESS_KEY_ID='<b2 key id>'
read -rs AWS_SECRET_ACCESS_KEY; export AWS_SECRET_ACCESS_KEY
read -rs RESTIC_PASSWORD; export RESTIC_PASSWORD
restic snapshots --tag monthly
restic restore latest --tag monthly --target ./restore
```

Then, once a Postgres 16+ and a MinIO (or any S3) exist again:

1. Create the roles: apply `cluster.yaml` (CNPG) or run the grants SQL.
2. `pg_restore -d sunfire ./restore/postgres/sunfire.dump`
3. `mc mirror ./restore/media <alias>/sunfire-guide-media`, matching object
   keys, because the database rows point at them by `object_key`.

Data written after the snapshot is lost. That is the accepted cost of monthly.

## 4. Run log

| Date | Snapshot | Result |
|---|---|---|
| 2026-09-21 | `cd4a985a` (first, 84.9 MiB) | ✅ `restic check` clean; `pg_restore` exit 0; 58/58 rows hash-identical to live |
