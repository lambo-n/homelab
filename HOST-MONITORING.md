# Host Monitoring — replacing the TrueNAS GUI with Grafana + systemd

**Status 2026-09-10: goals recorded, nothing built yet.** Part A (host-side) is
owned by the operator and runs first; Part B (cluster-side) is blocked on it.

`TRUENAS.md` was superseded on 2026-09-09 by the native `sas-pool`
([`SAS-STORAGE.md`](SAS-STORAGE.md)) after the PERC H355 turned out to be
un-passable — shared backplane cabling plus a Dell RMRR region. That closed the
storage question but left the TrueNAS *checklist* unclaimed: the appliance was
also going to schedule the SMART tests and scrubs, and give a health UI. Those
goals did not disappear with the VM.

This file records what those goals were and who owns each one now.

---

## The gap this closes

Stated already at [`HARDWARE.md`](HARDWARE.md) §`sda` and in `README.md`, and
re-confirmed against the live cluster 2026-09-10:

```
node-exporter DaemonSet  ->  k3s-control, k3s-worker1, k3s-worker2   (3/3 Running)
192.168.50.101 (pve)     ->  not a scrape target at all
```

**No host disk is monitored by anything in this repo.** Not `sas-pool`, not
`archive-pool`, not the BOSS-S2 boot mirror. `SANOID.md` §5 makes the same point
from the snapshot side: nothing will tell you when sanoid stops working.

Two numbers give that urgency rather than tidiness:

- **The SAS SSDs' last self-test was at lifetime hour 2** — factory, 2018. They
  are at ~49,957 hours now (`HARDWARE.md`). All three are one batch, powered
  together within 11 minutes of each other for their whole life; a correlated
  failure is the shape to expect and a scheduled long test is what sees it coming.
- **`local-lvm` thin-pool free space is falling** — 90.5 GiB (2026-09-03) ->
  82.12 GiB (2026-09-09). A full thin pool breaks all five guests at once
  (`STORAGE.md:306-308`), and `Data%` is watched by a human remembering to run
  `lvs`.

---

## The goals

Everything the TrueNAS web GUI would have given us, and where it lands instead.

| # | Goal | Mechanism | Owner |
|---|---|---|---|
| **G1** | Scheduled **SMART long tests** on the three SAS SSDs | `smartd` (`/etc/smartd.conf`, `-s L/../../6/03`) | host `.101` |
| **G2** | Scheduled **scrubs** on `sas-pool` and `archive-pool` | `zfs-scrub-monthly@<pool>.timer` — **but check the PVE cron first**, see A2 | host `.101` |
| **G3** | **Pool state** (`ONLINE`/`DEGRADED`), ARC and per-pool I/O as metrics | `prometheus-node-exporter`, `zfs` collector | host `.101` |
| **G4** | **Per-drive SMART** — temperature, grown defect list, uncorrected errors, endurance used, last self-test result | `smartctl_exporter` | host `.101` |
| **G5** | **Pool capacity, scrub age, sanoid snapshot age** | node-exporter **textfile collector** + a small script on a timer | host `.101` |
| **G6** | **`local-lvm` thin-pool `Data%`** and per-storage capacity | `prometheus-pve-exporter` against `:8006` — **in-cluster, no host install** | cluster |
| **G7** | **Dashboards + alert rules** over G3–G6 | `ScrapeConfig` + `PrometheusRule` + dashboard JSON in this repo | cluster |

G1 and G2 are *jobs*, not dashboards — Grafana cannot do them and never could.
That is not an argument against this design: `smartd` and a systemd timer are a
better home for them than an appliance UI, because they keep running when the
cluster does not.

---

## Part A — host-side (`192.168.50.101`, as root)

**This VM cannot do any of it.** `ssh root@192.168.50.101` returns
`Permission denied (publickey)` from `.103` (verified 2026-09-04, `tofu/README.md`),
and NFS/2049 and rpcbind/111 are filtered. Every command below is handed to the
operator deliberately, not as a fallback.

### A1 — SMART long tests (G1) — *applied 2026-09-10, with two corrections*

`smartmontools` is already installed on PVE and `smartmontools.service` is
enabled by the package.

