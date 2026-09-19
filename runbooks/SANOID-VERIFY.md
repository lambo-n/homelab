# sanoid rollback drill — verify a snapshot is actually restorable

> 🔁 **Standing runbook — meant to be re-run, not a one-time task.** An
> untested snapshot is a belief, not a backup. Re-run this whenever a new
> dataset is added to `sanoid.conf` (see [`../SANOID.md`](../SANOID.md)) and
> periodically thereafter — record each run in the log at the bottom rather
> than overwriting it.

**Do not test with `zfs rollback` on live data.** Clone the snapshot and
inspect the clone; that proves the snapshot is readable and complete without
risking the original. Runs on the Proxmox host `192.168.50.101` as root.

**For a filesystem dataset** (e.g. `minio-data` — the clone mounts itself):

```bash
SNAP=$(zfs list -t snapshot -o name -s creation -H -r archive-pool/minio-data | tail -1)
echo "$SNAP"
zfs clone "$SNAP" archive-pool/restore-test
ls -la /archive-pool/restore-test
# expect the MinIO layout: .minio.sys/ plus the bucket directories
du -sh /archive-pool/restore-test
zfs destroy archive-pool/restore-test
```

**For the PGDATA zvol, the same procedure does not apply.** A zvol clone is a
*block device*, not a directory — there is nothing to `ls`. It appears under
`/dev/zvol/` and carries an ext4 filesystem:

```bash
SNAP=$(zfs list -t snapshot -o name -s creation -H -r archive-pool/vm-104-disk-0 | tail -1)
echo "$SNAP"
zfs clone "$SNAP" archive-pool/pgdata-restore-test
udevadm settle
blkid /dev/zvol/archive-pool/pgdata-restore-test
# expect: TYPE="ext4" LABEL="pgdata"
zfs destroy archive-pool/pgdata-restore-test
```

`blkid` recognising the filesystem is the right stopping point. **Do not mount
it to look inside.** The snapshot is crash-consistent — taken while Postgres
was running — so the ext4 journal is dirty and mounting would replay it, and
mounting a live database's filesystem image on the hypervisor is a good way to
confuse yourself about which copy is real. If you ever genuinely need the
contents, mount `-o ro,norecovery` and treat what you see as a crash image.

Record the date and outcome below. An untested snapshot is a belief, not a
backup.

## Log

| Date | Datasets checked | Result |
|---|---|---|
| 2026-09-04 | `minio-data`, PGDATA zvol (`vm-104-disk-0`) | ✅ Both clones passed. `minio-data` clone showed the real layout (`.minio.sys/`, both buckets, 97 M). Zvol clone's `blkid` UUID (`47470f9d-…`) matched the filesystem's creation-time UUID exactly. |
| 2026-09-09 | `ts-ssh-records` | ✅ Initial snapshots confirmed (monthly/daily/hourly, 108K REFER) after being added to the `archival` template. |
| 2026-09-09 | `sas-pool/data` | ✅ Initial snapshots confirmed across the new RAIDZ1 pool; 17 tabs verified in the config. |
