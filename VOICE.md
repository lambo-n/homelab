# Voice assistant — ESP32-S3 satellite, Home Assistant on k3s, speech on VM 105

A Waveshare **ESP32-S3-Touch-LCD-1.85C-BOX** (360×360 round LCD, mic,
speaker box) listens for a wake word **on the device** and hands everything
after that to the homelab. Scaffolded 2026-09-17 on branch
`feat/voice-assistant`. Nothing has been deployed or flashed yet.

## Decisions

Settled with the owner on 2026-09-17:

| Decision | Choice | Why |
|---|---|---|
| Firmware | Stock **ESPHome**, not custom ESP-IDF | `micro_wake_word`, `voice_assistant` and OTA already exist; a custom firmware would still need the same mic/stream/speaker pieces |
| On-device scope | **Wake word + the minimum audio I/O only** | ESPHome warns audio components crash devices that carry too much else, BLE especially. See V3 |
| Orchestrator | **Home Assistant** in k3s (`voice` namespace) | ESPHome's `voice_assistant` only talks to HA |
| Speech-to-text | **whisper.cpp on the B70** (VM 105), Wyoming bridge beside it | Sub-second, next to llama; `-ng` is the CPU fallback |
| Text-to-speech | **Piper on VM 105's CPU** | Fast on CPU; not worth VRAM |
| Storage | HA config on `local-path` (worker1 root), recorder in a **new CNPG Cluster** `voice-db` on worker2 (the `archive-pool` zvol) | Worker roots are small; `archive-pool` is for databases and object storage (owner), and the recorder is a database. Models stay on `/models` |
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
| VM 105 | No STT, so the voice pipeline fails. **Known gap**; see V5 |
| `llama-fast` only | HA's built-in intents still handle device commands (V4 "prefer local") |

## Files

| Path | What |
|---|---|
| `esphome/voice-satellite.yaml` | Firmware. Validated with `esphome config` 2026.9.0 |
| `esphome/secrets.sops.yaml` | **Not created yet**; V3a |
| `scripts/esphome-run.sh` | Runs ESPHome with secrets decrypted into tmpfs for one run |
| `scripts/voice/*.service` | `whisper-server`, `wyoming-whisper`, `wyoming-piper` for VM 105 |
| `kubernetes/apps/voice/voice-db/` | CNPG Cluster `voice-db` |
| `kubernetes/apps/voice/home-assistant/` | Deployment, Service, config PVC, `configuration.yaml` |
| `mise.toml` | Adds `uv` and `pipx:esphome` |

---

## V0 — Hardware check (workstation, no homelab changes)

1. Plug the board into the **workstation** by USB-C. The dev VM has no USB
   passthrough; the first flash happens from the workstation (V3c).
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

## V1 — VM 105 speech services

Every block runs on `llm` (`ssh llm`) and carries its own setup.

### V1a. Build `whisper-server` (SYCL)

Same toolchain as llama.cpp's F2 build. Pinned to `v1.9.4` (2026-09-11).

```bash
( set -e
source /opt/intel/oneapi/setvars.sh >/dev/null
cd /models/src
git clone https://github.com/ggml-org/whisper.cpp
cd whisper.cpp
git checkout v1.9.4
cmake -B build-sycl -DGGML_SYCL=ON \
  -DCMAKE_C_COMPILER=icx \
  -DCMAKE_CXX_COMPILER=icpx \
  -DGGML_SYCL_F16=ON
cmake --build build-sycl -j 8 --target whisper-server
)
```

```bash
ls -l /models/src/whisper.cpp/build-sycl/bin/whisper-server
```

### V1b. Models and voice (pinned by revision and SHA-256)

Read from the Hugging Face API on 2026-09-17.

```bash
( set -e
sudo install -d -o llama -g llama /models/whisper
R=https://huggingface.co/ggerganov/whisper.cpp
U=$R/resolve/5359861c739e955e79d9a303bcbc70fb988958b1
F=ggml-small.en-q8_0.bin
sudo -u llama curl -fL -o /models/whisper/$F $U/$F
cd /models/whisper
H=67a179f608ea6114bd3fdb9060e762b588a3fb3bd00c4387971be4d177958067
echo "$H  $F" | sha256sum -c
)
```

```bash
( set -e
id wyoming >/dev/null 2>&1 || sudo useradd --system \
  --home-dir /opt/wyoming --shell /usr/sbin/nologin wyoming
sudo install -d -o wyoming -g wyoming /opt/wyoming /models/piper
R=https://huggingface.co/rhasspy/piper-voices
U=$R/resolve/1162a9173d0ce503555aed757976b7a9912eae4c
P=en/en_US/lessac/medium/en_US-lessac-medium
cd /models/piper
sudo -u wyoming curl -fLO $U/$P.onnx
sudo -u wyoming curl -fLO $U/$P.onnx.json
H=5efe09e69902187827af646e1a6e9d269dee769f9877d17b16b1b46eeaaf019f
echo "$H  en_US-lessac-medium.onnx" | sha256sum -c
)
```

