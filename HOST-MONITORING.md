# Host Monitoring — replacing the TrueNAS GUI with Grafana + systemd

**Status: partially built.** Goal G1 (SMART long tests) is live and verified;
G2–G7 are still open — see [`BACKLOG.md`](BACKLOG.md) for what's left and why
it isn't urgent. [`TRUENAS.md`](archive/TRUENAS.md) was superseded on 2026-09-09
by the native `sas-pool` ([`SAS-STORAGE.md`](SAS-STORAGE.md)) after the PERC
H355 turned out to be un-passable, which closed the storage question but left
the TrueNAS *checklist* unclaimed: the appliance was also going to schedule
SMART tests and scrubs, and give a health UI. This file records those goals
and who owns each one now.

## The gap this closes

```
node-exporter DaemonSet  ->  k3s-control, k3s-worker1, k3s-worker2   (3/3 Running)
192.168.50.101 (pve)     ->  not a scrape target at all
```

**No host disk is monitored by anything in this repo** except via G1 below.
Not `sas-pool`, not `archive-pool`, not the BOSS-S2 boot mirror. `SANOID.md`
makes the same point from the snapshot side.

Two numbers give that urgency:

- **The SAS SSDs went ~50,000 hours between self-tests** before G1 closed the
  gap. All three are one batch, powered together within 11 minutes of each
  other for their whole life — a correlated failure is the shape to expect.
- **`local-lvm` thin-pool free space is falling** (90.5 GiB → 82.12 GiB between
  2026-09-03 and 2026-09-09). A full thin pool breaks all five guests at once.

## The goals

Everything the TrueNAS web GUI would have given us, and where it lands instead.

| # | Goal | Mechanism | Owner | Status |
|---|---|---|---|---|
| **G1** | Scheduled **SMART long tests** on the SAS + SATA SSDs | `smartd` (`/etc/smartd.conf`) | host `.101` | ✅ **live** |
| **G2** | Scheduled **scrubs** on `sas-pool` and `archive-pool` | `zfs-scrub-monthly@<pool>.timer`, or the existing PVE cron if intact | host `.101` | open |
| **G3** | **Pool state**, ARC and per-pool I/O as metrics | `prometheus-node-exporter`, `zfs` collector | host `.101` | open |
| **G4** | **Per-drive SMART** as metrics | `smartctl_exporter` | host `.101` | open |
| **G5** | **Pool capacity, scrub age, sanoid snapshot age** as metrics | node-exporter textfile collector + a script on a timer | host `.101` | open |
| **G6** | **`local-lvm` thin-pool `Data%`** and per-storage capacity | `prometheus-pve-exporter` against `:8006`, in-cluster | cluster | open |
| **G7** | **Dashboards + alert rules** over G3–G6 | `ScrapeConfig` + `PrometheusRule` + dashboard JSON | cluster | open |

G1 and G2 are *jobs*, not dashboards — Grafana cannot do them and never could.
`smartd` and a systemd timer are a better home for them than an appliance UI
regardless, because they keep running when the cluster does not.

## G1 — SMART long tests (live)

Devices are addressed by `by-id` (a `sdX` shuffle is expected — see
[`HARDWARE.md`](HARDWARE.md)), each pool on its own day so two don't self-test
at once:

| Pool | Schedule | Devices |
|---|---|---|
| `sas-pool` | Saturdays 03:00 | the 3 SAS SSDs |
| `archive-pool` | Sundays 03:00 (live MinIO + Postgres data) | the 3 SATA SSDs |
| `llm-pool` | Fridays 03:00 (no redundancy) | 1 SATA SSD |

Temperature warn/crit at 45°C/55°C on every line. The `archive-pool` SATA trio
has degraded SMART support (no health-status bit, two of three with no
self-test or error log) — checked with `smartctl`, watched via temperature and
attribute thresholds rather than the pass/fail bit. Mail alerting is wired
through PVE's own notification system (`proxmox-mail-forward`), after a
2026-09-10 incident found the host's plain postfix mail had never delivered
anything, ever (full record: [`archive/HOST-MONITORING-SETUP.md`](archive/HOST-MONITORING-SETUP.md)).

## G2 — scrubs

Proxmox ships `/etc/cron.d/zfsutils-linux`, which scrubs **every imported
pool** on the second Sunday of each month. If it is intact, G2 is met and only
needs a metric (G5). Check before adding a second mechanism:

```bash
cat /etc/cron.d/zfsutils-linux
zpool status sas-pool archive-pool | grep -E 'scan:|scrub'
```

Only if that cron is absent or disabled, enable `zfs-scrub-monthly@<pool>.timer`
per pool. Do not run both — two scrubs of the same pool is wasted I/O, not
twice the safety.

