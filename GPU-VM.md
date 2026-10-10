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
| GuC firmware | **70.72.1**, from upstream `linux-firmware` (commit `4291fa65d305`), in `/lib/firmware/updates/xe/bmg_guc_70.bin`, which overrides noble's older `70.44.1` blob. See *GuC firmware override* below |
| Snapshots | None. `llm-pool` is deliberately excluded from `sanoid.conf` — model weights are re-downloadable, so there's nothing worth snapshotting |
| OpenTofu | Authored and created by `tofu apply` (not imported), `tofu/proxmox/proxmox-llm-vm.tf`. `prevent_destroy` is on. Its own scoped API token (`tofu@pve!llm`) can write to `/vms/105` only — see `tofu/README.md` |

**`gpu-rebar.service`** (`scripts/gpu-rebar.sh` + `.service`, installed on the
host): runs before `pve-guests.service` on every host boot. It replays the
sequence that actually releases the card's 56 GiB SR-IOV VF BAR reservation —
attempting 32 GiB first (which fails and releases the reservation), then 4 GiB,
then 32 GiB again — and always rebinds both the GPU and its audio function to
`vfio-pci` on exit. A failed resize leaves the card usable at a smaller BAR; it
never blocks boot. Check `journalctl -u gpu-rebar -b` after any host reboot.

**GuC firmware override:** the HWE kernel's `xe` driver asks for a newer
Battlemage GuC than noble's `linux-firmware-intel-graphics` ships. It runs on
the older one but logs "is recommended" at every boot. Upstream's
`xe/bmg_guc_70.bin` sits in `/lib/firmware/updates/xe/` (uncompressed, sha256
`de81c75f…6985ab398b`). The kernel searches `updates/` first and tries
uncompressed names before `.zst`, and `dpkg` never writes there. The initramfs
was rebuilt after installing it, so an early-loaded `xe` gets the same blob.

> ⚠️ **The override shadows every future Ubuntu update of this blob.** When
> `apt-cache policy linux-firmware-intel-graphics` shows a new version, check
> the GuC version it ships. If it's the same or newer, delete the override,
> run `sudo update-initramfs -u`, and reboot.

Checking it (on the guest):

| Command | Healthy |
|---|---|
| `sudo dmesg \| grep -i guc` | `Using GuC firmware from xe/bmg_guc_70.bin version 70.72.1` on GT0 and GT1; no `is recommended` line |
| a chat completion to `:8080/v1` | a correct answer at normal speed (`chat`: ~55 tok/s generation) |

History: [`archive/GPU-VM-BUILD.md`](archive/GPU-VM-BUILD.md) → *GuC firmware override*.

---

## The inference stack

`llama.cpp` (`v0.4.1`, built with Intel SYCL/oneAPI — roughly 2× faster than
Vulkan on this card) running as two systemd services on the guest, both system
user `llama`, plus an image-generation server that has the card to itself
(*Image generation* below):

| Service | Port | Serves | Notes |
|---|---|---|---|
| `llama-fast.service` | 8081 | **Qwen3.5-4B**, `-c 8192`, always loaded | thinking disabled, `-n 2048` cap |
| `llama-router.service` | 8080 | preset models below, `--models-max 1` | loads on first request, evicts the previous preset (LRU) |
| `sd-server.service` + `sd-proxy.service` | 8082 | **FLUX.2-dev**, image mode only | not enabled; `sudo llm-mode image` stops every other model on the card first |

**Router presets**, in `/etc/llama/models.ini`:

| Preset | Model | Context (beside `fast`) |
|---|---|---:|
| `qwen27` | Qwen3.8-27B UD-Q6_K_XL | 65,536 (sized to leave room for `whisper-server` — see [`VOICE.md`](VOICE.md)) |
| `chat` | Qwen3.6-35B-A3B UD-Q4_K_XL | 262,144 (full) |
| `qwen27-agent` | Qwen3.8-27B UD-Q6_K_XL, alone | ~195,072 (`sudo llm-mode agent` first — stops `llama-fast`) |

