# Host monitoring — A1 (SMART long tests) setup log

> 📦 **Archived 2026-09-16.** A1 (SMART long tests) is the one goal in
> [`../HOST-MONITORING.md`](../HOST-MONITORING.md) that's fully built and
> verified; this is the debugging record from doing it. The current
> configuration is summarized in that file; the remaining goals (A2–A6, Part B)
> are tracked in [`../BACKLOG.md`](../BACKLOG.md).

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
