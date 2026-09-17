# Backlog

Every open item across this repo, in one place, so nothing is tracked only in
a runbook nobody re-reads. Each entry says what it's waiting on and where the
fuller context lives. Nothing here is blocking day-to-day operation.

## Waiting on a decision

- [ ] **Retire the legacy NFS PV/PVC** (`postgres-pvc` → `postgres-pv`, 100 GiB,
      `Retain`). Still bound, still holding the pre-cutover Postgres data. They
      live in `sunfire-storage` where prune is permanently disabled, so removing
      them is a manual act a git edit cannot do by accident. The clock is a decay
      note in `GITOPS.md` → CloudNativePG: when rolling back would lose more than
      it saves, there is nothing left to keep them for.
- [ ] **Verify the 15-day Prometheus retention projection** — due around
      **2026-09-19**. The figure is derived from 65,810 active series, not
      measured. Check that `retention: 15d` is what is actually happening rather
      than `retentionSize: 4GiB` truncating it silently. See `GITOPS.md` →
      kube-prometheus-stack.
- [ ] **Decide what the `192.168.50.0/24` subnet route is allowed to reach**
      *(raised 2026-09-09)*. It is approved today, so tailnet membership alone
      grants layer-3 access to every port on the LAN — see `GITOPS.md` →
      Tailscale (host). Three options: leave it; restrict it with a Tailscale
      ACL to named devices; or drop the route and go back to `ProxyJump` only
      (costs reaching `:8006` and Grafana without a jump host). **Not urgent** —
      same "100% uptime isn't guaranteed, nothing here is worth much" calculus as
      the rest of `README.md`'s operating assumptions.
- [ ] **Repoint `sunfire-postgrest`'s `dependsOn`** at `sunfire-postgres-cnpg`. It
      still names `sunfire-postgres`, which since 2026-09-04 holds only a Secret.
      Harmless — a secret-only Kustomization is always Ready — but the edge no
      longer means what it says.

## Blocked on a layer that does not exist yet

- [ ] **Pin `sanoid` in Ansible/host config.** It is host-level, not a
      Kubernetes object, so neither Flux nor OpenTofu reconciles it. Needs the
      host-config layer named in `GITOPS.md` → Cross-cutting decisions → scope
      split. Until it exists, [`SANOID.md`](SANOID.md) *is* the record.
- [ ] **Split the OpenTofu root module in two.** Both providers share one root,
      so a Proxmox-only plan still refreshes Cloudflare and dies without that
      token. `-refresh=false` is the workaround in use. See `GITOPS.md` →
      OpenTofu.

## Host monitoring — G2 through G7

Goal G1 (SMART long tests) is live; the rest of the plan in
[`HOST-MONITORING.md`](HOST-MONITORING.md) is still open:

- [ ] **G2** — confirm the existing PVE monthly scrub cron is intact (or enable
      `zfs-scrub-monthly@<pool>.timer`) on `sas-pool` and `archive-pool`.
- [ ] **G3–G5** — host-side metrics: `prometheus-node-exporter`, `smartctl_exporter`,
      and a textfile-collector script for pool capacity / scrub age / snapshot age.
- [ ] **G6** — `prometheus-pve-exporter` in-cluster, on a new, separate
      `monitor@pve` token (never `tofu@pve`) — see `HOST-MONITORING.md` for the
      scope-split trade this one touches.
- [ ] **G7** — the `ScrapeConfig` + `PrometheusRule` + dashboard for G3–G6, as
      `kubernetes/apps/observability/host-monitoring/`.

## GPU / LLM VM

- [ ] **Verify the boot-time ReBAR resize across a real host reboot.** The first
      attempt (2026-09-16) failed at the 32 GiB step; the sequence was fixed in
      `gpu-rebar.sh` (PR #24) and passed a manual `systemctl restart`, but the
      *full* boot path (32 GiB refused → 4 GiB → 32 GiB, replayed automatically at
      boot) has not yet been proven by an actual reboot. Check
      `journalctl -u gpu-rebar -b` after the next one. See
      [`GPU-VM.md`](GPU-VM.md) and [`archive/GPU-VM-BUILD.md`](archive/GPU-VM-BUILD.md) → D4.
- [ ] **GuC firmware on the LLM guest is older than the kernel wants**
      (`70.44.1` loaded, `70.54.0` recommended). Works today; try
      `apt install --only-upgrade linux-firmware` when convenient. Not blocking.
- [ ] Check whether the tailscale gateway's `192.168.50.0/24` route exposes the
      LLM VM's `:8080`/`:8081` to tailnet devices beyond what F6a's firewall rules
      intend (the same route this file's "subnet route" item above is about).

## Hardware — still unknown

From [`HARDWARE.md`](HARDWARE.md) → "Still unknown":

- [ ] SMART baseline on the 6 SATA disks (`archive-pool` members + `llm-pool`) —
      all 3 SAS disks are already done. `smartctl -a /dev/sdX`.
- [ ] BOSS-S2 boot mirror health — invisible to every monitor in this repo; a
      failed M.2 surfaces only in iDRAC or the BOSS CLI.
- [ ] Total front-bay count and how many are physically empty — decides whether
      expansion needs a new chassis or just more disks.

## Backlog — not now

- [ ] kubeconform or [`flux-schema`](https://github.com/fluxcd/flux-schema)
      validation in CI *(own recommendation — the reference repo does not do this)*.
- [ ] `tofu validate` + `tofu fmt -check` in CI for PRs touching `tofu/`. Needs no
      credentials, but `tofu init` downloads providers, so the job isn't hermetic.
      See `tofu/README.md#versions` for the incident that motivated this
      (Renovate bumped `versions.tf` without refreshing the lock file, and every
      tofu command failed on a fresh checkout for six days, unnoticed).
- [ ] Loki + Promtail for logs — wants its own storage answer first (worker1's
      root disk is already the TSDB's constraint).
- [ ] Talos Linux for the k3s nodes — the real endgame for declarative node
      config, but a rebuild.
- [ ] Gateway API / Envoy Gateway instead of Traefik Ingress (CRDs already present).

## Related

- [`GITOPS.md`](GITOPS.md) — per-tool current reference; "Explicitly rejected"
  there has the standing decisions that are *not* backlog (closed questions,
  not open ones)
- [`archive/GITOPS-MIGRATION.md`](archive/GITOPS-MIGRATION.md) — the completed
  seven-phase migration this backlog grew out of