`llm-mode agent|normal|image|status` (on the guest) switches between the
always-on `fast` service, the long-context solo mode, and image mode.
`llama-fast.service` `Wants=whisper-proxy.service`, so however `fast` starts,
`whisper-server` and its proxy start with it. All models live in `/models`
(the `llm-pool` disk) and are checksum-verified against Hugging Face at
download time. Llama 3.1 8B Q8_0 is also downloaded but not wired into a
preset today.

**Access control:** every model role, every port answers `401` without an API
key, except `/health`, which answers `200` to anyone on the LAN. Three keys exist in `/etc/llama/api-keys` (owner, cluster, agents), each a
64-character line generated with `openssl rand -hex 32`.

**Firewall (`ufw` on the guest):** LAN-only. Port 22 open from anywhere
(ProxyJump SSH arrives via the tailscale gateway); ports 8080/8081/8082 open to
`192.168.50.0/24` but explicitly denied to the gateway's own address
(`192.168.50.102`), because routed tailnet traffic arrives as that address.
The tailnet policy also grants nothing on `.107`
([`GITOPS.md`](GITOPS.md#tailscale-host)), so a routed device is refused
twice. Ports 9100
(node-exporter) and 10200/10300 (Wyoming Piper and Whisper, for Home Assistant)
are open to the three k3s node IPs only, so the dev VM cannot reach the Wyoming
ports directly.

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

### Tool calling

`scripts/llm/tools/` gives the `llm` CLI three tools (all four presets are
`supports_tools: true`): `web_search` (SearXNG in the cluster,
[`GITOPS.md`](GITOPS.md) → *searxng*), `fetch_url` (a page's readable text) and
`ocr_url` (text from a PDF or image; `fetch_url` answers
`unsupported-content-type` for those, and the model then calls it).
`agent_tools.py` is the same three plus `run_python` (model-written Python in a
sandbox), and in use only `qwen27-agent` is pointed at it: `fast` and the other
presets read fetched pages, so they must never be one prompt injection away
from running code. Install the files together on the guest, and pass the tools
file with `--functions`:

```bash
ssh llm mkdir -p .config/io.datasette.llm/tools
```
```bash
scp scripts/llm/tools/{fetch,ocr,pyrun,tools,agent_tools}.py \
  llm:.config/io.datasette.llm/tools/
```

`ocr_url` and `run_python` also need the packages and the sandbox wrapper on
the guest:

```bash
ssh llm sudo apt-get install -y tesseract-ocr poppler-utils
```
```bash
scp scripts/llm/llm-sandbox llm:/tmp/
```
```bash
ssh llm sudo install -m 755 /tmp/llm-sandbox /usr/local/bin/
```
```bash
llm -m fast --td \
  --functions ~/.config/io.datasette.llm/tools/tools.py \
  "Read https://example.com and give me its title"
```

| | |
|---|---|
| `SEARXNG_URL` | Defaults to `http://192.168.50.104:8080` (a node IP; the Service answers on all three) |
| `LLM_TOOLS_DIR` | Where `tools.py` finds `fetch.py`; defaults to `~/.config/io.datasette.llm/tools` |
| `fetch_url` limits | Public `http`/`https` only, 2 MiB read, `max_chars` clamped to 12,000 (`fast` has an 8,192-token window) |
| `ocr_url` limits | 10 MiB download, English only, `max_pages` clamped to 10 (default 5); a PDF with a text layer uses `pdftotext`, only a scan is rasterised (150 dpi) and OCR'd, ~1 s per page |
| `LLM_SANDBOX` | The sandbox wrapper `ocr.py` calls through `sudo -n`; defaults to `llm-sandbox` |
| `run_python` limits | Standard library only, code ≤ 32 KiB, no network, 16 MiB scratch at `/mnt`, 512 MiB RAM, one CPU, 32 tasks, 30 s; returns `exit_code`, `stdout` (6,000 chars) and `stderr` (last 3,000). A kill by the memory or time limit comes back as `error: killed-by-limit` |

> ⚠️ **`fetch_url` is an SSRF boundary, because the model picks the URL and a
> fetched page can steer it.** `fetch.py` resolves the host and refuses it
> (`blocked-address`) unless every address is globally routable, connects to the
> address it checked, and re-checks each redirect hop. Loopback, the LAN, the
> k3s nodes and cloud metadata addresses are therefore unreachable through it.
> Keep that property if you change the fetcher.

> ⚠️ **`ocr_url` feeds hostile files to poppler and Tesseract, so they only run
> through `llm-sandbox`.** It runs one allow-listed binary (`pdfinfo`,
> `pdftotext`, `tesseract`, or the fixed `pdf-ocr-page` pipeline) as a
> throwaway systemd unit: no network, read-only filesystem, private `/tmp`,
> 1 GiB memory, 64 tasks, 60 s. Data goes over stdin/stdout. Do not swap it
> for `systemd-run --user`: with AppArmor restricting unprivileged user
> namespaces on this guest, `PrivateNetwork` is silently not applied there.
> `dev` already has passwordless `sudo`, so the wrapper is containment, not a
> privilege boundary. OCR is CPU-only and never touches the card's VRAM.
>
> **`run_python` is the same wrapper's `python-run` profile, and the code is
> the attacker's.** It has no network, so nothing it reads can leave, and the
> unit runs as a one-shot unprivileged user that cannot read `/home/dev` or
> `/etc/llama`. `/tmp` is blocked and `/mnt` is a size-limited tmpfs, because
> `DynamicUser` forces a disk-backed private `/tmp` that ignores a size limit.
> Keep `run_python` out of `tools.py`; a test enforces that.

> ⚠️ **`llm --functions` registers every public callable in the file.**
> `tools.py` exposes exactly `web_search`, `fetch_url` and `ocr_url`; everything else is
> underscore-prefixed and uses `import x`, never `from x import y`, or the
> import would become a tool. The file is `exec`'d without `__file__`, so it
> cannot import a sibling module by relative path.

**Checking it** — `python3 -m unittest discover -s scripts/llm/tools` passes
with no network. Then, on the guest:

| Command | Healthy |
|---|---|
| the `llm … --functions` call above | a `Tool call: fetch_url(...)` line, then a title of "Example Domain" |
| same, asking it to read `http://192.168.50.104:8123/` | `error: "blocked-address: 192.168.50.104"` in the tool result |
| same, asking it to read `https://mozilla.github.io/pdf.js/web/compressed.tracemonkey-pldi-09.pdf` | `fetch_url` returns `unsupported-content-type`, then an `ocr_url` call with `method: "text-layer"`, `pages: 14` |
| `ssh llm sudo llm-sandbox bash` | `'bash' is not allow-listed`, exit 2 |
| `llm -m qwen27 --functions …/agent_tools.py "Use run_python to sum the primes below 1000"` | a `Tool call: run_python(...)` with `exit_code: 0` and `76127` |
| `echo 'import socket; socket.create_connection(("1.1.1.1",53),2)' \| ssh llm sudo llm-sandbox python-run` | exit code `1` and `Network is unreachable` in the stderr part |
| `echo 'while True: pass' \| ssh llm sudo llm-sandbox python-run` | no output after 30 s (the unit was killed) |
| `curl 'http://192.168.50.104:8080/search?q=test&format=json'` | JSON with a non-empty `results` array |

### Image generation

`sudo llm-mode image` gives the whole card to
[stable-diffusion.cpp](https://github.com/leejet/stable-diffusion.cpp)
(`master-951-f89d9b1`, SYCL build in `/models/src/stable-diffusion.cpp/build-sycl`)
serving FLUX.2-dev. `sudo llm-mode normal` gives it back.

| | |
|---|---|
| Weights (`/models/flux2/`) | `flux2-dev-Q6_K.gguf` (25.5 GiB, `city96/FLUX.2-dev-gguf`), text encoder `Mistral-Small-3.2-24B-Instruct-2506-Q4_K_M.gguf` (13.3 GiB, `unsloth/…-GGUF`), `flux2-vae.safetensors` (`Comfy-Org/flux2-dev`, ungated). Licence: FLUX.2-dev non-commercial |
| Server | `sd-server` on `127.0.0.1:8092`, `--offload-to-cpu --diffusion-fa --vae-tiling`; request defaults 1024×1024, 28 steps, euler, CFG 1.0, random seed → `scripts/llm/sd-server.service` |
| Memory | All 39.4 GiB of weights in guest RAM; each stage moves onto the card while it runs: text encoder ~11 GiB, then the diffusion model, peaking at **29.2 of 31.9 GiB** VRAM at 1024². ~1 GiB between images |
| Speed (1024²) | Prompt encoding 8 s (32 s on the first request after start, reading the weights from disk); ~50 s moving the diffusion model onto the card; **~12.5 s per sampling step**; 4 s decode. The 28-step default is ~7 min per image |
| Front door | `sd-proxy` on `:8082`: the `/etc/llama/api-keys` Bearer keys (`/health` open, as on the llama ports) and saves every image to `/models/images/` → `scripts/llm/sd-proxy` |
| Output | `/models/images/<YYYYmmdd-HHMMSS>-<id>-<n>.png`, owner `llama`; the response's `X-Saved-Images` header names the files |
| APIs | OpenAI `POST /v1/images/generations` (synchronous), AUTOMATIC1111 `/sdapi/v1/txt2img`, native async `/sdcpp/v1/img_gen` + `GET /sdcpp/v1/jobs/<id>` → `examples/server/api.md` upstream |

**One model on the card, enforced by systemd.** `sd-server.service`
`Conflicts=` with `llama-fast`, `llama-router` and `whisper-server`, so
starting image mode stops all three (a loaded router preset goes with the
router), and starting any of them stops image mode. `whisper-proxy` stops with
`whisper-server`, and `llama-fast`'s `Wants=` brings both back, so **Home
Assistant and the `transcribe` app have no speech-to-text while image mode is
on** — Piper TTS is CPU and keeps running. `sd-proxy` is `BindsTo=` `sd-server`: outside image mode,
`:8082` refuses connections.

> ⚠️ **`/models/images/` is not backed up.** `llm-pool` is excluded from
> sanoid because weights re-download; generated images don't. Copy off what
> you want to keep.

> ⚠️ **`--vae-tiling` is required on this card.** Decoding a 1024² latent in
> one piece fails in the SYCL backend (`Provided range and/or offset does not
> fit in int`, `Error OP IM2COL`) after the whole sampling run, and the crash
> restarts `sd-server`.

> ⚠️ **`sd-server` has no authentication and never writes to disk.** Both are
> `sd-proxy`'s job, so `sd-server` must stay on loopback. A completed async
> job returns its images on every poll; the proxy saves each job id once.

Install (on the guest, from a copy of `scripts/llm/`):

```bash
sudo install -m 755 sd-proxy llm-mode /usr/local/sbin/
```
```bash
sudo install -m 644 sd-server.service sd-proxy.service /etc/systemd/system/
```
```bash
sudo install -d -o llama -g llama /models/images
```
```bash
sudo systemctl daemon-reload
```
```bash
sudo ufw insert 2 deny from 192.168.50.102 to any port 8082 proto tcp
```
```bash
sudo ufw insert 4 allow from 192.168.50.0/24 to any port 8082 proto tcp
```

**Checking it** — `python3 -m unittest scripts/llm/test_sd_proxy.py` passes
with no network. Then, on the guest:

| Command | Healthy |
|---|---|
| `sudo llm-mode image` then `sudo llm-mode status` | `sd-server: active`; fast, router and whisper `inactive` |
| `curl -s -o /dev/null -w '%{http_code}' localhost:8082/sdcpp/v1/capabilities` | `401` |
| a `POST /v1/images/generations` with a key (see *Generating an image*) | `200`, and a new file in `/models/images/` named in `X-Saved-Images` |
| `grep -h 'mode=.*} 1\|whisper_up' /var/lib/prometheus/node-exporter/*.prom` in image mode | `llm_mode{mode="image"} 1` and `whisper_up 0` (the timer runs every 15 s) |
| `grep -E 'flux2\|^sd_(busy\|step)' /var/lib/prometheus/node-exporter/llama.prom` after one image | `model_loaded{model="flux2-dev"} 1`, `sd_busy 0`, `sd_step_seconds` ≈ 10 |
| `sudo llm-mode normal` then `sudo llm-mode status` | fast, router and whisper `active`; `sd-server: inactive`; `whisper_up 1` once whisper's ~34 s warm-up ends |

#### Generating an image

```bash
K=$(sudo sed -n 1p /etc/llama/api-keys)
```
```bash
curl -s -D- -o /dev/null localhost:8082/v1/images/generations \
  -H "Authorization: Bearer $K" -H 'Content-Type: application/json' \
  -d '{"prompt":"a lighthouse at dusk, oil painting"}'
```

The `X-Saved-Images` line names the file under `/models/images/`. Size, steps
and seed go in `<sd_cpp_extra_args>` inside the prompt for the OpenAI route,
or as fields of the native `/sdcpp/v1/img_gen` body.

### Observability

`prometheus-node-exporter` on the guest (GPU temps/power via its hwmon
collector) plus two textfile collectors:

- `scripts/llm/llama-metrics` (`llama-metrics.timer`, every 15 s) polls
  `llama-fast` and any *loaded* router preset for tokens/sec, requests and
  cache-reuse — the router isn't scraped directly, since `/metrics?model=`
  400s on an unloaded preset. It also writes the card's mode
  (`llm_mode{mode="normal|agent|image|other"}`, from unit state), VRAM in use
  (`llm_gpu_vram_used_bytes`, from `xpu-smi stats -j`; hwmon has no VRAM
  figure), `sd_server_up`, and copies in `sd-proxy`'s counters from
  `/run/sd-proxy/sd.prom` while image mode is on. Image mode also appears as
  a preset, `flux2-dev`, under the llama names
  (`llamacpp:model_loaded`, `llamacpp:requests_processing`), so the
  dashboard's per-model row covers it. `sd-server` has no `/metrics`, so its
  busy flag (`sd_busy`) and the last completed image's stage times
  (`sd_stage_seconds{stage="encode|weights|sample|decode"}`,
  `sd_sampling_steps`, `sd_step_seconds`) are parsed from its journal, current
  run only. Busy covers every API, async `/sdcpp/v1` jobs included.
- `scripts/voice/whisper-proxy` sits between `wyoming-whisper` and
  `whisper-server`, timing every real transcription and classifying it GPU
  (SYCL, <1 s) or CPU fallback (≥1 s). whisper.cpp's server has no `/metrics`
  endpoint and logs its device only once at startup, so this is the live
  signal for a silent fallback afterward — but latency only updates when
  someone actually uses the voice assistant — see [`VOICE.md`](VOICE.md) →
  *V1f*. `whisper_up` is set to 1 when the proxy starts (after
  `whisper-server`'s warm-up) and to 0 by its unit's `ExecStopPost`, so it
  reads 0 in image mode.

Both write to node_exporter's textfile collector, scraped by the cluster's
Prometheus via `kubernetes/apps/observability/llm-vm/`; dashboard `LLM VM —
Arc Pro B70` (`uid llm-vm-gpu`) in Grafana. `PrometheusRule llm-vm` alerts on
GPU temp > 90°C and the VM being unreachable. The dashboard's *Image
generation* row shows the card mode, VRAM used, whether `sd-server` is
generating, images and failures per 24 h, per-image wall time, and the last
image's stage breakdown. The *Model: flux2-dev* row shows loaded / idle /
busy, seconds per sampling step (from step 2; step 1 also builds the graph),
prompt-encoding time, images per 24 h and the last image's wall time.

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
- `tofu/proxmox/proxmox-llm-vm.tf`, `tofu/README.md` — the VM definition and its token
- `scripts/llm/` — the services, wrapper scripts and configs referenced above