> ⚠️ **`DEVICESCAN` silently voids everything after it.** PVE ships
> `/etc/smartd.conf` with an active
> `DEVICESCAN -d removable -n standby -m root -M exec /usr/share/smartmontools/smartd-runner`
> on line 19, and — as that file's own comments state — **the word DEVICESCAN
> causes every remaining line in the file to be ignored.** Per-drive directives
> appended at the bottom parse as nothing at all, `smartd` restarts cleanly, and
> no self-test is ever scheduled. Found the hard way on the first attempt here.
>
> Comment it out. Once it is off, **only listed devices are monitored**, so
> `archive-pool` has to be listed in the same pass rather than left for later.

> ⚠️ **Keep `-m root -M exec /usr/share/smartmontools/smartd-runner` on every
> line.** That pair is how Debian actually delivers a smartd warning — it runs
> the scripts in `/etc/smartmontools/run.d/`. `DEVICESCAN` carried it; a
> hand-written drive line that omits it logs the failure and mails no one.

Devices by `by-id`, so a device-name shuffle cannot retarget the test — `sdg/sdh/sdi`
in `HARDWARE.md` are `sdh/sdi/sdj` in `SAS-STORAGE.md`, which is the whole argument:

```
# sas-pool members — long self-test Saturdays 03:00, temp warn 45C / crit 55C
/dev/disk/by-id/scsi-35002538a48872950 -d scsi -a -s L/../../6/03 -W 4,45,55 -m root -M exec /usr/share/smartmontools/smartd-runner
/dev/disk/by-id/scsi-35002538a48872700 -d scsi -a -s L/../../6/03 -W 4,45,55 -m root -M exec /usr/share/smartmontools/smartd-runner
/dev/disk/by-id/scsi-35002538a48872be0 -d scsi -a -s L/../../6/03 -W 4,45,55 -m root -M exec /usr/share/smartmontools/smartd-runner

# archive-pool members — long self-test Sundays 03:00 (live MinIO + Postgres data)
/dev/disk/by-id/ata-HFS1T9G3H2X069N_ADB5N4365I150584Z -a -s L/../../7/03 -W 4,45,55 -m root -M exec /usr/share/smartmontools/smartd-runner
/dev/disk/by-id/ata-HFS1T9G3H2X069N_ADB5N4365I1505855 -a -s L/../../7/03 -W 4,45,55 -m root -M exec /usr/share/smartmontools/smartd-runner
/dev/disk/by-id/ata-MTFDDAK1T9TDT_222939CA58D4 -a -s L/../../7/03 -W 4,45,55 -m root -M exec /usr/share/smartmontools/smartd-runner
```

Separate days so the two pools do not self-test at once. If `smartctl -i <by-id>`
on the SATA three needs `-d sat`, add it — or drop `-d` and let smartd
auto-detect rather than guess.

**Verify the parse, do not trust a clean restart.** This is the step that catches
the DEVICESCAN trap:

```bash
smartd -d -q onecheck 2>&1 | grep -E 'Monitoring|Device:|Next'
```

All six devices must be named. Anything absent is a line smartd never read.

```bash
systemctl restart smartmontools.service
systemctl is-enabled smartmontools.service
```

> **`systemctl enable smartd` fails** with `Refusing to operate on linked unit
> file smartd.service` — `smartd.service` is an alias symlink on Debian. The real
> unit is `smartmontools.service`, and the package already enables it, so this
> error is cosmetic. Use the real name.

> `smartd` mails on failure via the host MTA. Confirm one actually delivers
> (`echo test | mail -s test root`) or the `-m` directive is decoration. This is
> the **only** alert path in this design that survives the cluster being off.

