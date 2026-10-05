# Backlog

Every open item across this repo, in one place, so nothing is tracked only in
a runbook nobody re-reads. Each entry says what it's waiting on and where the
fuller context lives. Nothing here is blocking day-to-day operation.

## OpenTofu

- [ ] **Split the OpenTofu root module in two.** Both providers share one root,
      so a Proxmox-only plan still refreshes Cloudflare and dies without that
      token. `-refresh=false` is the workaround in use. See `GITOPS.md` →
      OpenTofu.

## Host monitoring

- [ ] **Decide on thin-pool autoextend for `local-lvm` (`pve/data`).** The pool
      is overcommitted (guest disks exceed its size) with ~16 GiB free in the
      `pve` VG, and `thin_pool_autoextend_threshold` in `/etc/lvm/lvm.conf` is
      off. `HostThinPoolData*`/`MetadataHigh` alert at 80% (`HOST-MONITORING.md`),
      so this is whether LVM should also grow the pool into the VG by itself.

## GPU / LLM VM

- [ ] **Finish the tool-calling harness (OCR, code-exec).** `web_search` and
      `fetch_url` exist (`GPU-VM.md` → *Tool calling*). Still to build: a
      CPU-only OCR tool (Tesseract), called only when `fetch_url` returns
      `unsupported-content-type` for a PDF/image, so it never competes with
      `chat`+`fast`+whisper for the card's ~2.2 GiB of free VRAM; and a
      sandboxed code-exec tool for `qwen27-agent`, with no sandbox mechanism
      chosen yet. Also still to do: install the tools on the guest and
      confirm `web_search` end to end once SearXNG is running.
- [ ] **Verify the boot-time ReBAR resize across a real host reboot.** The first
      attempt (2026-09-16) failed at the 32 GiB step; the sequence was fixed in
      `gpu-rebar.sh` (PR #24) and passed a manual `systemctl restart`, but the
      *full* boot path (32 GiB refused → 4 GiB → 32 GiB, replayed automatically at
      boot) has not yet been proven by an actual reboot. Check
      `journalctl -u gpu-rebar -b` after the next one. See
      [`GPU-VM.md`](GPU-VM.md) and [`archive/GPU-VM-BUILD.md`](archive/GPU-VM-BUILD.md) → D4.

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