### V1c. Wyoming bridges (venvs)

`python3-venv` is needed if it isn't installed yet.

```bash
( set -e
sudo apt-get install -y python3-venv
cd /opt/wyoming
sudo -u wyoming python3 -m venv piper/.venv
sudo -u wyoming piper/.venv/bin/pip install wyoming-piper==2.5.2
G=https://github.com/ser/wyoming-whisper-api-client
sudo -u wyoming git clone $G whisper-api
cd whisper-api
sudo -u wyoming git checkout 6fe7f273d76283403ce44ed6b4d1ad65633d1f04
sudo -u wyoming python3 script/setup
)
```

### V1d. Units

Copy the unit files from the **workstation** (type `bash` first; fish breaks
the variables):

```bash
eval "$(ssh-agent -s)"; ssh-add
S=dev:homelab/scripts/voice
scp -3 $S/whisper-server.service llm:/tmp/
scp -3 $S/wyoming-whisper.service llm:/tmp/
scp -3 $S/wyoming-piper.service llm:/tmp/
```

Then on `llm`:

```bash
( set -e
cd /tmp
sudo install -m 644 whisper-server.service \
  wyoming-whisper.service wyoming-piper.service \
  /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now whisper-server
sudo systemctl enable --now wyoming-whisper wyoming-piper
)
```

```bash
systemctl --no-pager status whisper-server wyoming-whisper wyoming-piper | grep -E "Active|error|fail"
```

### V1e. Firewall

Wyoming has no authentication, so allow access from the three k3s nodes only
(the same shape as the `:9100` rule). `whisper-server` binds loopback and needs
no rule.

```bash
( set -e
for n in 104 105 106; do
  sudo ufw allow from 192.168.50.$n \
    to any port 10200,10300 proto tcp
done
sudo ufw status numbered | grep -E "10200|10300"
)
```

### V1f. Checks

1. **Transcription works on the card.** Use a sample WAV from the whisper.cpp
   tree:

   ```bash
   W=/models/src/whisper.cpp/samples/jfk.wav
   time curl -s -F file=@$W http://127.0.0.1:8910/inference
   ```

   Record the time here. `journalctl -u whisper-server -b` should show the
   SYCL0 device and not a CPU fallback.

2. **⚠️ VRAM: `qwen27` + `fast` + whisper together.** This is the everyday
   combination (`chat` is rarely used, owner 2026-09-17). Fit chose 81,920
   context for `qwen27` beside `fast`, leaving ~1 GiB free. **It was cut to
   65,536 on 2026-09-17** (`scripts/llm/models.ini`), freeing ~540 MiB more
   (16,384 tokens × ~34 KiB, q8_0), so ~1.5 GiB is free against whisper
   `small.en` q8_0's estimated ~0.5–0.8 GiB. These are estimates. Measure:
   1. Install the new `models.ini` and `claude-local` (V1g).
   2. Start `whisper-server` **before** loading `qwen27`. Every preset runs
      `--fit off`, so it is the model loaded last that fails.
   3. Load `qwen27` through the router (GPU-VM.md F5) and read used/free
      memory with `xpu-smi stats -d 0`.
   4. Send one ~60K-token request to `qwen27` while transcribing `jfk.wav` in
      a loop. A fit at idle can still fail on runtime allocations at long
      context.
   5. If it still fails: `ggml-base.en`, then `-ng` (CPU).
   - `chat` (262K beside `fast`) and `qwen27-agent` (195K, card to itself)
     were also fit to the margin. Load each once; if either fails, the
     rare-use answer is to `systemctl stop whisper-server` first (for
     `qwen27-agent`, inside `llm-mode agent`).

### V1g. Install the 65,536 `qwen27` preset

The router reads `/etc/llama/models.ini` only at start. From the
**workstation** (type `bash` first):

```bash
eval "$(ssh-agent -s)"; ssh-add
scp -3 dev:homelab/scripts/llm/models.ini llm:/tmp/
```

Then on `llm`. `/etc/llama` is `750 root:llama`, so use full paths: a `cd`
as `dev` fails (hit 2026-09-17). Copying onto the existing file keeps its
owner and mode.

```bash
( set -e
D=/etc/llama
sudo cp -p $D/models.ini $D/models.ini.bak-81920
sudo cp /tmp/models.ini $D/models.ini
sudo grep -A6 '^\[qwen27\]' $D/models.ini | grep ctx-size
sudo systemctl restart llama-router
)
```

Expect `ctx-size = 65536`. The restart drops whatever preset the router has
loaded, so don't run it in the middle of a `claude-local` session.
`claude-local` on the dev VM is a copy in `~/.local/bin`, and it was already
updated on 2026-09-17, so Claude Code's context cap matches the new window.

