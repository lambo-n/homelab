# Backlog

Every open item across this repo, in one place, so nothing is tracked only in
a runbook nobody re-reads. Each entry says what it's waiting on and where the
fuller context lives. Nothing here is blocking day-to-day operation.

## GPU / LLM VM

- [ ] **Verify the boot-time ReBAR resize across a real host reboot.** The first
      attempt (2026-09-16) failed at the 32 GiB step; the sequence was fixed in
      `gpu-rebar.sh` (PR #24) and passed a manual `systemctl restart`, but the
      *full* boot path (32 GiB refused → 4 GiB → 32 GiB, replayed automatically at
      boot) has not yet been proven by an actual reboot. Check
      `journalctl -u gpu-rebar -b` after the next one. See
      [`GPU-VM.md`](GPU-VM.md) and [`archive/GPU-VM-BUILD.md`](archive/GPU-VM-BUILD.md) → D4.
- [ ] **Trial Hermes Agent against `qwen27`** as a general agent with persistent
      memory, editing with its own `patch` tool; Aider stays as the fallback
      for multi-file Python work. Run it as a separate `hermes` user on the dev
      VM (no kubeconfig, no `sops`/`age.key`), against a throwaway clone of
      this repo. Record the prompt size with unused toolsets off, how many
      edits needed a similarity match, and wall time per task.
      Configure a custom provider with the model name `qwen27`: a model name
      containing `openai/` makes Hermes offer Qwen OpenAI's patch format.
      Waits on: the owner creating the user. Adopt or drop it, then
      document the result in [`GPU-VM.md`](GPU-VM.md) → *Consumers*.

## Voice assistant — leftovers

**Working end to end.** The satellite is flashed, adopted at `192.168.50.70`, and answering on the
custom "Hey Doofus" wake word; the items below are what is left. See [`VOICE.md`](VOICE.md).

- [ ] **Judge the wake word at `probability_cutoff: 0.93`** after a few days
      of real use. It runs at 0.93 because 0.97 gave zero false wakes but often
      missed the correct phrase. If false wakes appear, go back to 0.95. If misses
      persist, retrain with the owner's own recordings as positives rather than
      dropping far below 0.90. See [`VOICE.md`](VOICE.md) → *Wiring it in*.
- [ ] **Re-enable Home Assistant device control (Assist)** for the
      conversation agent once real entities exist — off today because the 4B
      model burns through HA's tool-iteration cap calling `GetLiveContext`
      with nothing exposed yet.
- [ ] **Track the `wyoming-whisper` patch and alert on STT failures.** The
      bridge (`/opt/wyoming/whisper-api/wyoming_whisper_api_client/handler.py`
      on VM 105) is patched in place to return an empty transcript when
      `whisper-proxy` answers non-200, instead of dying; the patch is not in
      this repo and a reinstall of the package would drop it. Copy the
      handler under `scripts/voice/` and deploy it from there, and alert on
      non-200 from the proxy so a silent satellite shows up in Grafana.
- [ ] **V5, deferred** — an LVGL status display, a CPU-only STT fallback for
      when VM 105 is off, and Prometheus metrics on the pipeline. Each measured
      against the V3e heap baseline.

## Hardware — still unknown

From [`HARDWARE.md`](HARDWARE.md) → "Still unknown":

- [ ] BOSS-S2 boot mirror health — invisible to every monitor in this repo
      (verified: no Prometheus series exists for `sda` past its own pass/fail
      bit — see `HARDWARE.md` → *SATA SMART baseline*). A failed M.2 surfaces
      only in iDRAC or the BOSS CLI, neither reachable from the dev VM — the
      owner's to check.
- [ ] Total front-bay count and how many are physically empty — decides whether
      expansion needs a new chassis or just more disks.

## Backlog — not now

- [ ] kubeconform or [`flux-schema`](https://github.com/fluxcd/flux-schema)
      validation in CI *(own recommendation — the reference repo does not do this)*.
- [ ] `tofu validate` + `tofu fmt -check` in CI for PRs touching `tofu/`, once per
      root (`tofu/cloudflare/`, `tofu/proxmox/`). Needs no credentials, but
      `tofu init` downloads providers, so the job isn't hermetic.
      See `tofu/README.md#versions` for the incident that motivated this
      (Renovate bumped a `versions.tf` without refreshing the lock file, and every
      tofu command failed on a fresh checkout for six days, unnoticed).
- [ ] Loki + Promtail for logs — wants its own storage answer first; the
      dedicated worker1 data disk on `archive-pool` in
      [`archive/DISK-SPACE-HEADROOM.md`](archive/DISK-SPACE-HEADROOM.md) (phase C)
      is the fit.
- [ ] A dedicated data disk for `k3s-worker1` on `archive-pool`, for the TSDB and
      the other `local-path` volumes. Not needed at ~45% free; do it if the TSDB
      needs more than ~6 GiB (longer retention, Loki) or worker1's `/` falls under
      25% free despite the kubelet image-GC setting. The procedure is phase C of
      [`archive/DISK-SPACE-HEADROOM.md`](archive/DISK-SPACE-HEADROOM.md).
- [ ] Talos Linux for the k3s nodes — the real endgame for declarative node
      config, but a rebuild.
- [ ] Gateway API / Envoy Gateway instead of Traefik Ingress (CRDs already present).

## Related

- [`GITOPS.md`](GITOPS.md) — per-tool current reference; "Explicitly rejected"
  there has the standing decisions that are *not* backlog (closed questions,
  not open ones)
- [`archive/GITOPS-MIGRATION.md`](archive/GITOPS-MIGRATION.md) — the completed
  seven-phase migration this backlog grew out of