> 🔴 **It did not deliver. Found 2026-09-10 — `/etc/aliases.db` had never been
> built.** `postfix` is enabled and running and accepts mail happily, but every
> message deferred:
>
> ```
> postfix/local: error: open database /etc/aliases.db: No such file or directory
> status=deferred (alias database unavailable)
> ```
>
> **`mailq` held 5 messages, three of them predating this work.** `newaliases`
> had never been run on this host, so nothing it has ever tried to tell anyone —
> PVE notifications, cron output, smartd — has been delivered. Not queued for a
> human to find: deferred in `/var/spool/postfix/deferred`, where nothing looks.
>
> This is why A1 asks for the MTA test rather than trusting `systemctl status`.
> Every layer reported healthy: the unit was `active (running)`, `mail` exited 0,
> the message got a queue ID. The only command that showed the truth was `mailq`.
>
> **Fix (PVE 8+, the idiomatic route).** `proxmox-mail-forward` hands root's mail
> to PVE's own notification system, keeping the SMTP credential in PVE's managed
> config rather than a hand-rolled `/etc/postfix/sasl_passwd`:
>
> ```bash
> echo 'root: |/usr/bin/proxmox-mail-forward' >> /etc/aliases
> newaliases
> postqueue -f
> ```
>
> Then set the target under **Datacenter → Notifications → Add → SMTP**.
>
> Without `proxmox-mail-forward`: alias `root` to a real address and set a
> `relayhost` with SASL — `relayhost` is empty here and direct-to-internet SMTP
> from this IP will be refused. That route leaves a plaintext SMTP credential on
> `.101`, outside both SOPS and Infisical ([`../secrets_architecture`](GITOPS.md)
> covers neither the hypervisor); the PVE route avoids it.
>
> Verify with `status=sent`, not with an empty `mailq` alone:
>
> ```bash
> journalctl -u postfix --since -2min | grep -E 'status=(sent|bounced|deferred)'
> ```

#### Verified 2026-09-10 — `Monitoring 3 ATA/SATA, 3 SCSI/SAS and 0 NVMe devices`

All six parse and are on the monitor list. Three findings from that run.

**The `archive-pool` SATA trio has degraded SMART support.** Both SK hynix units
report `not capable of SMART Health Status check`, `no SMART Self-test Log,
ignoring -l selftest` and `no SMART Error Log`; the Micron keeps its logs and
loses only the health bit. So `-a` does considerably less on these three than on
the SAS side — no pass/fail bit, and on two drives no readable test history.
They do still report self-test *status* (`previous self-test completed without
error`), so the Sunday test is not wasted, only less legible.

Most likely the SAT translation layer of the H355 rather than the drives.
**`-T permissive` is deliberately not used** — it forces reads of logs the device
has said do not exist, and false errors on the disks holding live MinIO and
Postgres data is the wrong trade. The consequence is for Part B: alert rules
cannot key on health status for these three and must use reallocated/pending
sector attributes and temperature instead.

**Add `-I 9 -I 194` to every line.** `-a` implies `-t`, so smartd logs each
change in *normalised* attribute values — `Temperature_Celsius changed from 66 to
65` while the raw temperature is 35 C, plus attribute 9 (power-on hours) ticking
hourly. Nothing is lost: `-W 4,45,55` is what actually watches temperature, and
`-I` suppresses change *reporting* only, never failure detection.

**Kernel names had already shifted.** `…803377` enumerated as `/dev/sdh`, having
been recorded as `sdg` in `HARDWARE.md` the previous day — the whole SAS set moved
up a letter, and `archive-pool`'s second mirror member is `sde`, not `sdd`. The
`by-id` addressing above is why this was a non-event.

**Retire the hour-2 gap by hand.** The schedule is set, but these drives have not
self-tested in ~50,000 hours; do not wait for Saturday. Stagger them rather than
running all three at once:

```bash
smartctl -t long /dev/disk/by-id/scsi-35002538a48872950
smartctl -l selftest /dev/disk/by-id/scsi-35002538a48872950   # ~30-60 min
```

### A2 — Scrubs (G2) — verify before adding anything

Proxmox ships `/etc/cron.d/zfsutils-linux`, which scrubs **every imported pool**
on the second Sunday of each month. If it is intact, G2 is already met and only
needs a metric (G5). Check first:

```bash
cat /etc/cron.d/zfsutils-linux
zpool status sas-pool archive-pool | grep -E 'scan:|scrub'
```

Only if that cron is absent or disabled:

```bash
systemctl enable --now zfs-scrub-monthly@sas-pool.timer
systemctl enable --now zfs-scrub-monthly@archive-pool.timer
```