## V2 — Cluster: `voice-db` and Home Assistant

1. Merge the `feat/voice-assistant` PR. Flux applies `voice-db`, then
   `home-assistant` (`dependsOn`).
2. From the dev VM:

   ```bash
   flux get ks voice-db home-assistant
   kubectl -n voice get cluster,pods,pvc,svc
   ```

   Expect the Cluster healthy, the HA pod Running on `k3s-worker1`, and the
   Service listing `192.168.50.104,105,106` on `:8123`.
3. Open `http://192.168.50.104:8123` from the LAN and complete onboarding.
   Store the owner account in LastPass.
4. **UI-only configuration.** These are config entries in `.storage` on the
   PVC. HA has no YAML for them, so this list is what a rebuilt PVC needs
   redone:
   - Settings → Devices & services → Add → **Wyoming Protocol**, host
     `192.168.50.107`, port `10300` (STT).
   - The same with port `10200` (TTS).
   - Settings → Voice assistants → Add assistant: STT = the whisper entry,
     TTS = Piper (`en_US-lessac-medium`), conversation agent = V4.
5. Check that the recorder uses Postgres: Settings → System → Repairs should
   report no database issue, and `kubectl -n voice logs deploy/home-assistant`
   should mention no `sqlite`.

## V3 — Firmware

### V3a. Secrets

Four keys go in `esphome/secrets.sops.yaml`: `wifi_ssid`, `wifi_password`,
and `api_encryption_key` (32 random bytes, base64). OTA has no password; it
inherits the API key. Generate the API key **straight into** the file so it is
never printed. On the dev VM:

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

### V3b. Validate and compile

```bash
cd ~/homelab
scripts/esphome-run.sh config
```

### V3c. First flash over USB (workstation)

The dev VM has no USB. Build the factory image into a private directory, move
it with `scp -3`, and flash it from the browser:

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

### V3d. Adopt in HA

1. Find the board's IP (router DHCP table) and reserve it (V0).
2. HA → Add integration → ESPHome → host = that IP, key = `api_encryption_key`.
   Decrypt it into your clipboard on the workstation instead of printing it in
   a shared terminal.
3. Assign the device to the assistant from V2.

Later updates go over the air from the dev VM:
`scripts/esphome-run.sh upload --device 192.168.50.<ip>`.

### V3e. Memory baseline (the point of the lean build)

Record the `Heap Free`, `Heap Max Block` and `PSRAM Free` sensors in HA at
three moments: idle, while the wake word is listening, and during a reply.
**Every later component is added one at a time and compared against these.**
If the device crashes, get a backtrace with ESPHome's Troubleshooting guide
(`scripts/esphome-run.sh logs --device …` streams logs over the API; a crash backtrace over serial needs the workstation, since the dev VM has no USB).

| State | Heap Free | Max Block | PSRAM Free |
|---|---:|---:|---:|
| idle | | | |
| listening | | | |
| speaking | | | |

## V4 — Conversation agent → `llama-fast`

1. The agent needs an **OpenAI-compatible integration with a configurable base
   URL**. HA core's OpenAI integration has historically not allowed one. Check
   what HA 2026.9 ships before installing a custom integration (e.g. Extended
   OpenAI Conversation via HACS).
2. Base URL `http://192.168.50.107:8081/v1`, model `fast`, API key = the
   cluster key (SOPS `llm-api-key`, line 2 of `/etc/llama/api-keys`). Pod egress
   masquerades to the node IPs, which the F6a LAN rule already admits.
3. Enable **"Prefer handling commands locally"** so on/off/timer commands never
   reach the LLM and keep working when VM 105 is down.
4. Write a voice-specific system prompt: no markdown, short sentences, no
   lists.
5. Record wake → reply-start latency and each stage (HA → Settings → Voice
   assistants → Debug).

## V5 — Later, each measured against V3e

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

- [ ] V0 pin map checked against the Waveshare schematic
- [ ] V1a whisper-server built @ v1.9.4
- [ ] V1b whisper model and Piper voice downloaded, hashes OK
- [ ] V1c venvs installed
- [ ] V1d units enabled
- [ ] V1e ufw rules for 10200/10300 from .104–.106
- [x] V1g `qwen27` at 65,536 installed on `llm` (2026-09-17: loaded warm in 27 s, `/props` n_ctx 65536, 1 slot); `claude-local` updated
- [ ] V1f transcription time recorded; **`qwen27` + `fast` + whisper measured under a long request**; `chat`/`qwen27-agent` checked
- [ ] V2 PR merged; voice-db healthy; HA onboarded; Wyoming entries added; pipeline created
- [ ] V3a secrets.sops.yaml created
- [ ] V3c first USB flash; firmware .bin deleted
- [ ] V3d device adopted, IP reserved
- [ ] V3e memory baseline recorded
- [ ] V4 conversation agent on :8081; latency recorded
