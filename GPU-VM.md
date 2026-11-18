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
| `neo-coder` | Qwen3.8-27B "Brainwaves HERETIC" NEO-CODER Q6_K (community fine-tune, uncensored), MTP speculative decoding | 65,536 |
| `chat` | Qwen3.6-35B-A3B UD-Q4_K_XL | 262,144 (full) |
| `qwen27-agent` | Qwen3.8-27B UD-Q6_K_XL, alone, MTP speculative decoding | 163,840 (`sudo llm-mode agent` first — stops `llama-fast`) |
| `neo-coder-agent` | the `neo-coder` GGUF, alone, MTP speculative decoding | 196,608 (`sudo llm-mode heretic` loads it) |

**`qwen27-agent` decodes speculatively with the model's own MTP head**
(`spec-type = draft-mtp`, two draft tokens, q8_0 draft KV cache): about
**39 tok/s** generation against 18.5 without it. Code accepts 89–94% of
drafted tokens; prose about 47%, so prose gains less. Prompt processing is
unchanged (~477 tok/s on a 135k prompt, so a full window takes minutes).

> ⚠️ **The MTP layer's KV cache is why this preset is 163,840, not 195,072.**
> At 195,072 the load fails with `UR_RESULT_ERROR_OUT_OF_DEVICE_MEMORY` even
> with a q8_0 draft cache. 163,840 leaves ~1 GiB free (33.2 GB in use);
> 180,224 loads with ~250 MB. Hermes' `context_length` must match `ctx-size`.

| Check | Healthy |
|---|---|
| `journalctl -u llama-router \| grep "draft acceptance"` after a request | `draft acceptance = 0.8…–0.9…` on code, `mean len` ≈ 2.8 |
| `llm_gpu_vram_used_bytes` in `/var/lib/prometheus/node-exporter/llama.prom` with the preset loaded | ≈ 33.2 GB |

**`neo-coder` runs MTP beside `fast`.** Its Q6_K is 1.27 GB lighter than
UD-Q6_K_XL, enough for the draft cache at 65,536: about **38 tok/s**, 93%
acceptance on code, and 29.1 GB on the card with `fast` and `whisper` running
beside it. Its GGUF embeds an older Qwen template that raises on mid-conversation
system messages, so the preset uses the patched base template (same tokenizer).

**`neo-coder-agent` is the same model with the card to itself**, at
196,608 context, 3× `neo-coder`'s. The KV plus MTP draft cache costs about
46 KiB per token at q8_0, and the lighter weights buy ~27k tokens over
`qwen27-agent`. It holds 33.5 GB on the card (~0.7 GB free) and stays
there through a 189k-token prompt: ~485 tok/s prefill (about 6.5 min),
~35 tok/s generation on a short prompt, ~12 tok/s at a full window, 97%
draft acceptance on code. 180,224 is the fallback if a llama.cpp upgrade
grows the compute buffers.

| Check | Healthy |
|---|---|
| `sudo llm-mode heretic` | `neo-coder-agent loaded alone` |
| `curl` `/slots?model=neo-coder-agent` | `n_ctx` 196608 |
| `llm_gpu_vram_used_bytes` with it loaded | ≈ 33.5 GB |

> ⚠️ **Any request naming another preset evicts it** (`--models-max 1`),
> including `GET /slots?model=neo-coder`, which loads the preset it names.
> Poll `/slots` only for the preset that is already loaded.