Do not run both mechanisms — two scrubs of the same pool is wasted I/O, not
twice the safety.

### A3 — node-exporter (G3, and the vehicle for G5)

```bash
apt update && apt install -y prometheus-node-exporter
```

Confirm the textfile collector directory the Debian package uses, and that the
`zfs` collector is producing pool state:

```bash
grep ARGS /etc/default/prometheus-node-exporter
ls -d /var/lib/prometheus/node-exporter
curl -s localhost:9100/metrics | grep -E 'node_zfs_zpool_state|node_zfs_arc' | head
```

`node_zfs_zpool_state` comes from `/proc/spl/kstat/zfs/<pool>/state`. If it is
absent on this ZFS build, pool state moves into the A4 script instead — it is
one more line there, not a blocker.

### A4 — smartctl_exporter (G4)

Check for a package first; fall back to the upstream release binary:

```bash
apt-cache policy prometheus-smartctl-exporter
```

It needs root to run `smartctl`, listens on `:9633`, and wants every device
named by `by-id` in its config for the same reason A1 does.

### A5 — textfile metrics: capacity, scrub age, snapshot age (G5)

The one piece with no off-the-shelf exporter. A short script writing
`.prom` files into the textfile directory, on a 5-minute systemd timer, covering:

- `zpool list -Hp -o name,size,alloc,free,capacity,fragmentation,health`
- scrub completion age, parsed from `zpool status`
- newest snapshot age per dataset — `SANOID.md` §5 calls this "the first metric
  worth having", because a snapshot count that stops growing is exactly how
  sanoid fails

Write it atomically (`> file.tmp && mv`) — node-exporter reads the directory on
every scrape and will happily serve a half-written file.

### A6 — firewall (all of the above)

`host.fw` is default-drop. The 445/139 rules in `SAS-STORAGE.md` are the
precedent; the exporters need the same treatment:

```ini
[RULES]
IN ACCEPT -source 192.168.50.0/24 -p tcp -dport 9100 -log nolog # node-exporter
IN ACCEPT -source 192.168.50.0/24 -p tcp -dport 9633 -log nolog # smartctl-exporter
```

```bash
pve-firewall compile && pve-firewall restart
```

Verify from this VM before touching Part B — `curl -s 192.168.50.101:9100/metrics | head`.
Until that returns, nothing in Part B can work.

---

## Part B — cluster-side (this repo, after Part A)

The stack is already able to take these; nothing needs installing.

- `scrapeconfigs.monitoring.coreos.com` **CRD is registered** (verified 2026-09-10).
- `scrapeConfigSelectorNilUsesHelmValues: false` in `helmrelease.yaml:318`, so a
  `ScrapeConfig` in any namespace is selected **without** a `release:` label.

Planned, as a new app directory `kubernetes/apps/observability/host-monitoring/`:

1. **`ScrapeConfig`** with a `staticConfigs` target list — `192.168.50.101:9100`
   and `:9633`. A static target rather than a `Service`/`Endpoints` pair because
   it is a static target; the Endpoints trick buys nothing here.
2. **`PrometheusRule`** — pool not `ONLINE`; scrub older than 35 days; any grown
   defect or uncorrected error (threshold 1, these are at 0 today); drive temp
   over 55C; newest snapshot older than 2h; `local-lvm` `Data%` over 85; and
   node-exporter itself absent for 15m, which is the one that catches the host
   being down rather than a disk being bad.
   > **Two rule sets, not one.** Per A1's 2026-09-10 findings the `archive-pool`
   > SATA drives expose no SMART health status, and two of the three no self-test
   > or error log. Grown-defect and health-bit rules apply to the three SAS disks
   > only; the SATA trio needs reallocated/pending-sector attributes and
   > temperature. A single rule written against the SAS shape would evaluate to
   > nothing on the drives holding the live data — silently.
3. **Dashboard JSON**, committed, following the `flux-monitoring` precedent.
4. **`prometheus-pve-exporter`** (G6) — see the token note below.

