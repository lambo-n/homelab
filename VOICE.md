# Voice assistant — ESP32-S3 satellite, Home Assistant on k3s, speech on VM 105

A Waveshare **ESP32-S3-Touch-LCD-1.85C-BOX** (360×360 round LCD, mic,
speaker box) listens for a wake word **on the device** and hands everything
after that to the homelab. Scaffolded 2026-09-17 on branch
`feat/voice-assistant` (PR #32, merged). **Status 2026-09-17:** V1 speech
services live on `llm`; V2 Home Assistant + `voice-db` deployed and the
"Doofus" assistant created; V3 firmware compiled (board arrives 2026-09-18,
not flashed); V4 LLM agent wired to `llama-fast`. **Status 2026-09-19:**
board flashed and adopted at `192.168.50.70`; "Hey Doofus" wakes it and the
Doofus pipeline answers aloud. Audio needed Waveshare's real wiring (V0).

## Decisions

Settled with the owner on 2026-09-17:

| Decision | Choice | Why |
|---|---|---|
| Firmware | Stock **ESPHome**, not custom ESP-IDF | `micro_wake_word`, `voice_assistant` and OTA already exist; a custom firmware would still need the same mic/stream/speaker pieces |
| On-device scope | **Wake word + the minimum audio I/O only** | ESPHome warns audio components crash devices that carry too much else, BLE especially. See V3 |
| Orchestrator | **Home Assistant** in k3s (`voice` namespace) | ESPHome's `voice_assistant` only talks to HA |
| Speech-to-text | **whisper.cpp on the B70** (VM 105), `small.en` **f16**, Wyoming bridge beside it | 0.21 s for 11 s of audio (measured); q8_0 is broken on this SYCL build; `-ng` is the CPU fallback (1.84 s) |
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
| `esphome/secrets.sops.yaml` | Wi-Fi SSID/password and the API key (generated into SOPS, never printed) |
| `scripts/esphome-run.sh` | Runs ESPHome with secrets decrypted into tmpfs for one run |
| `scripts/voice/*.service` | `whisper-server`, `wyoming-whisper`, `wyoming-piper` for VM 105 |
| `kubernetes/apps/voice/voice-db/` | CNPG Cluster `voice-db` |
| `kubernetes/apps/voice/home-assistant/` | Deployment, Service, config PVC, `configuration.yaml` |
| `mise.toml` | Adds `uv` and `pipx:esphome` |

---

## V0 — Hardware check (workstation, no homelab changes)

1. Plug the board into the **workstation** by USB-C. The dev VM has no USB
   passthrough; the first flash happens from the workstation (V3c).
2. Pin map. **Take audio pins from Waveshare's own code**
   (`waveshareteam/ESP32-S3-Touch-LCD-1.85C`, Arduino examples
   `03_audio_out_no_tf` and `08_esp_sr`), not from the community config
   `ulsmith/home-assistant-esphome-esp32-s3-touch-lcd-185c` @ `db184c07` the
   pins first came from. That config drove GPIO2 and GPIO15 as mic clocks and
   skipped both audio chips; on this board the mic then reads all-zero samples
   (`-inf dB`) on either channel. A WebFetch summary of the wiki also got this
   wrong (it named a PCM5101 and direct mic pins), so read the example source.

   | Signal | Pin |
   |---|---|
   | I2S BCLK / LRCK / MCLK (one bus, shared) | GPIO48 / GPIO38 / GPIO2 |
   | Mic data in, from the **ES7210** ADC (I²C 0x40, two analog mics) | GPIO39 |
   | Speaker data out, to the **ES8311** codec (I²C 0x18) | GPIO47 |
   | Speaker amplifier enable (drive HIGH) | GPIO15 |
   | I²C | SDA GPIO11 / SCL GPIO10. Scan found 0x18, 0x20 (PCA9554), 0x40, 0x51 (RTC) |
   | Side button | GPIO0 (BOOT). Top right; RESET is bottom right |
   | Slide switch | Battery power. Not a mic mute; no effect on USB power |
   | Backlight | GPIO5. Unused until V5 |

   One shared bus means mic and speaker take turns (ESPHome locks it). Any
   extra mic consumer, like a `sound_level` sensor, must be `passive: true`,
   or it holds the bus and the speaker can never play.

3. Give the board a **DHCP reservation** once it has joined Wi-Fi (V3). HA adds
   it by IP, because mDNS does not cross the pod network.

## V1 — VM 105 speech services

Every block runs on `llm` (`ssh llm`) and carries its own setup.

### V1a. Build `whisper-server` (SYCL)

Same toolchain as llama.cpp's F2 build. Pinned to `v1.9.4` (2026-09-11).

`setvars.sh` is sourced **before** `set -e`: its internal probes may return
non-zero, and under `set -e` that would abort the block silently.

```bash
( source /opt/intel/oneapi/setvars.sh >/dev/null
set -e
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

> **f16, not q8_0.** `ggml-small.en-q8_0.bin` transcribes garbage on this SYCL
> build (V1f, 2026-09-17). The q8_0 file is still on `/models/whisper`, unused.

Read from the Hugging Face API on 2026-09-17.

```bash
( set -e
sudo install -d -o llama -g llama /models/whisper
R=https://huggingface.co/ggerganov/whisper.cpp
U=$R/resolve/5359861c739e955e79d9a303bcbc70fb988958b1
F=ggml-small.en.bin
sudo -u llama curl -fL -o /models/whisper/$F $U/$F
cd /models/whisper
H=c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d
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
for u in whisper-server wyoming-whisper wyoming-piper; do
  echo "$u: $(systemctl is-active $u)"
done
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
   `small.en`'s estimated ~0.5–0.8 GiB. These are estimates. Measure:
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

**Results, 2026-09-17:**
- **q8_0 on SYCL is broken.** `jfk.wav` came back as single wrong words
  (`chapel`, `matching`, `photographs`) in ~0.2 s, with flash attention on
  and with `-nfa`. The same file on CPU (`-ng -t 8`) was correct in 1.84 s.
- **f16 on SYCL is correct**, 4/4 runs at **0.21 s** warm. The first request
  after a start takes **~34 s** (SYCL kernel compilation), so the unit now
  sends a warm-up request in `ExecStartPost`.
- **VRAM:** `xpu-smi` reports **27,221 / 32,656 MiB used** with `qwen27`
  (65,536), `fast` and the q8_0 whisper all loaded, so ~5.3 GiB is free at
  idle. That is far more than fit's 1024 MiB margin implied. f16 adds
  ~220 MiB. The long-request test (step 4) still stands.
- **Test trap:** whisper-server sets `SO_REUSEPORT`, so a second test server
  on the same port *starts* and the kernel splits requests between the two.
  Leftover servers from earlier pastes mixed results. Kill test servers by
  `$!` PID, never `%1`.
- **Firewall:** `:10300` is refused from the dev VM (`.103`), as intended.
- **Long-context test passed:** a 60,354-token `qwen27` request (GPU-VM.md +
  GITOPS.md) with `fast` and the f16 whisper loaded, and a transcription loop
  running. Prompt 104.4 s (578 tok/s), generation 6.76 tok/s at that depth,
  correct answer, no allocation failure (03:39:01–03:40:56 UTC). The
  transcription loop was **300/300 correct** across the whole window.
- **Grafana's "Memory used" and "CPU busy" are the VM's RAM and CPU, not the
  card.** node_exporter has no VRAM source; use `xpu-smi`. During the test, RAM
  peaked at 6.95 GiB and CPU at 23% (8 cores). The 100% CPU on the dashboard was
  the whisper.cpp build at 03:06–03:09.
- **f16 service installed:** `model size = 487.00 MB`, JFK correct in 0.22 s
  straight after restart. The restart took 13 s, not the ~34 s cold compile,
  probably because the kernels were still cached from test C; the warm-up
  covers the cold case either way.

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

**Results, 2026-09-17:**
- PR #32 merged (`8f4fe24`). First CI run failed: `render-charts.py` parsed
  HA's `configuration.yaml` and rejected `!env_var`; fixed to ignore unknown
  tags. `voice-db` healthy on worker2; HA on worker1; recorder created 13
  tables in Postgres.
- Wyoming entries `whisper-cpp` (:10300) and `piper` (:10200). "Piper" in the
  integration search is only an alias for Wyoming Protocol; its port must be
  typed (a second attempt re-used 10300).
- Assistant **"Doofus"**: STT `stt.whisper_cpp`, TTS `tts.piper` voice
  `en_US-norman-medium`, set as preferred.
- Picking or previewing voices in HA downloads them into `/models/piper`
  despite `--local-files-only` (see the unit comment).

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

**Results, 2026-09-19 (hardware):**
- V3c: the factory image was rebuilt on dev from `5fea582` (stock
  `okay_nabu`) after the Wi-Fi password changed (`2feb374`); flashed from
  web.esphome.io; the `.bin` deleted on dev.
- V3d: joined Wi-Fi at `192.168.50.70` (−31 to −39 dBm), adopted as
  "Voice Satellite" (entities `*.doofus1_*`), assistant **Doofus**. The
  **Wake word** selects in HA read `unavailable`: HA 2026.9.3 gets an empty
  list from the device even with the model loaded (confirmed at DEBUG). It
  is cosmetic; detection runs on the device regardless.
- Stock build: wake word and push-to-talk both dead. HA pipeline runs showed
  `stt-start` then `run-end` with no VAD events: the mic was delivering
  zeros. Fixed by the V0 wiring (`708f93b`); the stock baseline was then
  moot and "Hey Doofus" went straight on.
- Hey Doofus v2 on the device: detected at 0.98 average probability, full
  pipeline, spoken reply. The speaker defaults to full scale, far too loud:
  a **Speaker Volume** number (restored, applied at boot) sits at 65–70 %.

Baseline, Hey Doofus + ES7210/ES8311 build (idle = wake word armed; the
"speaking" trough is `Heap Min Free`, the lowest free heap since boot):

| State | Heap Free | Max Block | PSRAM Free |
|---|---:|---:|---:|
| idle, wake word armed (07:40 UTC) | 216,164 | 200,704 | 7,330,348 |
| lowest since boot, through one full conversation (07:40:40 UTC) | 206,956 | | |

For comparison, the stock build with the broken audio wiring idled at
216,368 / 204,800 / 7,346,812.

**Results, 2026-09-17 (pre-hardware):**
- V3a: `secrets.sops.yaml` created with the API key generated straight into
  SOPS; SSID `NETGEAR19` (2.4 GHz confirmed by owner); password entered by
  the owner in a terminal with `read -rs`, never in chat.
- V3b: needs `python3.12-venv` on the dev VM (ESPHome builds an ESP-IDF
  5.5.5 venv). Compiled: RAM 32.8 % (111,959 / 341,760 B), flash 13.2 %.
- `esphome-run.sh` assumed PlatformIO's `.pioenvs/`; ESPHome 2026.9 builds
  with native ESP-IDF, so it now locates `firmware.factory.bin`.
- The factory image is on the owner's workstation for V3c; the dev VM copy
  was deleted.

## V4 — Conversation agent → `llama-fast`

✅ **Done 2026-09-17.**

- **Integration:** HA 2026.9 ships a native **llama.cpp** integration (base
  URL + API key + model), so no HACS component. Entry
  `http://192.168.50.107:8081/v1`, streaming on, key = the cluster key from
  `kubernetes/apps/observability/llm-vm/app/llm-api-key.sops.yaml` (the owner
  decrypted it in their own terminal). Conversation agent `conversation.fast`,
  model `fast`.
- **Checked first:** `llama-fast` returns proper `tool_calls` for a
  `HassTurnOn` definition; `n_ctx` 8192 across 4 slots; the HA pod reaches
  `:8081` (401 without a key).
- **Doofus pipeline:** agent `conversation.fast`, **prefer handling commands
  locally = on**, preferred assistant.
- **Control Home Assistant (Assist) is OFF for now.** With no exposed
  entities the 4B model called `GetLiveContext` domain by domain until HA's
  `MAX_TOOL_ITERATIONS = 10` (`llama_cpp/entity.py`) ran out, producing
  "Unable to get response". Re-enable once real devices are exposed.
- **Prompt lessons** (tested directly against `llama-fast`, 14 prompts each):
  - Concrete few-shot examples leak: the prompt with a cat example answered
    "the wifi is slow" with "move the damn cat". The example-free prompt leaked
    0/14. Describe style; don't give example dialogues.
  - Without an explicit rule it claims actions it cannot do ("turning off the
    lamp") — the prompt now says only report actions a tool performed.
  - It needs a spoken-output rule (no markdown or lists; 1–3 sentences) or it
    produces ~250-word bulleted answers.
  - Sound effects only when asked, lowercase (Piper may spell out all-caps).
  - The 4B model gets simple facts wrong (cups → ounces answered 16 and 12).
  - Saved prompt: 1,806 characters, in HA only (`.storage`, not git).

## Pipeline test (no hardware)

`scripts/voice/pipeline-test.py` sends WAV files into the **Doofus** pipeline over
HA's websocket API at the STT stage, the way a satellite does, follows it through
the agent and TTS, downloads the reply audio and prints per-stage timings. Token:
`scripts/voice/ha-api.sops.yaml` (HA long-lived token `pipeline-test`, entered by
the owner with `read -rs`). Needs `websockets` + `aiohttp` in a throwaway venv.

**Results, 2026-09-17** (questions spoken by Piper lessac, 0.8–2.7 s; two runs):

| Question | Path | Heard | Intent | Total |
|---|---|---|---|---|
| "What is the capital of Australia?" | LLM | exact | 727–885 ms, first token ~350 ms | **1.30–1.34 s** |
| "The wifi is so slow today, this sucks." | LLM | exact | 851–1,038 ms | **1.39–1.74 s** |
| "What time is it?" | **local** (`processed_locally: true`) | exact | 2–11 ms | **0.17–0.29 s** |

- STT 145–251 ms, including streaming the whole clip in at once. On the device
  audio arrives in real time and HA waits for end-of-speech silence, so real
  wake → reply adds the length of the question plus that tail.
- TTS renders on fetch: 116–443 ms for an mp3 of the reply.
- Persona: once of two runs, "capital of Australia" got a refusal ("look it up
  yourself") instead of the answer. If that keeps happening, add "always answer
  simple questions, even while complaining" to the instructions.

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
- **Custom wake word** "Hey Doofus": a separate training project, below.
- **VAD model** in `micro_wake_word`, only if false accepts show up.

### Custom wake word — "Hey Doofus"

The phrase is fixed: **"Hey Doofus"**, matching the assistant name in HA. Three
syllables, which is the minimum that trains cleanly, and a real dictionary word,
so eSpeak inside the Piper sample generator pronounces it without a lexicon
entry or IPA override. A coined name would have needed one, and a wrong
phonemization poisons every positive sample generated from it.

Train it **after V3e**. A custom model changes both heap and false-accept
behaviour, and without the stock-model baseline there is no way to tell which
of the two regressed.

The upstream pipeline has two homes: the original `kahrendt/microWakeWord` and
the Open Home Foundation fork `OHF-Voice/micro-wake-word`, which is the one
tracking ESPHome releases. `basic_training_notebook.ipynb` is the starting
point. The work lives in `~/mww-hey-doofus`, with data on `llm` under
`/models/mww`.

Training runs on `llm`'s **CPU**, not the B70, and not Colab. Measured
2026-09-18: the model is 23,489 parameters and a full 10,000-step run takes
about 12.5 minutes on the 8 cores. The card cannot help regardless of what is
loaded on it: Intel's TensorFlow plugin does not support Battlemage, and pins a
TensorFlow, Python and oneAPI that conflict with this VM's stack. The
project README has the details.

Outline, in order:

1. Generate positives with the Piper **sample generator** (a different repo from
   the `wyoming-piper` TTS in V1). Tens of thousands of clips, many speakers,
   varied speed and pitch.
2. Fetch the precomputed negative and ambient spectrogram features from the
   `microwakeword` collection on Hugging Face. Tens of GB — stage them on a data
   disk, not a VM root.
3. **Hard negatives (below).**
4. Augment: room impulse responses and background mixing. SpecAugment stays
   **off**: frequency masking can blank the band carrying the `/f/`, the one
   sound separating "hey doofus" from "hey, do us".
5. Train the streaming MixConv model — 40 spectrogram features every 10 ms —
   then quantize to int8 for TFLite Micro. Record the tensor arena size.
6. Evaluate, tune the cutoff, write the manifest, OTA, re-measure heap against
   V3e.

#### The hard-negative step

"Hey Doofus" collides with ordinary speech: *"hey, do us a favour"* differs from
it by a single consonant, the `/f/`. Ambient noise datasets will not catch this,
because the collision **is** speech. The generic negative set is not enough on
its own.

- Synthesize a few thousand near-miss clips with the same Piper generator and
  fold them into the negatives: "do us a favour", "hey dude", "hey, does",
  "goofus", "who's this", "hey, do you".
- Raise `penalty_weight` and `negative_class_weight` on that subset so a hard
  negative costs more than a generic background clip.
- Hold back ~20% of them as a **separate** eval set. Report false accepts per
  hour on ambient audio and on the hard-negative set as two numbers: a model can
  look clean on one and fail the other.
- Tune `probability_cutoff` against the hard negatives first, then confirm
  recall at normal speaking distance across the room. Expect to land at 0.97
  or above; three syllables with a common collision does not tolerate a loose
  cutoff.

Second-order and not a training problem: "doofus" is a real insult, so anyone
saying it to a person in the room wakes the satellite.

**First model, 2026-09-18.** 62 KB quantized streaming model after 10,000 steps
(21 min on `llm`'s CPU). On 4,080 held-back hard negatives it false-accepts 2
at cutoff 0.97 and 6 at 0.90, and every "do us" variant scores about zero: the
collision is handled. The gap is recall in noise. Clean recall is 93% at 0.90,
but upstream's augmented test misses 27.5% at 0.79. Numbers and method are in
the `~/mww-hey-doofus` README.

**v2, 2026-09-18: in the firmware.** A second training phase at a tenth of the
learning rate (v1's validation never settled) cut upstream's noisy-set miss
rate at zero ambient false accepts from 27.5% to 17.5%. Clean held-back recall
at 0.97 went from 87.5% to 98.4%, for 18/4,080 hard-negative false accepts
("hey do us" 1/140). The model is `esphome/wake_words/hey_doofus.tflite`
(sha256 `7fbff053…90edb89`) and replaces `okay_nabu`. The owner chose
real-world testing before any further training.

Tensor arena: 28,000 B. TFLite Micro on `llm` (`/models/mww/.venv-tflm`,
tflite-micro `0.dev20260203175027`; the newest builds fail to import on Python
3.12) found a minimum of 25,599 B for this model and 24,499 B for
`okay_nabu`. `okay_nabu`'s manifest ships 26,080, a 6.5% margin over the host
figure, and the same margin gives about 27,250. Rounded up because a short
arena fails at boot and a spare KB costs almost nothing. Compiled with ESPHome
2026.9: static RAM and flash unchanged at 32.8% / 13.2%.

**Order on the device:** flash the stock image already on the workstation
first (V3c), record V3e, then OTA this build. The V3e numbers are what make
the swap's heap cost measurable, and they take minutes.

#### Wiring it in

`wake_word` in the manifest reads `Hey Doofus`. That string is what HA shows in
the pipeline UI and what the `on_wake_word_detected` lambda in V3 passes to
`voice_assistant.start`.

```yaml
micro_wake_word:
  id: mww
  microphone: mic
  task_stack_in_psram: true
  models:
    - model: hey_doofus.json
      id: hey_doofus
      probability_cutoff: 0.97
      sliding_window_size: 5
```

Drop the stock `okay_nabu` at that point rather than running both: each model is
a second always-running inference and its own tensor arena.

`scripts/esphome-run.sh` copies `esphome/wake_words/` into its tmpfs build
directory beside the YAML, since ESPHome resolves the local manifest path
relative to it. Then, after V3e:

```bash
cd ~/homelab
scripts/esphome-run.sh upload --device 192.168.50.<ip>
```

After the upload, record the three V3e rows again and compare. Retune with
`probability_cutoff` in the YAML: 0.99 if false wakes annoy (97.5% clean
recall, 5/4,080 hard-negative false accepts).

## Checklist

- [x] V0 pin map: audio corrected to Waveshare's official examples (2026-09-19)
- [x] V1a whisper-server built @ v1.9.4
- [x] V1b whisper model (f16; q8_0 broken on SYCL) and Piper voice downloaded, hashes OK
- [x] V1c venvs installed
- [x] V1d units enabled
- [x] V1e ufw rules for 10200/10300 from .104–.106
- [x] V1g `qwen27` at 65,536 installed on `llm` (2026-09-17: loaded warm in 27 s, `/props` n_ctx 65536, 1 slot); `claude-local` updated
- [x] V1f transcription time recorded; **`qwen27` + `fast` + whisper measured under a long request**
- [ ] V1f `chat` and `qwen27-agent` load once with whisper-server running (rare-use presets; not yet checked)
- [x] V2 PR merged; voice-db healthy; HA onboarded; Wyoming entries added; pipeline created
- [x] V3a secrets.sops.yaml created
- [x] V3c first USB flash; firmware .bin deleted on dev (workstation copy: owner)
- [x] V3d device adopted at 192.168.50.70
- [ ] V3d DHCP reservation for 192.168.50.70 confirmed
- [x] V3e memory baseline: idle 216,164 B; conversation trough 206,956 B (~9 KB)
- [x] V5 "Hey Doofus" v2 wired in (manifest, arena 28,000 B, compiled)
- [x] V5 "Hey Doofus" OTA (with the audio fix, 2026-09-19); wakes at 0.98
- [ ] V5 real-world false-wake notes (check HA pipeline debug runs for empty or stray transcripts)
- [x] V4 conversation agent on :8081 (device control off until devices exist)
- [ ] V4 end-to-end latency (wake → reply start) recorded on the real device
