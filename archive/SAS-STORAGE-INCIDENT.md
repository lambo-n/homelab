# `sas-pool` import failure — investigation and fix (2026-09-15/16)

> 📦 **Archived 2026-09-16 — investigation complete, fix proven.** The standing
> warning and fix are in [`../SAS-STORAGE.md`](../SAS-STORAGE.md); this is the
> full incident record.

`sas-pool` was found **not imported** while running the GPU-VM build's A2 step,
and had been since the host booted for the GPU install on 2026-09-15 14:20 PDT.
The owner imported it (**140 GiB intact, no data lost**) and enabled
`zfs-import-scan`.

**Why it happened, and why nothing complained:**

- **This pool has no owner for its import.** It is host-native and *not* in
  `/etc/pve/storage.cfg`, so nothing brings it up at boot. `archive-pool` is a
  PVE storage, so `pvestatd` activates it — which is why that one was imported
  and snapshotting all evening while this one sat idle. The difference is not
  ZFS, it is who owns the import.
- On that boot `/etc/zfs/zpool.cache` was missing or empty, so
  `zfs-import-cache` skipped itself on `ConditionFileNotEmpty`, and
  `zfs-import-scan` was **disabled**. Nothing was left to try.
- `smbd` started regardless and served `/sas-pool` — an **empty directory** —
  as the `[data]` share, and `sanoid` kept firing every 15 minutes against a
  dataset that did not exist. **Both dependants reported healthy.**

**The durable fix is `systemctl enable zfs-import-scan`, not the cachefile.**
The PVE ZFS plugin imports with `-o cachefile=none`, so `zpool get cachefile`
reads `none`/`local` and setting it back to `/etc/zfs/zpool.cache` can be
reverted on the next activation. `zfs-import-scan` protects both pools.

⚠️ **`zpool status -x` does not catch this.** An unimported pool is not
unhealthy, it is absent, and `-x` happily reports "all pools are healthy."
After any reboot of `.101`, check **`zpool list`** and confirm all three pools
are present by name before trusting `/sas-pool/data` or the `[data]` share.

✅ **Fix proven across a real reboot, 2026-09-16 00:48 PDT.** The GPU-VM
build's B2 power cycle was the same kind of boot that dropped the pool the
first time, and `sas-pool` imported on its own alongside `archive-pool` and
`llm-pool`. `zpool list` then read `ALLOC 210G` — raw space including RAIDZ1
parity, ~1.5 × the ~140 GiB `USED` seen at recovery, not new data.

## The unbind really did fault the pool — evidence recovered 2026-09-10

During the 2026-09-09 TrueNAS passthrough attempt, unbinding `c3:00.0` was
reasoned to detach `archive-pool` (all 8 front bays share that controller).
ZED had in fact logged it happening: three `ZFS device fault for pool
archive-pool` events at **15:53:45** and a `ZFS resilver_finish` at **15:57:42**
on 2026-09-09. `archive-pool` lost its members, faulted, and resilvered itself
in four minutes once they came back — short because nothing had changed in the
interval.

**Nobody saw any of it for hours.** The notifications were found sitting in the
postfix queue while fixing an unrelated mail problem
([`../HOST-MONITORING.md`](../HOST-MONITORING.md) → SMART tests) —
`/etc/aliases.db` had never been built, so every message this host ever
generated was deferred, unread.

Two things worth keeping from that. ZED's side worked perfectly: the pool
holding the live MinIO data and the Postgres NFS PV faulted, and the host said
so immediately, in detail, to an address that could not receive it. **The
detection was never the missing piece — the delivery was.** And a documented
risk had already become a logged event without anyone noticing, which is the
strongest available argument for the cluster-side half of host monitoring
(tracked in [`../BACKLOG.md`](../BACKLOG.md)).
