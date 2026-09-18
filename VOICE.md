# Voice assistant — ESP32-S3 satellite, Home Assistant on k3s, speech on VM 105

A Waveshare **ESP32-S3-Touch-LCD-1.85C-BOX** (360×360 round LCD, mic,
speaker box) will listen for a wake word **on the device** and hand everything
after that to the homelab. Scaffolded 2026-09-17 (PR #32, merged).

**Status: everything except the physical hardware is done.** V1 (speech
services on VM 105), V2 (Home Assistant + `voice-db` in k3s, onboarded) and V4
(the conversation agent, tuned and pipeline-tested without hardware) are all
live. V3 (firmware) has its secrets generated and compiles cleanly, but the
board hasn't arrived yet (expected 2026-09-18) — nothing is flashed or adopted
in HA. See "What's not built yet" for what's left.

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
| `llama-fast` only | HA's built-in intents still handle device commands ("prefer handling commands locally" is on) |

## Files

| Path | What |
|---|---|
| `esphome/voice-satellite.yaml` | Firmware, validated with `esphome config` 2026.9.0 — compiled, not yet flashed |
| `esphome/secrets.sops.yaml` | Wi-Fi SSID/password and the API key (generated into SOPS, never printed) |
| `scripts/esphome-run.sh` | Runs ESPHome with secrets decrypted into tmpfs for one run |
| `scripts/voice/*.service` | `whisper-server`, `wyoming-whisper`, `wyoming-piper`, `wyoming-piper-pitch` units for VM 105 |
| `scripts/voice/piper_pitch_proxy.py` | Wyoming proxy: pitch-shifts a Piper voice (ffmpeg asetrate+atempo) and advertises it as its own voice — see "Pitched voice" below |
| `scripts/voice/ha-api.sops.yaml` | HA long-lived token for `pipeline-test.py`, operator-only (not read by the cluster) |
| `scripts/voice/pipeline-test.py` | Drives the Doofus pipeline over HA's websocket API without hardware |
| `kubernetes/apps/voice/voice-db/` | CNPG Cluster `voice-db` |
| `kubernetes/apps/voice/home-assistant/` | Deployment, Service, config PVC, `configuration.yaml` |
| `mise.toml` | Adds `uv` and `pipx:esphome` |

## What's running today

### Speech services on VM 105 (V1)

Three services on `llm` (VM 105), alongside `llama-fast`/`llama-router` (see
[`GPU-VM.md`](GPU-VM.md)):

| Service | Port | What |
|---|---|---|
| `whisper-server` | `127.0.0.1:8910` (loopback) | whisper.cpp `v1.9.4`, SYCL build, **`small.en` f16** — q8_0 was found to transcribe garbage on this SYCL build |
| `wyoming-whisper` | `:10300` | Wyoming protocol bridge in front of `whisper-server`, for Home Assistant |
| `wyoming-piper` | `:10200` | Piper TTS, Wyoming protocol, CPU only |
| `wyoming-piper-pitch` | `:10201` | Proxy in front of `wyoming-piper`, advertises `en_US-norman-medium_x0.8` — see "Pitched voice" below. **Not deployed yet** (no SSH access to `llm` from the dev VM used to build it; ffmpeg not confirmed installed) |

**Measured:** f16 transcribes in 0.21 s warm (first request after a cold start
takes ~34 s for SYCL kernel compilation, so the unit sends itself a warm-up
request). With `qwen27` (cut to 65,536 context — see [`GPU-VM.md`](GPU-VM.md)),
`llama-fast` and whisper's f16 model all loaded, VRAM use is 27,221/32,656 MiB,
leaving ~5.3 GiB free at idle. A 60K-token `qwen27` request ran clean
concurrently with a transcription loop (300/300 correct).

**Firewall:** ports 10200/10300 open only to the three k3s node IPs
(`192.168.50.104–106`); `whisper-server` itself binds loopback and is not
reachable off the VM at all. 10201 needs the same rule once
`wyoming-piper-pitch` is deployed — see "Pitched voice" below.

⚠️ **`--local-files-only` doesn't stop Piper voice downloads.** Picking or
previewing a voice in HA's assistant settings downloads it into `/models/piper`
regardless, unpinned — outside the hash-pinned set. Harmless (it lands on
`/models` and then works offline), but worth knowing before assuming every
voice on disk was deliberately pinned.

Full build log: [`archive/VOICE-BUILD-V1.md`](archive/VOICE-BUILD-V1.md).

#### Pitched voice — `en_US-norman-medium_x0.8`

The owner wants a deeper Norman without slowing the speech down. Piper itself
has no pitch control (`SynthesisConfig` only exposes `speaker_id`,
`length_scale`, `noise_scale`, `noise_w_scale`) and `wyoming-piper` 2.5.2 calls
`piper.PiperVoice` in-process rather than shelling out to a binary, so there is
no external command to wrap. `scripts/voice/piper_pitch_proxy.py` is a small
standalone Wyoming server instead: it forwards each `Synthesize` to the real
`wyoming-piper` on `:10200` requesting `en_US-norman-medium`, buffers the PCM
it gets back (one utterance is always short enough to hold in memory), and
pipes it through ffmpeg's `asetrate=<rate*0.8>,aresample=<rate>,atempo=1.25`
before re-emitting it — `asetrate` alone would lower pitch and slow tempo
together, so `atempo=1/0.8` cancels the slowdown back out, changing only the
pitch. Verified locally against a synthetic tone: a 220 Hz input measured
176.07 Hz out (0.8×, expected 176.0) at the same duration (±0.5%, from
`atempo`'s block-based resampling — inaudible). It advertises itself as a
single voice, `en_US-norman-medium_x0.8`, on its own port so it shows up as a
distinct choice next to the unmodified voices; it does not touch
`wyoming-piper`'s own voice list on `:10200`.

**Not deployed yet** — this dev VM has no SSH key for `llm` (`Permission
denied (publickey)`), so an operator has to run the deploy by hand:

```bash
scp -3 scripts/voice/piper_pitch_proxy.py scripts/voice/wyoming-piper-pitch.service llm:/tmp/
ssh llm '
  sudo apt install -y ffmpeg
  sudo install -o wyoming -g wyoming -m 644 /tmp/piper_pitch_proxy.py /opt/wyoming/piper/piper_pitch_proxy.py
  sudo install -m 644 /tmp/wyoming-piper-pitch.service /etc/systemd/system/wyoming-piper-pitch.service
  sudo systemctl daemon-reload
  sudo systemctl enable --now wyoming-piper-pitch
  sudo ufw allow from 192.168.50.104 to any port 10201 proto tcp
  sudo ufw allow from 192.168.50.105 to any port 10201 proto tcp
  sudo ufw allow from 192.168.50.106 to any port 10201 proto tcp
'
```

Then in HA: Settings → Devices & services → Add integration → **Wyoming
Protocol** → host = a node IP, port `10201`. It advertises one voice,
`en_US-norman-medium_x0.8`; pick it as the TTS voice on the "Doofus" assistant
(or any other) the same way `tts.piper` was picked in V2.

### Home Assistant + `voice-db` in k3s (V2)

`kubernetes/apps/voice/` — a CNPG Cluster `voice-db` on `k3s-worker2` (the
`archive-pool` zvol; recorder, 13 tables) and a Home Assistant Deployment on
`k3s-worker1`, reached at `http://192.168.50.104:8123` (any of the three node
IPs answers). Onboarded and configured through the UI — there is no YAML for
any of the following, so a rebuilt PVC needs it redone by hand:

- Wyoming Protocol integrations `whisper-cpp` (`:10300`) and `piper`
  (`:10200`), pointed at VM 105.
- Voice assistant **"Doofus"**, set as preferred: STT `stt.whisper_cpp`, TTS
  `tts.piper`, conversation agent `conversation.fast` (V4), **prefer handling
  commands locally = on**.

Full result record: [`archive/VOICE-BUILD-V2-V4.md`](archive/VOICE-BUILD-V2-V4.md).

### Conversation agent (V4)

Home Assistant's native **llama.cpp** integration (HA 2026.9 ships this — no
HACS component needed) points at `llama-fast` (`http://192.168.50.107:8081/v1`,
model `fast`, streaming on), authenticated with the cluster API key from
`kubernetes/apps/observability/llm-vm/app/llm-api-key.sops.yaml`.

⚠️ **Home Assistant device control (Assist) is deliberately OFF for now.**
With no entities exposed yet, the 4B model calls `GetLiveContext` domain by
domain until HA's tool-iteration cap runs out and the turn fails. Re-enable
once real devices exist — tracked in [`BACKLOG.md`](BACKLOG.md).

Tested without hardware via `scripts/voice/pipeline-test.py`, which drives the
Doofus pipeline over HA's websocket API the way a satellite would. Measured:
LLM answers **1.3–1.7 s** end-to-end (STT 145–251 ms, agent 727 ms–1.0 s, TTS
116–443 ms); locally-handled intents (e.g. "what time is it") **0.17–0.29 s**.
That excludes the on-device wake-word/silence-detection time a real satellite
adds — see "What's not built yet." Prompt-tuning notes and the full timing
table: [`archive/VOICE-BUILD-V2-V4.md`](archive/VOICE-BUILD-V2-V4.md).

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

### V3 — Firmware

**V3a. Secrets — done 2026-09-17.** Four keys in `esphome/secrets.sops.yaml`:
`wifi_ssid`, `wifi_password`, and `api_encryption_key` (32 random bytes,
base64). OTA has no password; it inherits the API key. The API key was
generated **straight into** the file so it was never printed; SSID
(`NETGEAR19`, 2.4 GHz confirmed by the owner) and password were entered
directly by the owner with `read -rs`, never in chat. To redo:

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

**V3b. Validate and compile — done 2026-09-17.** Compiled clean: RAM 32.8%
(111,959 / 341,760 B), flash 13.2%. Needed `python3.12-venv` on the dev VM
(ESPHome builds an ESP-IDF 5.5.5 venv). `scripts/esphome-run.sh` originally
assumed PlatformIO's `.pioenvs/` output path; ESPHome 2026.9 builds with
native ESP-IDF instead, so the script now locates `firmware.factory.bin`
rather than hardcoding its path.

```bash
cd ~/homelab
scripts/esphome-run.sh config
```

**V3c. First flash over USB (workstation) — waiting on hardware** (board
expected 2026-09-18). The dev VM has no USB. Build the
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

**V4's one remaining item lives here too:** once the device is adopted, record
the real wake → reply-start latency (HA → Settings → Voice assistants →
Debug). The 1.3–1.7 s measured in
[`archive/VOICE-BUILD-V2-V4.md`](archive/VOICE-BUILD-V2-V4.md) is the pipeline
alone, over a websocket test — it excludes the on-device wake-word detection
and end-of-speech silence wait a real satellite adds.

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
- [x] V2 — `voice-db` + Home Assistant deployed and onboarded, Wyoming entries
      added, "Doofus" pipeline created
- [x] V3a/V3b — firmware secrets generated, config validated and compiled
- [ ] V3c/V3d/V3e — flash, adopt in HA, memory baseline (waiting on hardware,
      expected 2026-09-18)
- [ ] V0 — pin map checked against the Waveshare schematic
- [ ] V1f leftover — `chat` and `qwen27-agent` load once with `whisper-server`
      running (rare-use presets, not yet checked)
- [x] V4 — conversation agent wired to `llama-fast`, tuned, pipeline-tested
      without hardware — full log in
      [`archive/VOICE-BUILD-V2-V4.md`](archive/VOICE-BUILD-V2-V4.md)
- [ ] V4 leftover — end-to-end wake → reply latency on the real device
- [ ] V5 — display, STT fallback, metrics, custom wake word (all deferred)
- [ ] V1g — pitched voice `en_US-norman-medium_x0.8`: proxy written and
      verified locally (pitch and duration both check out), not deployed to
      `llm` yet — see "Pitched voice" under V1, needs an operator with SSH
      access to run the deploy and add the HA integration

## Related

- [`archive/VOICE-BUILD-V1.md`](archive/VOICE-BUILD-V1.md) — the V1 build log
  and its debugging record
- [`archive/VOICE-BUILD-V2-V4.md`](archive/VOICE-BUILD-V2-V4.md) — the V2 and
  V4 build log: Home Assistant onboarding, the conversation agent, and the
  no-hardware pipeline test results
- [`GPU-VM.md`](GPU-VM.md) — VM 105's GPU passthrough and the `llama.cpp`
  inference stack this shares a card with
- [`BACKLOG.md`](BACKLOG.md) — everything still open, tracked as work items
