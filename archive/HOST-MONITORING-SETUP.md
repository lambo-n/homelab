# Host monitoring — setup log (G1–G7)

> 📦 **Archived 2026-09-16.** G1 (SMART long tests) is the one goal in
> [`../HOST-MONITORING.md`](../HOST-MONITORING.md) that's fully built and
> verified; this is the debugging record from doing it. The current
> configuration is summarized in that file; the remaining goals (G2–G7) are
> tracked in [`../BACKLOG.md`](../BACKLOG.md).
>
> *This file originally numbered the goals `A1`–`A6` + "Part B"; they were
> renumbered `G1`–`G7` in `HOST-MONITORING.md`. Same goals, one scheme.*

`smartmontools` is already installed on PVE and `smartmontools.service` is
enabled by the package.

## The DEVICESCAN trap

⚠️ **`DEVICESCAN` silently voids everything after it.** PVE ships
`/etc/smartd.conf` with an active
`DEVICESCAN -d removable -n standby -m root -M exec /usr/share/smartmontools/smartd-runner`
on line 19, and — as that file's own comments state — **the word DEVICESCAN
causes every remaining line in the file to be ignored.** Per-drive directives
appended at the bottom parse as nothing at all, `smartd` restarts cleanly, and
no self-test is ever scheduled. Found the hard way on the first attempt here.

Comment it out. Once it is off, **only listed devices are monitored**.

⚠️ **Keep `-m root -M exec /usr/share/smartmontools/smartd-runner` on every
line.** That pair is how Debian actually delivers a smartd warning — it runs
the scripts in `/etc/smartmontools/run.d/`. `DEVICESCAN` carried it; a
hand-written drive line that omits it logs the failure and mails no one.

## Adding the `llm-pool` line, 2026-09-16

`smartd -q onecheck` opened `…150584Y` as `[SAT]` and added it to the monitor
list, and after a restart the journal reads `Monitoring 4 ATA/SATA, 3 SCSI/SAS
and 0 NVMe devices`. It gets its own day (Friday) because it is the pool with
no redundancy.

Two things learned adding it:

- **The unit is `smartmontools.service`.** `smartd` is only an alias:
  `systemctl is-active smartd` follows it, but **`journalctl -u smartd` does
  not** and prints `-- No entries --`. Use `journalctl -u smartmontools`.
- **Don't retype a by-id line.** The first attempt was typed by hand and came
  out with three wrong characters in the path, and `smartontools` in the runner
  path. Build the line from ZFS's own record of the disk and an existing
  working line instead:
  ```bash
  D=$(zpool status -P llm-pool | awk '/by-id/ {sub(/-part1$/,"",$1); print $1}')
  grep 'MTFDDAK1T9TDT_222939CA58D4' /etc/smartd.conf | sed "s#^[^ ]*#$D#; s#/7/03#/5/03#" >> /etc/smartd.conf
  ```

⚠️ **SMART on the SK hynix `HFS1T9G3H2X069N` (FW `DZ02`) is thin**, per smartd:
`not capable of SMART Health Status check`, no Attribute 197
(`Current_Pending_Sector`), `no SMART Self-test Log`, `no SMART Error Log`. So
smartd cannot raise a health-FAILED alert and cannot report self-test results
for this model. What it can watch is temperature (`-W 4,45,55`) and attribute
threshold crossings. For these disks the **ZFS scrub's checksum errors are the
more meaningful early warning**, especially on `llm-pool`, which has no second
copy to repair from.

## Verify the parse, do not trust a clean restart

```bash
smartd -d -q onecheck 2>&1 | grep -E 'Monitoring|Device:|Next'
```

All devices must be named. Anything absent is a line smartd never read.

```bash
systemctl restart smartmontools.service
systemctl is-enabled smartmontools.service
```

> **`systemctl enable smartd` fails** with `Refusing to operate on linked unit
> file smartd.service` — `smartd.service` is an alias symlink on Debian. The
> real unit is `smartmontools.service`, and the package already enables it, so
> this error is cosmetic.

## The mail delivery incident, 2026-09-10

`smartd` mails on failure via the host MTA. **It did not deliver.**
`/etc/aliases.db` had never been built. `postfix` was enabled and running and
accepted mail happily, but every message deferred:

