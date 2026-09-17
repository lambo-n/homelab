# Voice assistant — ESP32-S3 satellite, Home Assistant on k3s, speech on VM 105

A Waveshare **ESP32-S3-Touch-LCD-1.85C-BOX** (360×360 round LCD, mic,
speaker box) will listen for a wake word **on the device** and hand everything
after that to the homelab. Scaffolded 2026-09-17 (PR #32).

**Status: V1 done, nothing else built yet.** The speech services on VM 105
(whisper STT, Piper TTS) are live and verified. Nothing is deployed in k3s and
nothing is flashed to hardware — nothing below "What's not built yet" has
started.

## Decisions

Settled with the owner on 2026-09-17:

| Decision | Choice | Why |
|---|---|---|
| Firmware | Stock **ESPHome**, not custom ESP-IDF | `micro_wake_word`, `voice_assistant` and OTA already exist; a custom firmware would still need the same mic/stream/speaker pieces |
| On-device scope | **Wake word + the minimum audio I/O only** | ESPHome warns audio components crash devices that carry too much else, BLE especially |
| Orchestrator | **Home Assistant** in k3s (`voice` namespace) | ESPHome's `voice_assistant` only talks to HA |
| Speech-to-text | **whisper.cpp on the B70** (VM 105), `small.en` **f16**, Wyoming bridge beside it | 0.21 s for 11 s of audio (measured); q8_0 is broken on this SYCL build; `-ng` is the CPU fallback (1.84 s) |
| Text-to-speech | **Piper on VM 105's CPU** | Fast on CPU; not worth VRAM |
| Storage | HA config on `local-path` (worker1 root), recorder in a CNPG Cluster `voice-db` on worker2 (the `archive-pool` zvol) | Worker roots are small; `archive-pool` is for databases and object storage, and the recorder is a database. Models stay on `/models` |
| LLM | **`llama-fast` :8081** (Qwen3.5-4B, thinking off) | Always loaded. The router (`--models-max 1`) could swap a model mid-request and add seconds |

## Architecture

```
 ESP32-S3 satellite                  k3s (voice ns)            VM 105 llm (.107)
 ────────────────────                ───────────────            ─────────────────
 mic ─► micro_wake_word
          │ "okay nabu"
          ▼
 voice_assistant ══ native API ════► Home Assistant ─ Wyoming ► wyoming-whisper :10300
   (audio stream, :6053;             :8123 (ServiceLB)                │ 127.0.0.1:8910
    HA dials the device)                  │                     whisper-server (B70)
                                          │ ─ Wyoming ────────► wyoming-piper  :10200 (CPU)
                                          │ ─ OpenAI API ─────► llama-fast     :8081 (B70)
 speaker ◄═ TTS PCM over the API ═════════╛
                                     voice-db (CNPG, recorder)
```

What each component does when something is down:

| Down | Result |
|---|---|
| Wi-Fi | The wake word still fires; the pipeline errors and the device returns to listening |
| Cluster (HA) | The device keeps running (`api.reboot_timeout: 0s`); nothing answers |
| VM 105 | No STT, so the voice pipeline fails. Known gap — see "What's not built yet" |
| `llama-fast` only | HA's built-in intents still handle device commands, once V4 lands |

## What's running today (V1)

Three services on `llm` (VM 105), alongside `llama-fast`/`llama-router` (see
[`GPU-VM.md`](GPU-VM.md)):

| Service | Port | What |
|---|---|---|
| `whisper-server` | `127.0.0.1:8910` (loopback) | whisper.cpp `v1.9.4`, SYCL build, **`small.en` f16** — q8_0 was found to transcribe garbage on this SYCL build |
| `wyoming-whisper` | `:10300` | Wyoming protocol bridge in front of `whisper-server`, for Home Assistant |
| `wyoming-piper` | `:10200` | Piper TTS (`en_US-lessac-medium`), Wyoming protocol, CPU only |

**Measured:** f16 transcribes in 0.21 s warm (first request after a cold start
takes ~34 s for SYCL kernel compilation, so the unit sends itself a warm-up
request). With `qwen27` (cut to 65,536 context — see [`GPU-VM.md`](GPU-VM.md)),
`llama-fast` and whisper's f16 model all loaded, VRAM use is 27,221/32,656 MiB,
leaving ~5.3 GiB free at idle. A 60K-token `qwen27` request ran clean
concurrently with a transcription loop (300/300 correct).

**Firewall:** ports 10200/10300 open only to the three k3s node IPs
(`192.168.50.104–106`); `whisper-server` itself binds loopback and is not
reachable off the VM at all.

**Files already in place:**

| Path | What |
|---|---|
| `scripts/voice/*.service` | `whisper-server`, `wyoming-whisper`, `wyoming-piper` units for VM 105 |
| `esphome/voice-satellite.yaml` | Firmware, validated with `esphome config` 2026.9.0 — not yet flashed |
| `scripts/esphome-run.sh` | Runs ESPHome with secrets decrypted into tmpfs for one run |
| `kubernetes/apps/voice/voice-db/` | CNPG Cluster `voice-db` — manifests merged, not yet exercised |
| `kubernetes/apps/voice/home-assistant/` | Deployment, Service, config PVC, `configuration.yaml` — merged, not yet onboarded |
| `mise.toml` | Adds `uv` and `pipx:esphome` |

Full build log, including the debugging (the `q8_0`-is-broken finding, the
`SO_REUSEPORT` test trap, the VRAM budget measurement): [`archive/VOICE-BUILD-V1.md`](archive/VOICE-BUILD-V1.md).

## What's not built yet

### V0 — Hardware check (workstation, no homelab changes)

1. Plug the board into the **workstation** by USB-C. The dev VM has no USB
   passthrough; the first flash happens from the workstation (V3).
2. Compare the pin map in `esphome/voice-satellite.yaml` with the schematic on
   Waveshare's `ESP32-S3-Touch-LCD-1.85C` wiki page. It came from
   `ulsmith/home-assistant-esphome-esp32-s3-touch-lcd-185c` @ `db184c07`:

   | Signal | Pin |
   |---|---|
   | Mic I2S LRCLK / BCLK / DIN | GPIO2 / GPIO15 / GPIO39 (right channel) |
   | Speaker I2S LRCLK / BCLK / DOUT | GPIO38 / GPIO48 / GPIO47 |
   | Side button | GPIO0 (BOOT) |
   | I²C (touch 0x15, PCA9554 0x20) | SDA GPIO11 / SCL GPIO10. Unused until V5 |
   | Backlight | GPIO5. Unused until V5 |

3. Give the board a **DHCP reservation** once it has joined Wi-Fi (V3). HA adds
   it by IP, because mDNS does not cross the pod network.

### V2 — Cluster: `voice-db` and Home Assistant

1. From the dev VM, confirm the merged manifests are actually reconciled and
   healthy:

   ```bash
   flux get ks voice-db home-assistant
   kubectl -n voice get cluster,pods,pvc,svc
   ```

   Expect the Cluster healthy, the HA pod Running on `k3s-worker1`, and the
   Service listing `192.168.50.104,105,106` on `:8123`.
2. Open `http://192.168.50.104:8123` from the LAN and complete onboarding.
   Store the owner account in LastPass.
3. **UI-only configuration.** These are config entries in `.storage` on the
   PVC. HA has no YAML for them, so this list is what a rebuilt PVC needs
   redone:
   - Settings → Devices & services → Add → **Wyoming Protocol**, host
     `192.168.50.107`, port `10300` (STT).
   - The same with port `10200` (TTS).
   - Settings → Voice assistants → Add assistant: STT = the whisper entry,
     TTS = Piper (`en_US-lessac-medium`), conversation agent = V4.
4. Check that the recorder uses Postgres: Settings → System → Repairs should
   report no database issue, and `kubectl -n voice logs deploy/home-assistant`
   should mention no `sqlite`.

### V3 — Firmware

**V3a. Secrets.** Four keys go in `esphome/secrets.sops.yaml`: `wifi_ssid`,
`wifi_password`, and `api_encryption_key` (32 random bytes, base64). OTA has
no password; it inherits the API key. Generate the API key **straight into**
the file so it is never printed. On the dev VM:

```bash
cd ~/homelab
sops esphome/secrets.sops.yaml
```

In the editor, add the SSID and Wi-Fi password lines, and set
`api_encryption_key` to a placeholder. Then save and run:

```bash
( set -e
cd ~/homelab
K=$(head -c 32 /dev/urandom | base64)
[ ${#K} -eq 44 ]
sops set esphome/secrets.sops.yaml \
  '["api_encryption_key"]' "\"$K\""
)
```

**V3b. Validate and compile:**

```bash
cd ~/homelab
scripts/esphome-run.sh config
```

**V3c. First flash over USB (workstation).** The dev VM has no USB. Build the
factory image into a private directory, move it with `scp -3`, and flash it
from the browser:

```bash
( set -e
cd ~/homelab
install -d -m 700 ~/fw
ESPHOME_KEEP_FIRMWARE=~/fw scripts/esphome-run.sh compile
)
```

From the workstation, run `scp -3 dev:fw/firmware.factory.bin .`, open
`https://web.esphome.io`, then Connect → Install → pick the file. **The .bin
contains the Wi-Fi password and API key.** Delete it on both machines after
flashing (`rm -rf ~/fw` on dev).

**V3d. Adopt in HA:**

1. Find the board's IP (router DHCP table) and reserve it (V0).
2. HA → Add integration → ESPHome → host = that IP, key = `api_encryption_key`.
   Decrypt it into your clipboard on the workstation instead of printing it in
   a shared terminal.
3. Assign the device to the assistant from V2.

Later updates go over the air from the dev VM:
`scripts/esphome-run.sh upload --device 192.168.50.<ip>`.

**V3e. Memory baseline (the point of the lean build).** Record the
`Heap Free`, `Heap Max Block` and `PSRAM Free` sensors in HA at three moments:
idle, while the wake word is listening, and during a reply. **Every later
component is added one at a time and compared against these.** If the device
crashes, get a backtrace with ESPHome's Troubleshooting guide
(`scripts/esphome-run.sh logs --device …` streams logs over the API; a crash
backtrace over serial needs the workstation, since the dev VM has no USB).

### V4 — Conversation agent → `llama-fast`

1. The agent needs an **OpenAI-compatible integration with a configurable base
   URL**. HA core's OpenAI integration has historically not allowed one. Check
   what HA 2026.9 ships before installing a custom integration (e.g. Extended
   OpenAI Conversation via HACS).
2. Base URL `http://192.168.50.107:8081/v1`, model `fast`, API key = the
   cluster key (SOPS `llm-api-key`, line 2 of `/etc/llama/api-keys`). Pod
   egress masquerades to the node IPs, which the LAN firewall rule on VM 105
   already admits (see [`GPU-VM.md`](GPU-VM.md) F6a).
3. Enable **"Prefer handling commands locally"** so on/off/timer commands never
   reach the LLM and keep working when VM 105 is down.
4. Write a voice-specific system prompt: no markdown, short sentences, no
   lists.
5. Record wake → reply-start latency and each stage (HA → Settings → Voice
   assistants → Debug).

### V5 — Later, each measured against V3e

- **Display.** Add `qspi_dbi` + LVGL with a simple state face
  (idle/listening/thinking/speaking/offline). The init sequence and the
  EXIO2 reset quirk are in the reference repo. This is the largest memory
  cost, so compare against V3e.
- **STT fallback when VM 105 is off.** A small `wyoming-faster-whisper` on CPU
  in k3s as a second pipeline, or accept the gap.
- **Metrics.** HA's `prometheus` integration needs a long-lived token, so it
  can only be added after onboarding. Scrape it and add per-stage pipeline
  latency to Grafana.
- **Custom wake word** (e.g. "hey sunfire"): the microWakeWord training
  pipeline is a separate project.
- **VAD model** in `micro_wake_word`, only if false accepts show up.

## Checklist

- [x] V1 — speech services on VM 105 (whisper-server, Wyoming bridges,
      `qwen27` cut to 65,536 context) — full log in
      [`archive/VOICE-BUILD-V1.md`](archive/VOICE-BUILD-V1.md)
- [ ] V0, V2, V3, V4, V5 — tracked in [`BACKLOG.md`](BACKLOG.md)

## Related

- [`archive/VOICE-BUILD-V1.md`](archive/VOICE-BUILD-V1.md) — the V1 build log
  and its debugging record
- [`GPU-VM.md`](GPU-VM.md) — VM 105's GPU passthrough and the `llama.cpp`
  inference stack this shares a card with
- [`BACKLOG.md`](BACKLOG.md) — everything from V0 onward, tracked as open work