## G3–G5 — host-side metrics

```bash
apt update && apt install -y prometheus-node-exporter
```

`node_zfs_zpool_state` (from `/proc/spl/kstat/zfs/<pool>/state`) covers pool
state if this ZFS build exports it; otherwise it moves into the G5 script.
`smartctl_exporter` (or the upstream release binary if no package exists)
covers G4, needs root, listens on `:9633`. G5 has no off-the-shelf exporter — a
short script on a 5-minute systemd timer writing `.prom` files (pool capacity,
scrub completion age, newest snapshot age per dataset — the metric `SANOID.md`
calls the first one worth having) into node-exporter's textfile directory,
written atomically (`> file.tmp && mv`).

Firewall (`host.fw` is default-drop, same precedent as `SAS-STORAGE.md`'s
Samba rules):

```ini
[RULES]
IN ACCEPT -source 192.168.50.0/24 -p tcp -dport 9100 -log nolog # node-exporter
IN ACCEPT -source 192.168.50.0/24 -p tcp -dport 9633 -log nolog # smartctl-exporter
```

## G6–G7 — cluster-side

The stack can already take these; nothing needs installing. `scrapeconfigs.monitoring.coreos.com`
is registered, and `scrapeConfigSelectorNilUsesHelmValues: false` means a
`ScrapeConfig` in any namespace is selected without a `release:` label.

Planned as `kubernetes/apps/observability/host-monitoring/`: a `ScrapeConfig`
with a static target list (`192.168.50.101:9100` and `:9633`); a
`PrometheusRule` — pool not `ONLINE`, scrub older than 35 days, any grown
defect/uncorrected error, drive temp over 55°C, newest snapshot older than 2h,
`local-lvm` `Data%` over 85, node-exporter absent for 15m — split into two rule
sets, since the `archive-pool` SATA drives expose no SMART health bit and need
reallocated/pending-sector attributes instead; and a dashboard JSON, following
the `flux-monitoring` precedent.

**G6's `prometheus-pve-exporter` needs a hypervisor-scoped credential
in-cluster** (`PVEAuditor` is sufficient), which is the one thing `GITOPS.md`'s
scope split otherwise keeps out of the cluster entirely. Judged defensible
because it's read-only — an attacker gains inventory visibility, not
write — but it must be a **separate `monitor@pve` token**, never `tofu@pve`,
so it stays revocable without touching OpenTofu. If that trade is unwanted, G6
degrades gracefully: thin-pool `Data%` comes from the G5 script instead, and
the in-cluster exporter is dropped.

## What this does not cover

- **The BOSS-S2 boot mirror stays invisible** either way — the OS cannot see
  its member disks; a failed half surfaces only in iDRAC or the BOSS CLI.
- **The monitor sits on what it monitors.** Prometheus runs on `k3s-worker1`, a
  VM on `.101`. Host dies → monitoring dies with it, and the `absent()` alert
  dies with it too. Only `smartd`'s own mail escapes this.
- **The cluster is frequently powered off** (`README.md` operating
  assumptions). A drive degrading overnight with k3s down is seen at next
  boot, not at 03:00.
- **Alertmanager is on the chart's `null` receiver** (`GITOPS.md` →
  kube-prometheus-stack). Every alert here is a *pull* notification until that
  changes.

## Series budget

Prometheus is at ~65,810 active series, `retention: 15d` guarded by
`retentionSize: 4GiB`. node-exporter adds roughly 1–2k series for one host,
smartctl_exporter a few dozen per drive, the textfile script a handful — call
it 3k, under 5%. `retention: 15d` was verified as the binding limit on
2026-09-21 (TSDB steady at 2.56 GB). **Check worker1's free disk before landing
G3–G7**, not just the series count: the node is at ~2.4 GB free since Home
Assistant moved there, and eviction starts at ~0.96 GB (`GITOPS.md` →
kube-prometheus-stack).

## Related

- [`archive/HOST-MONITORING-SETUP.md`](archive/HOST-MONITORING-SETUP.md) — the
  G1 debugging record: the DEVICESCAN trap and the mail-delivery incident
- [`archive/TRUENAS.md`](archive/TRUENAS.md) — the superseded appliance design
  these goals came from
- [`SAS-STORAGE.md`](SAS-STORAGE.md) — `sas-pool`, the pool being watched, and
  the import incident this design would have caught sooner
- [`HARDWARE.md`](HARDWARE.md) — per-disk SMART baselines and the BOSS-S2 blind spot
- [`SANOID.md`](SANOID.md) — snapshot age as the first host metric worth having
- [`GITOPS.md`](GITOPS.md) — the hypervisor/cluster scope split G6's token touches
- [`BACKLOG.md`](BACKLOG.md) — G2–G7 tracked as open work