```
postfix/local: error: open database /etc/aliases.db: No such file or directory
status=deferred (alias database unavailable)
```

**`mailq` held 5 messages, three of them predating this work.** `newaliases`
had never been run on this host, so nothing it has ever tried to tell anyone —
PVE notifications, cron output, smartd — had been delivered. Not queued for a
human to find: deferred in `/var/spool/postfix/deferred`, where nothing looks.

Every layer reported healthy: the unit was `active (running)`, `mail` exited 0,
the message got a queue ID. **The only command that showed the truth was
`mailq`.**

**Fix (PVE 8+, the idiomatic route).** `proxmox-mail-forward` hands root's mail
to PVE's own notification system, keeping the SMTP credential in PVE's managed
config rather than a hand-rolled `/etc/postfix/sasl_passwd`:

```bash
echo 'root: |/usr/bin/proxmox-mail-forward' >> /etc/aliases
newaliases
postqueue -f
```

> ⚠️ **The alias line above was wrong for this host**, and the fix it
> describes was never completed. See *Mail path fixed, 2026-09-21* below.

Then set the target under **Datacenter → Notifications → Add → SMTP**. Verify
with `status=sent`, not with an empty `mailq` alone:

```bash
journalctl -u postfix --since -2min | grep -E 'status=(sent|bounced|deferred)'
```

This incident is also the discovery event behind
[`SAS-STORAGE-INCIDENT.md`](SAS-STORAGE-INCIDENT.md)'s ZED-fault finding — the
same broken mail path had silenced a real pool fault three days earlier.

## Verified 2026-09-10 — `Monitoring 3 ATA/SATA, 3 SCSI/SAS and 0 NVMe devices`

All six devices parsed and were on the monitor list. Findings from that run:

**The `archive-pool` SATA trio has degraded SMART support.** Both SK hynix
units report `not capable of SMART Health Status check`, `no SMART Self-test
Log, ignoring -l selftest` and `no SMART Error Log`; the Micron keeps its logs
and loses only the health bit. Most likely the SAT translation layer of the
H355 rather than the drives. **`-T permissive` is deliberately not used** — it
forces reads of logs the device has said do not exist, and false errors on the
disks holding live MinIO and Postgres data is the wrong trade.

**`-I 9 -I 194` added to every line.** `-a` implies `-t`, so smartd logs each
change in *normalised* attribute values — `Temperature_Celsius changed from 66
to 65` while the raw temperature is 35°C, plus attribute 9 (power-on hours)
ticking hourly. Nothing is lost: `-W 4,45,55` is what actually watches
temperature; `-I` suppresses change *reporting* only.

**Kernel names had already shifted.** `…803377` enumerated as `/dev/sdh`,
having been recorded as `sdg` in `HARDWARE.md` the previous day. The `by-id`
addressing is why this was a non-event.

**The hour-2 self-test gap was retired by hand**, staggered rather than all
three at once, since the drives had not self-tested in ~50,000 hours.

## G2–G7, 2026-09-21

**G2 needed nothing.** `/etc/cron.d/zfsutils-linux` was intact (scrub on the
second Sunday, TRIM on the first). `sas-pool` and `archive-pool` had both
scrubbed clean on Sun 2026-09-13. `llm-pool`, created 2026-09-16, had never
been scrubbed (`scan: none requested`).

**G6 was folded into G5, by the owner's choice.** `prometheus-pve-exporter`
would have needed a `monitor@pve` `PVEAuditor` token in SOPS, the first
Proxmox credential in the cluster. `lvs` on the host gives the thin pool's
`Data%` and `Meta%` (pve-exporter has no `Meta%`), so the textfile script
took it over. Recorded under `GITOPS.md` → *Explicitly rejected*.

**`smartctl_exporter` over Debian's `smartmon` collector.** trixie packages
node-exporter 1.9.0 and `prometheus-node-exporter-collectors`, whose
`smartmon.sh` parses `smartctl` text output. It covers SAS grown defects, but
not the uncorrected-error counters, and it exits on any device type it
doesn't recognise. `smartctl_exporter` reads `smartctl -j` and exports both
counters, so it was installed as the upstream v0.14.0 release binary
(sha256-checked). node-exporter went in with `--no-install-recommends` so
`smartmon` didn't come along.

