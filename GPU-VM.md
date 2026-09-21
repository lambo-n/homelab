# GPU VM — Intel Arc Pro B70 passed whole to one LLM guest

**VM 105 (`llm`, `192.168.50.107`)** is a dedicated guest with the host's only
GPU passed through whole, running a local inference stack for the rest of the
homelab and the owner's workstation. For how it was built — the passthrough
work, the ATS hard-lockup, the Resizable BAR saga — see
[`archive/GPU-VM-BUILD.md`](archive/GPU-VM-BUILD.md). This file is the current
state: what's running, how it's configured, and how to reach it.

---

## Hardware and VM configuration

| | |
|---|---|
| Guest | `q35` + OVMF, `cpu host`, 8 vCPU (unpinned — the host has one NUMA node), 64 GiB RAM (`balloon 0` — a passthrough device pins all guest memory) |
| Disks | 32 GiB root on `local-lvm`; 1400 GiB models disk on `llm-pool` (single ZFS disk on `sde`, no redundancy — see [`HARDWARE.md`](HARDWARE.md)) |
| GPU | Intel Arc Pro B70, 32 GiB VRAM, passed through whole via the `arc-b70` PCI mapping (`hostpci0: mapping=arc-b70,pcie=1`). Host driver `vfio-pci`; no k3s node or other guest sees it |
| Kernel requirement | `pci=noats` on the **host** kernel command line — passthrough with ATS enabled hard-locks the host. Never remove it while this card is passed through |
| Resizable BAR | **Full 32 GiB, CPU-visible.** The card defaults to a 256 MiB BAR; `gpu-rebar.service` resizes it to 32 GiB at every host boot, before guests start. Model loads are disk/CPU-bound, not BAR-bound, once resized |
| Guest OS | Ubuntu 24.04 LTS on the HWE kernel (≥ 6.17) — the GA kernel predates driver support for this card |
| Snapshots | None. `llm-pool` is deliberately excluded from `sanoid.conf` — model weights are re-downloadable, so there's nothing worth snapshotting |
| OpenTofu | Authored and created by `tofu apply` (not imported), `tofu/proxmox-llm-vm.tf`. `prevent_destroy` is on. Its own scoped API token (`tofu@pve!llm`) can write to `/vms/105` only — see `tofu/README.md` |

**`gpu-rebar.service`** (`scripts/gpu-rebar.sh` + `.service`, installed on the
host): runs before `pve-guests.service` on every host boot. It replays the
sequence that actually releases the card's 56 GiB SR-IOV VF BAR reservation —
attempting 32 GiB first (which fails and releases the reservation), then 4 GiB,
then 32 GiB again — and always rebinds both the GPU and its audio function to
`vfio-pci` on exit. A failed resize leaves the card usable at a smaller BAR; it
never blocks boot. Check `journalctl -u gpu-rebar -b` after any host reboot.

---

## The inference stack

`llama.cpp` (`v0.4.1`, built with Intel SYCL/oneAPI — roughly 2× faster than
Vulkan on this card) running as two systemd services on the guest, both system
user `llama`:

| Service | Port | Serves | Notes |
|---|---|---|---|
| `llama-fast.service` | 8081 | **Qwen3.5-4B**, `-c 8192`, always loaded | thinking disabled, `-n 2048` cap |
| `llama-router.service` | 8080 | preset models below, `--models-max 1` | loads on first request, evicts the previous preset (LRU) |

**Router presets**, in `/etc/llama/models.ini`:

| Preset | Model | Context (beside `fast`) |
|---|---|---:|
| `qwen27` | Qwen3.8-27B UD-Q6_K_XL | 65,536 (cut from 81,920 on 2026-09-17 to leave room for `whisper-server` — see [`VOICE.md`](VOICE.md)) |
| `chat` | Qwen3.6-35B-A3B UD-Q4_K_XL | 262,144 (full) |
| `qwen27-agent` | Qwen3.8-27B UD-Q6_K_XL, alone | ~195,072 (`sudo llm-mode agent` first — stops `llama-fast`) |

