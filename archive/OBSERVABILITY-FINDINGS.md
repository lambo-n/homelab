# Observability findings — Prometheus retention and series

> 📦 **Archived 2026-10-05.** Verification runs and the disk-pressure fix
> behind the Prometheus retention settings. Current state:
> [../GITOPS.md](../GITOPS.md#kube-prometheus-stack).

## 2026-09-21 — retention verified as the binding limit; worker1 disk pressure and the grow to 32 GB

> Moved from `GITOPS.md` → *kube-prometheus-stack* in the 2026-10-05 docs pass, as it stood.

> ✅ **Verified 2026-09-21: `retention: 15d` is the binding limit, not `retentionSize`.**
> Oldest sample 2026-09-06 06:00 UTC (15.4 days, which is expected, because time retention
> drops whole blocks); `prometheus_tsdb_time_retentions_total` 3 and
> `prometheus_tsdb_size_retentions_total` **0**. The TSDB grew ~0.15 GB/day, then
> levelled off at **2.56 GB** (2.33 blocks + 0.23 WAL) from 09-19, when the first blocks
> aged out. The projection was ~2.4 GiB (2.58 GB), close enough to call it confirmed. Head
> series is 60–78k depending on pod churn. Six pod restarts from host reboots did not
> reset anything. Measured through the apiserver service proxy, because the image is
> distroless (no `wget`, no `sh`).
>
> ⚠️ **But the 4 GiB guard no longer fits the disk it guards.** Worker1's free space
> dropped from 5.67 GB to 2.91 GB overnight on 09-16/17 when Home Assistant landed there
> (see [`VOICE.md`](../VOICE.md)), and it now sits at ~2.4 GB. Kubelet's hard eviction is
> `nodefs.available<5%` (~0.96 GB), so Prometheus has ~1.4 GB of growth before the node
> evicts pods, while `retentionSize` would allow ~1.7 GB. Image GC is already above its
> 85% threshold and failing to free anything, and DiskPressure fired for 5 minutes on
> 2026-09-18 14:01 UTC.
>
> ✅ **Fixed 2026-09-21**, both ways. `retentionSize` went to **3GiB** so Prometheus's own
> cap sits under the eviction line. Worker1's disk went **20 → 32 GB** (`qm resize`, then
> `growpart`/`pvresize`/`lvextend -r` online), which left `/` at 30.2 GiB with 14 GB free.
> The tofu side took a `TofuDisk` grant on the *token* as well as the user (privsep, see
> `tofu/README.md`) and a `-refresh-only` apply. That refresh also exposed a `k3s` tag
> added on the host and the generated `mac_addresses` lists, which were pod veths
> frozen at import. Both are now fixed in `proxmox-vms.tf`, and the plan is clean.