**Found on the first scrape:**

- **Every disk appeared twice.** `smartctl --scan` found each drive as `sdX`
  and again through the PERC as `bus_2_megaraid_N` (SAS) /
  `bus_2_sat+megaraid_N` (SATA), with the same serials. Fixed with
  `--smartctl.device-exclude=^bus_`. The exporter's filter matches its
  device label, not the raw path (`main.go`, `scanDevices`).
- **No per-pool I/O.** `node_zfs_zpool_nread` doesn't exist on this ZFS
  version; only `node_zfs_zpool_dataset_*` does. The dashboard sums those by
  pool.
- **Every media-error baseline was 0**: SAS grown defects and uncorrected
  read/write errors on all three, and SATA attributes 5 and 198 on all five.
  None of these drives report 197. So the `> 0` thresholds hold from day one.
- The SATA drives all reported `smartctl_device_smart_status` 1 through the
  exporter, even though `smartd` logs that most of them lack a health-status
  check.

**`llm-pool` was scrubbed by hand** the same evening (`zpool scrub
llm-pool`, 0 errors, a few minutes for ~100 GB) so `HostZpoolScrubStale`
wouldn't fire before the October cron run. Polling the textfile output through
it showed all three scrub states live: end time `0`, then `in_progress 1`
with no end time, then a real end time with `errors 0`.

**Verified** from a `curlimages/curl` pod pinned to `k3s-worker1`, which
exercised the `host.fw` rules: `:9100` served 3,958 series, `:9633` 1,316
lines before the `bus_` exclusion (~640 series after it). Every metric the
rules and dashboard reference was present. Each expression also parsed
against the live Prometheus before merge.

**After merge (PR #55, 22:00)**, Prometheus picked up both targets within
two minutes (`up` 1 for `host-node` and `host-smartctl`). All 15 rules
loaded with health `ok`. Run without its threshold, every rule returned
series: 3 pools ONLINE, 0–5% allocated; last scrubs 12 minutes to 8.6 days
old with 0 errors; each of the four sanoid datasets snapshotted ~1h earlier;
thin pool 52.2% data and 2.9% metadata; 9 drives passing SMART with every
media-error counter at 0 and temperatures 33–42°C; host `/` 80% free. With
the thresholds, none matched, and `ALERTS{alertname=~"Host.*"}` was empty.
Grafana's sidecar loaded `host.json`, and every panel returned data once
`rate()` had two samples. The first host CPU reading was ~70% busy, from
only two samples.

## Mail path fixed, 2026-09-21

The 2026-09-10 fix above had never been finished, and no test email had been
sent end to end. A check on 2026-09-21 found:

- **No alias in `/etc/aliases`.** Proxmox already hooks the forwarder in
  through `/root/.forward` (`|/usr/libexec/proxmox-mail-forward`), so none
  was needed.
- **An SMTP target existed but was unused.** `smartd-notis` (Gmail, port 587,
  STARTTLS, to `root@pam`'s email) was configured, but `default-matcher`
  routed only to the stock `mail-to-root` sendmail target.

Steps taken on the host:

1. `pvesh set /cluster/notifications/matchers/default-matcher --target
   smartd-notis`. The target's own test email arrived.
2. Following the 2026-09-10 instructions, `root: |/usr/bin/proxmox-mail-forward`
   was appended to `/etc/aliases`. A `mail … root` test then deferred:
   `local: fatal: execvp /usr/bin/proxmox-mail-forward: No such file or
   directory`, `dsn=4.3.0`. The alias overrode the correct `.forward`, and
   the binary doesn't exist at that path; on PVE 9 it is
   `/usr/libexec/proxmox-mail-forward`.
3. The alias line was deleted, `newaliases` run, and `postqueue -f` flushed
   the queue: `status=sent`, and the deferred test email arrived.

`mailq` was empty before step 2 even though mail had never reached a
person. The earlier test messages had gone to `mail-to-root`.
`HOST-MONITORING.md` → *Mail path* is the current config.