`llm-mode agent|normal|status` (on the guest) switches between the always-on
`fast` service and the long-context solo mode. All models live in `/models`
(the `llm-pool` disk) and are checksum-verified against Hugging Face at
download time. Llama 3.1 8B Q8_0 is also downloaded but not wired into a
preset today.

**Access control:** every model role, every port answers `401` without an API
key. Three keys exist in `/etc/llama/api-keys` (owner, cluster, agents), each a
64-character line generated with `openssl rand -hex 32`.

**Firewall (`ufw` on the guest):** LAN-only. Port 22 open from anywhere
(ProxyJump SSH arrives via the tailscale gateway); ports 8080/8081 open to
`192.168.50.0/24` but explicitly denied to the gateway's own address
(`192.168.50.102`), because routed tailnet traffic arrives as that address.
The tailnet policy also grants nothing on `.107`
([`GITOPS.md`](GITOPS.md#tailscale-host)), so a routed device is refused
twice. Port 9100
(node-exporter) is open to the three k3s node IPs only.

### Consumers

- **Cluster apps** — `http://192.168.50.107:8080/v1` (router) or `:8081/v1`
  (`fast`), with the cluster API key (delivered via SOPS).
- **CLI chat** — Simon Willison's `llm` (0.35, via `pipx`) on the guest itself,
  configured from `scripts/llm/extra-openai-models.yaml`.
- **Claude Code** — `scripts/llm/claude-local` wraps `claude` to point at one
  router preset (`CLAUDE_LOCAL_MODEL=qwen27|qwen27-agent|chat`), runs *from the
  dev VM* (file edits, commands and MCP servers execute there; only model
  requests go to the guest), and uses a separate settings/history directory
  (`CLAUDE_CONFIG_DIR=~/.claude-local`) so the normal `claude` login is
  untouched. Requires `scripts/llm/templates/qwen3.8-27b.jinja` — the stock
  Qwen3.8 GGUF template rejects Claude Code's mid-conversation system messages.
  Known limits: no WebSearch/WebFetch (both call Anthropic's own servers), no
  MCP tool search on a non-first-party base URL, and any other machine using
  this needs its own copy of the wrapper and key since the API is LAN-only.

### Observability

`prometheus-node-exporter` on the guest (GPU temps/power via its hwmon
collector) plus `scripts/llm/llama-metrics` (a `.timer`-driven collector
polling `llama-fast` and any *loaded* router preset for tokens/sec, requests,
and cache-reuse — the router isn't scraped directly, since `/metrics?model=`
400s on an unloaded preset). Scraped by the cluster's Prometheus via
`kubernetes/apps/observability/llm-vm/`; dashboard `LLM VM — Arc Pro B70`
(`uid llm-vm-gpu`) in Grafana. `PrometheusRule llm-vm` alerts on GPU temp > 90°C
and the VM being unreachable.

---

## Related

- [`archive/GPU-VM-BUILD.md`](archive/GPU-VM-BUILD.md) — the full build log:
  hardware bring-up, the PCI mapping and scoped API token, the ATS lockup and
  its fix, every step of the ReBAR resize, and the first llama.cpp benchmarks
- [`HARDWARE.md`](HARDWARE.md) — the GPU and `llm-pool` in the physical inventory
- [`VOICE.md`](VOICE.md) — the voice assistant stack (whisper/piper STT-TTS,
  ESPHome, Home Assistant) sharing this VM's GPU alongside `llama-server`
- [`BACKLOG.md`](BACKLOG.md) — the one open item from this build (verifying the
  boot-time ReBAR resize across a real host reboot)
- `tofu/proxmox-llm-vm.tf`, `tofu/README.md` — the VM definition and its token
- `scripts/llm/` — the services, wrapper scripts and configs referenced above
