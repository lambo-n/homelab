# Backlog

Every open item across this repo, in one place, so nothing is tracked only in
a runbook nobody re-reads. Each entry says what it's waiting on and where the
fuller context lives. Nothing here is blocking day-to-day operation.

## Waiting on a decision

- [ ] **Retire the legacy NFS PV/PVC** (`postgres-pvc` → `postgres-pv`, 100 GiB,
      `Retain`). Still bound, still holding the pre-cutover Postgres data. They
      live in `sunfire-storage` where prune is permanently disabled, so removing
      them is a manual act a git edit cannot do by accident. **The clock they
      were waiting on has run out:** the successor Worker is live on
      `sunosrs.cc`, so rolling back to data frozen at the 2026-09-04 cutover
      would now lose writes rather than recover them. The backups are the
      recovery path. See `GITOPS.md` → CloudNativePG.
- [ ] **Re-decide off-site backup, now that the data is real** *(raised
      2026-09-21)*. Both the R2 rejection and the VolSync deferral rested on "no
      successor app exists, so nothing here is worth off-siting." The Worker is
      live. Today guide media, the database, its barman backups and every sanoid
      snapshot are all on pools in the same chassis — host loss takes all of it.
      Decide on the data's actual value: `zfs send` to a rotated external disk,
      `syncoid` over Tailscale, or R2 after all. See `GITOPS.md` → CloudNativePG
      → *R2 rejected*.
- [ ] **Worker1's root disk is nearly full** *(raised 2026-09-21)*. It has
      ~2.4 GB free of 17.8 GiB (it had 7.3 GiB at Phase 7). Home Assistant's
      arrival on 09-16/17 took ~2.8 GB. Image GC is above its 85% threshold and
      failing to free anything, and DiskPressure fired for 5 minutes on 09-18.
      The next large image bump (HA is 0.65 GB compressed) needs old and new
      images on disk together. `retentionSize: 4GiB` also allows ~1.7 GB more
      TSDB growth, which is more than the ~1.4 GB left before eviction.
      **In progress** (branch `fix/worker1-disk-headroom`): `retentionSize`
      is now 3GiB, and the disk went from 20 to 32 GB. The resize is manual,
      because tofu is read-only for VM 103.

      *Done 2026-09-21:* on the Proxmox host, `qm resize 103 scsi0 +12G` and
      `TofuDisk` granted. On worker1, `growpart /dev/sda 3`, `pvresize`, then
      `lvextend -l +100%FREE -r`. `/` is now 30G with 14 GB free. The guest
      saw the new size without a SCSI rescan.

      *Still to do*, in a normal terminal on the dev VM (paste the
      `tofu@pve!import` token from LastPass at the silent prompt):
      ```bash
      cd ~/homelab/tofu
      read -rs PROXMOX_VE_API_TOKEN
      export PROXMOX_VE_API_TOKEN
      tofu apply -refresh-only \
        -target=proxmox_virtual_environment_vm.k3s_worker1
      # accept only if the diff is disk size 20 -> 32
      tofu plan -refresh=false   # expect: No changes.
      ```
      A plan alone would not persist the refresh (`tofu/README.md` →
      "State drift"). Then, on the Proxmox host, as root:
      ```bash
      pveum acl delete / --users tofu@pve --roles TofuDisk
      ```
      Merge only after the refresh. Before it, the `.tf` says 32 and the
      state still says 20. See `GITOPS.md` → kube-prometheus-stack.
- [ ] **Decide what the `192.168.50.0/24` subnet route is allowed to reach**
      *(raised 2026-09-09)*. It is approved today, so tailnet membership alone
      grants layer-3 access to every port on the LAN — see `GITOPS.md` →
      Tailscale (host). Three options: leave it; restrict it with a Tailscale
      ACL to named devices; or drop the route and go back to `ProxyJump` only
      (costs reaching `:8006` and Grafana without a jump host). **Not urgent** —
      same "100% uptime isn't guaranteed, nothing here is worth much" calculus as
      the rest of `README.md`'s operating assumptions.
- [ ] **Decide whether this repo should stay public** *(raised 2026-09-21)*.
      Several documents described it as private until that date, and one real
      decision rested on the belief — `platformAutomerge` was left off because
      branch protection was thought unavailable on a private repo, which cost
      PR #15 nine days (`GITOPS.md` → Renovate). Nothing is *cryptographically*
      wrong with public: every payload is age-encrypted and `age.key` has never
      been committed. What is public is the whole topology — IPs, hostnames,
      ports, firewall rules, credential *locations* — and the ciphertext itself,
      which is offline-attackable forever by anyone who cloned it. Either
      confirm public deliberately, or flip it and re-check what was exposed
      meanwhile.
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
- [ ] **Confirm the LLM API is actually unreachable over the tailnet.** The
      guest's `ufw` denies `:8080`/`:8081` to `192.168.50.102` specifically, so a
      routed tailnet device — which arrives as the gateway's address — should be
      refused while LAN hosts are not ([`GPU-VM.md`](GPU-VM.md)). That is the
      intent; it has not been tested *from* a tailnet device. Same route as the
      "subnet route" item above.

## Voice assistant — leftovers

**Working end to end since 2026-09-19.** V0–V5 are done except the items below;
the satellite is flashed, adopted at `192.168.50.70`, and answering on the
custom "Hey Doofus" wake word. See [`VOICE.md`](VOICE.md).

- [ ] **V3d leftover** — confirm the DHCP reservation for `192.168.50.70`. HA
      added the device by IP, because mDNS does not cross the pod network, so a
      new lease would silently break it.
- [ ] **V4 leftover** — record real wake → reply-start latency on the device
      (HA → Settings → Voice assistants → Debug). The 1.3–1.7 s measured so far
      is the pipeline alone (`scripts/voice/pipeline-test.py`, no hardware); it
      excludes on-device wake-word detection and the end-of-speech silence wait.
- [ ] **V5 leftover** — real-world false-wake notes from the HA pipeline debug
      transcripts, before deciding whether to retune `probability_cutoff` or
      train again.
- [ ] **V1f leftover** — load `chat` and `qwen27-agent` once each with
      `whisper-server` running; both are rare-use presets and weren't checked
      when VRAM headroom was measured.
- [ ] **Re-enable Home Assistant device control (Assist)** for the
      conversation agent once real entities exist — off today because the 4B
      model burns through HA's tool-iteration cap calling `GetLiveContext`
      with nothing exposed yet.
- [ ] **V5, deferred** — an LVGL status display, a CPU-only STT fallback for
      when VM 105 is off, and Prometheus metrics on the pipeline. Each measured
      against the V3e heap baseline.

## Hardware — still unknown

From [`HARDWARE.md`](HARDWARE.md) → "Still unknown":

- [ ] SMART baseline on the SATA disks — the 3 `archive-pool` members, the
      `llm-pool` disk, the `sdf` cold spare and the BOSS virtual disk. All 3 SAS
      disks are already done. G1 schedules long *tests* on four of them, but the
      baseline attribute read has never been recorded, and the `archive-pool`
      trio have degraded SMART support (no health bit) so the attributes are the
      only signal there. Address by `by-id`, not `sdX`.
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