**Ordering:** no `dependsOn` on `kube-prometheus-stack`, matching the reasoning
in `README.md` — `PrometheusRule` and `ScrapeConfig` are registered kinds
already, and nothing should be able to wedge on this.

### The pve-exporter token, and a boundary it touches

G6 is attractive because it needs **zero host access** — it reads `:8006`, which
is the one port that is usable from here. `PVEAuditor` is sufficient; the
`VM.Config.Disk` problem in `tofu/README.md` was a provider-specific route and
does not apply to a metrics read.

But `GITOPS.md` -> *Explicitly rejected* turns down Flux-for-Proxmox partly
because a shim "needs a Proxmox API token stored in-cluster, so cluster
compromise would become hypervisor compromise — today the cluster cannot touch
`.101` at all." **A pve-exporter Secret puts a hypervisor credential in the
cluster and spends that invariant**, even read-only.

Judgement: the trade is defensible for `PVEAuditor` — an attacker gains the
ability to *read* guest and storage inventory, not to change anything, and
`prevent_destroy` plus the read-only role are unchanged. But it must be a
**separate `monitor@pve` token**, never the `tofu@pve` one, so it is revocable
without breaking OpenTofu. If that trade is unwanted, G6 degrades gracefully:
thin-pool `Data%` can come from the A5 textfile script instead, and the whole
in-cluster exporter is dropped.

---

## What this does not cover

Recording these so the dashboard is not mistaken for full coverage:

- **The BOSS-S2 boot mirror stays invisible.** The OS cannot see the member
  disks; `smartctl /dev/sda` reads the virtual disk. A failed half surfaces only
  in iDRAC or the BOSS CLI. TrueNAS would not have helped either — this is a
  gap in both designs, not a regression.
- **The monitor sits on what it monitors.** Prometheus runs on `k3s-worker1`, a
  VM on `.101`. Host dies -> monitoring dies with it, and the `absent()` alert
  dies with it too. Only `smartd`'s own mail (A1) escapes this.
- **The cluster is frequently powered off** — by hand for maintenance and to
  power cuts (`README.md` operating assumptions; it is also why SOPS holds the
  cluster-only secrets). A drive degrading overnight with k3s down is seen at
  next boot, not at 03:00. This is the one thing a TrueNAS appliance would
  genuinely have done better.
- **Alertmanager is still on the chart's `null` receiver.** Rules fire and are
  visible in the UI; nothing is pushed anywhere. Deliberate today — but it means
  every alert in Part B is a *pull* notification until that changes.
  > And until 2026-09-10 the host could not push either — `/etc/aliases.db` did
  > not exist, so postfix deferred every message it had ever been given (A1).
  > **Both notification paths on this hardware were dead at the same time**, one
  > by choice and one by accident, and the accident was invisible from every
  > status command that looked healthy. Treat "an alert exists" and "an alert
  > arrives" as separate claims needing separate evidence.

---

## Series budget

Prometheus is at ~65,810 active series, `retention: 15d` guarded by
`retentionSize: 4GiB` on `local-path` on worker1's root disk. node-exporter adds
roughly 1–2k series for one host, smartctl_exporter a few dozen per drive, the
textfile script a handful — call it 3k, under 5%.

Small, but it lands on top of the open item in `GITOPS.md` due **2026-09-19**:
verify whether `retention: 15d` or `retentionSize: 4GiB` is actually binding.
Do that check first if Part B is built before then, so the answer is not
confounded by new series.

---

## Related

- [`TRUENAS.md`](TRUENAS.md) — the superseded appliance design these goals came from
- [`SAS-STORAGE.md`](SAS-STORAGE.md) — `sas-pool`, the pool being watched
- [`HARDWARE.md`](HARDWARE.md) — per-disk SMART baselines (2026-09-09) and the
  BOSS-S2 blind spot; the alert thresholds above are set against those readings
- [`SANOID.md`](SANOID.md) — §5, snapshot age as the first host metric worth having
- [`STORAGE.md`](STORAGE.md) — the thin pool that G6 watches
- [`GITOPS.md`](GITOPS.md) — the hypervisor/cluster scope split the pve-exporter
  token touches
- `tofu/README.md:196-322` — the existing PVE API token and the read-only argument