History and the benchmark table: [`archive/GPU-VM-BUILD.md`](archive/GPU-VM-BUILD.md#mtp-speculative-decoding-on-qwen27-agent-2026-10-15).

`llm-mode agent|heretic|music-instrument|normal|image|status` (on the guest)
switches between the always-on `fast` service, the long-context solo mode,
image mode, music mode (*Music generation* below) and heretic mode.
**`sudo llm-mode heretic`** stops `fast` and `whisper-server` and loads
`neo-coder-agent` through the router's `/models/load`, so it is the only
model on the card, at 196,608 context. Home Assistant has no speech-to-text
until `sudo llm-mode normal`.
`llm_mode` reports heretic mode as `agent`, because both run the router
without `fast`.
`llama-fast.service` `Wants=whisper-proxy.service`, so however `fast` starts,
`whisper-server` and its proxy start with it. All models live in `/models`
(the `llm-pool` disk) and are checksum-verified against Hugging Face at
download time, except `neo-coder`'s GGUF, which was copied in by hand from
no pinned upstream revision: its hash is in `/models/gguf/SHA256SUMS`
(`sha256sum -c` there). Llama 3.1 8B Q8_0 is also downloaded but not wired into a
preset today.

**Access control:** every model role, every port answers `401` without an API
key, except `/health`, which answers `200` to anyone on the LAN. Three keys exist in `/etc/llama/api-keys` (owner, cluster, agents), each a
64-character line generated with `openssl rand -hex 32`.

**Firewall (`ufw` on the guest):** Port 22 open from anywhere (ProxyJump SSH
arrives via the tailscale gateway). Ports 8080 (the router) and 8082 (image
generation) are open to `192.168.50.0/24`, which includes the gateway
(`192.168.50.102`) that routed tailnet traffic arrives as, so tailnet members
reach them too; the tailnet policy grants `.107` `tcp:8080` and `tcp:8082` and
nothing else ([`GITOPS.md`](GITOPS.md#tailscale-host)). Port 8081 is LAN-only:
open to `192.168.50.0/24` but explicitly denied to `.102`. ufw cannot tell
tailnet devices apart, so the tailnet policy is the only filter on who reaches
8080/8082 from outside; the API key is the second. History:
[`archive/GPU-VM-BUILD.md`](archive/GPU-VM-BUILD.md#router-opened-to-the-tailnet-2026-10-15),
[`…#image-generation-opened-to-the-tailnet-2026-10-16`](archive/GPU-VM-BUILD.md#image-generation-opened-to-the-tailnet-2026-10-16).
Ports 9100
(node-exporter) and 10200/10300 (Wyoming Piper and Whisper, for Home Assistant)
are open to the three k3s node IPs only, so the dev VM cannot reach the Wyoming
ports directly.

### Consumers

- **Cluster apps** — `http://192.168.50.107:8080/v1` (router) or `:8081/v1`
  (`fast`), with the cluster API key (delivered via SOPS).
- **CLI chat** — Simon Willison's `llm` (0.35, via `pipx`) on the guest itself,
  configured from `scripts/llm/extra-openai-models.yaml`.
- **Coding: Aider** (`~/.local/bin/aider`) on the dev VM, against the router
  (`openai/qwen27` by default). One request per instruction with diff edits,
  rather than an agent loop, so the prompt stays small and the prompt cache
  gets reused. Config in `scripts/llm/aider/`, installed as
  `~/.aider.conf.yml` and `~/.aider.model.settings.yml`. The model settings
  turn thinking off per request for every preset; `auto-commits` and
  analytics are off. Edits and commands execute on the dev VM; only model requests reach the
  guest. The key is read from `~/.config/aider/api.env`, sourced by hand.
  Claude Code is not used against these models: its per-turn prompt is too
  heavy for a 27B model on this card ([`archive/GPU-VM-BUILD.md`](archive/GPU-VM-BUILD.md#claude-code-wrapper-retired-2026-10-14)).
- **Agent: Hermes Agent** (v2026.9.24, `~/.local/bin/hermes`), against
  `qwen27-agent` by default (`sudo llm-mode agent` first), or `neo-coder`
  beside `fast` with `hermes -m neo-coder` (no mode switch, 65,536 context),
  or `hermes -m neo-coder-agent` after `sudo llm-mode heretic` (196,608).
  It edits with its own `patch`
  tool and keeps memory and full session history in `~/.hermes`. Runs as `dev`
  on the dev VM, where `~/.hermes` is a separate 20 GiB disk
  (`sas-vm:vm-101-disk-0` on `sas-pool`, ext4 labelled `hermes`, `nofail` in
  `/etc/fstab`), mounted at exactly that path because the venv holds absolute
  paths ([`SAS-STORAGE.md`](SAS-STORAGE.md)). **`scripts/llm/hermes/` is the
  whole setup**: `config.yaml`, `SOUL.md`, and `install.sh`, which installs the
  pinned release and copies both into `~/.hermes/` on any Linux machine on the
  LAN (re-run with `--config-only` after editing either). The config:
  - every side task (compression, session search, memory review, `/goal`'s
    judge) on whichever preset the session runs: each names the provider but
    no model, so it follows `-m` and `/model`, since a second model would
    evict the first; the judge gets a 300 s timeout instead of 60 s;
  - each preset's window: `model.context_length` (163,840) for the default,
    `providers.llama.models.<preset>.context_length` for any other. Without
    the entry Hermes takes `neo-coder` as 256,000 and never compacts before
    the server's 65,536 overflows. Each must equal `ctx-size` in `models.ini`;
  - compaction at 64k tokens (`compression.threshold_tokens`) on
    `qwen27-agent`, not the 75%-of-window floor (~123k): at ~477 tok/s
    prefill a 123k summary takes ~4 min. On `neo-coder` the window's own
    threshold (55,705) comes first;
  - non-thinking sampling sent per request in `extra_body`, overriding the
    thinking-mode defaults in `models.ini`;
  - seven toolsets (file, terminal, memory, session search, skills, todo,
    clarify); no web, browser, messaging or cron;
  - `max_turns: 40`, `verify_on_stop: auto`, and standing rules to push back
    on impossible asks, ask when a term is ambiguous, stay in scope, and never
    decrypt a secret.

  History and results: [`archive/HERMES-TRIAL.md`](archive/HERMES-TRIAL.md).

  **Another machine** needs only the key: `install.sh` stops until
  `~/.config/llama/api-key` (mode 600) holds the agents key, which the owner
  copies (`dev` has it at the same path). Off the LAN, a tailnet member with
  `--accept-routes` uses the same `192.168.50.107:8080` address unchanged; it
  shares the one loaded model with LAN clients, so a mode switch from either
  side evicts the other's. What stays per machine, and out of
  git because this repo is public: `~/.hermes/state.db` (sessions),
  `memories/MEMORY.md` and `USER.md`.

  > ⚠️ **The "ask, don't guess" rules hold only where someone can answer.**
  > With no user (`hermes chat -q`, cron), `clarify` returns "not available"
  > and Qwen proceeds on a guess regardless of `coding_instructions`; one test
  > raised `qwen27-agent` to a context that cannot load. Use those modes for
  > questions, not edits.

  > ⚠️ **Hermes runs with all of `dev`'s access** (kubeconfig, `~/.ssh`
  > including the Proxmox host key, `sops`, `age.key`), and every session,
  > tool output included, is stored in `~/.hermes/state.db` indefinitely. The
  > never-decrypt rule is an instruction to the model, not a control. A
  > secret that does land there is in `sas-pool/vm`'s snapshots for six months.

  > ⚠️ **A repo HTML comment containing `ignore`, `override`, `system`,
  > `secret` or `hidden` blocks the whole file.** Hermes' context scanner
  > replaces AGENTS.md with a `[BLOCKED]` notice and the session runs without
  > it. That is why the doc-history marker is `<!-- doc-history:allow -->`.

  **Checking it:**

  | Command | Healthy |
  |---|---|
  | `hermes doctor` | `auxiliary task routing resolves: … custom@192.168.50.107`, `Config version up to date (v46)`; only the npm warnings left |
  | `hermes chat -q "Reply with just OK"`, then on `llm`: `curl -H "Authorization: Bearer …" localhost:8080/slots?model=qwen27-agent` | `temperature` 0.7, `top_p` 0.8, `top_k` 20, `presence_penalty` 1.5, `n_ctx` 163840 |
  | `hermes -m neo-coder chat -q "Reply with just OK"`, then the same `curl` with `?model=neo-coder` | the same sampling, `n_ctx` 65536 |
  | `grep "API call" ~/.hermes/logs/agent.log` after that session | `model=neo-coder`, never `qwen27-agent` |
  | `sudo llm-mode heretic` on `llm`, then `hermes -m neo-coder-agent chat -q "Reply with just OK"` and the `curl` with `?model=neo-coder-agent` | the same sampling, `n_ctx` 196608 |
  | `grep "Context file" ~/.hermes/logs/agent.log` after a session in `~/homelab` | no `blocked` line |

### Tool calling

`scripts/llm/tools/` gives the `llm` CLI three tools (all five presets are
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
sudo ufw allow from 192.168.50.0/24 to any port 8082 proto tcp
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

Other agents drive image mode over SSH from
[`scripts/llm/IMAGE-AGENT.md`](scripts/llm/IMAGE-AGENT.md), installed as
`~/IMAGE-AGENT.md` for `dev` on the guest: rules (never print the key or a raw
job body), the async submit-and-poll flow, and troubleshooting. It reads the
third line of `/etc/llama/api-keys`.

### Music generation

`sudo llm-mode music-instrument` stops the router and `sd-server` and keeps
`fast` and whisper, so the voice assistant keeps working. Then
`music-instrument-gen` (as `dev`) writes an instrumental with **Stable Audio 3
Medium** through [audio.cpp](https://github.com/0xShug0/audio.cpp) (`v0.9.5`,
`61c7838b`, unmodified SYCL build in `/models/src/audio.cpp/build-sycl`).
`sudo llm-mode normal` gives the card back to the router.

| | |
|---|---|
| Weights (`/models/stable-audio-3-medium/`) | `stable-audio-3-medium-f16.gguf` (5.8 GB, self-contained: configs and T5Gemma tokenizer embedded), from `audio-cpp/audio.cpp-gguf` at revision `7a103b33`, the package audio.cpp's `model_specs/stable_audio.json` points to. Ungated, unlike the upstream `stabilityai/stable-audio-3-medium`. Hash in `SHA256SUMS` there (`sha256sum -c`) |
| Why F16 | The whole model is 5.8 GB, so Q8_0's saving buys nothing on this card |
| Wrapper | `music-instrument-gen "<style>" [seconds] [seed]` → `scripts/llm/music-instrument-gen`. Refuses to start while the router or `sd-server` is up. `seconds` (default 30) is the file's length; the music fades out over the last 2–4 s |
| Memory | `fast` + whisper hold ~5.9 GB; a 10 s or 30 s clip peaks at **11.4 of 31.9 GiB** with them loaded (~5.5 GB for audio.cpp) |
| Speed | A 30 s clip takes ~8–12 s (RTF ≈ 0.27–0.4, mostly fixed overhead); 17 s on the first run after boot |
| Input | An English style description; no vocals, no lyrics |
| Output | `/models/music/<YYYYmmdd-HHMMSS>.wav`, 44.1 kHz stereo, owner `dev`; the wrapper prints the path and seed |
| Licence | Stability AI Community License: free under USD 1M yearly revenue, commercial use registered with Stability AI and shown as "Powered by Stability AI". The embedded T5Gemma encoder is under the Gemma Terms of Use → `docs/model_licenses.md` in audio.cpp |

Stable Audio is not on audio.cpp's own SYCL validation list. On this card its
GPU output matches the CPU backend's (correlation 0.994) with oneDNN on or
off, so the wrapper sets no `GGML_SYCL_*` switches. Neither memory nor output
has been measured past 30 s.

**MiniMax Music 3 (songs with lyrics) is downloaded but not set up.** Its
Q8_0 weights are in `/models/minimax-music3/` (`audio-cpp/MiniMax-Music3-GGUF`
at `46fe77f8`, `SHA256SUMS` there), kept for a later audio.cpp release. On
`v0.9.5` it needs a local ggml-sycl patch, needs oneDNN off, and still
produces noise for a 30 s song on the GPU. Findings:
[`archive/GPU-VM-BUILD.md`](archive/GPU-VM-BUILD.md#minimax-music-3-tried-and-shelved-2026-11-18).

> ⚠️ **`/models/music/` is not backed up**, like `/models/images/`.

`llm_mode` reports music mode as `other`: `fast` without the router matches
neither `normal` nor `agent`.

Build and install (on the guest, with `scripts/llm/` copied to `~/llm`):

```bash
cd /models/src
git clone --branch v0.9.5 --recurse-submodules \
  https://github.com/0xShug0/audio.cpp
cd audio.cpp
source /opt/intel/oneapi/setvars.sh
cmake -S . -B build-sycl -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DAUDIOCPP_DEPLOYMENT_BUILD=ON -DENGINE_ENABLE_SYCL=ON \
  -DCMAKE_C_COMPILER=icx -DCMAKE_CXX_COMPILER=icpx
cmake --build build-sycl --target audiocpp_cli -j 8
```
```bash
sudo install -m 755 ~/llm/music-instrument-gen /usr/local/bin/
```
```bash
sudo install -d -o dev -g dev /models/music
```

**Checking it**, on the guest:

| Command | Healthy |
|---|---|
| `sudo llm-mode music-instrument` then `sudo llm-mode status` | `llama-fast` and `whisper` `active`; `llama-router` and `sd-server` `inactive` |
| `music-instrument-gen x` while the router is up | `llama-router holds the card; run: sudo llm-mode music-instrument`, exit 1 |
| a 30 s clip (see below) | `saved /models/music/….wav`; ~10 s |
| the file's samples (any WAV reader) | loudness varying second to second, and clipped samples a tiny fraction: Stable Audio often peaks at 1.0 with a few hundred clipped samples per 30 s, as its CPU-backend output does. Nearly every sample at ±1.0 is a broken GPU run |
| `cd /models/stable-audio-3-medium && sha256sum -c SHA256SUMS` | `stable-audio-3-medium-f16.gguf: OK` |
| `git -C /models/src/audio.cpp status --short` | no output (unmodified upstream) |

#### Generating an instrumental

```bash
music-instrument-gen "Warm lo-fi hip hop, 80 BPM, dusty Rhodes" 30
```

Other agents follow [`scripts/llm/MUSIC-AGENT.md`](scripts/llm/MUSIC-AGENT.md),
installed as `~/MUSIC-AGENT.md` for `dev` on the guest: rules, prompt
guidance, a `bash -s` heredoc that keeps quotes intact over SSH, a
full-scale-noise check, and troubleshooting. Install both guides with:

```bash
install -m 664 ~/llm/IMAGE-AGENT.md ~/llm/MUSIC-AGENT.md ~/
```

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

> ⚠️ **One malformed line in `llama.prom` hides every llama metric.**
> node_exporter rejects the whole textfile (`node_textfile_scrape_error 1`),
> so `llamacpp:*`, `llm_mode` and VRAM all vanish while `LlmVmDown` stays
> quiet. `llama-metrics` adds `model="…"` inside a metric's existing label set
> (MTP's `spec_decode_num_accepted_tokens_per_pos_total{position="N"}` has
> one); `LlmMetricsTextfileBroken` alerts after 5 minutes, since the chart's
> own textfile alert matches only `job="node-exporter"`.

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
