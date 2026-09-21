# Voice assistant — ESP32-S3 satellite, Home Assistant on k3s, speech on VM 105

A Waveshare **ESP32-S3-Touch-LCD-1.85C-BOX** (360×360 round LCD, mic,
speaker box) listens for the wake word **"Hey Doofus" on the device** and
hands everything after that to the homelab. Scaffolded 2026-09-17 (PR #32,
merged).

**Status 2026-09-19: working end to end.** V1 (speech services on VM 105), V2
(Home Assistant + `voice-db` in k3s) and V4 (the conversation agent) are live.
V3: the board is flashed and adopted at `192.168.50.70`, runs the custom
"Hey Doofus" wake word, and answers aloud through the Doofus pipeline. The
audio only worked once it followed Waveshare's real wiring (V0). Open items
are in the checklist.

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
          │ "hey doofus"
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
| VM 105 | No STT, so the voice pipeline fails. Known gap — see "Hardware and firmware" |
| `llama-fast` only | HA's built-in intents still handle device commands ("prefer handling commands locally" is on) |

## Files

| Path | What |
|---|---|
| `esphome/voice-satellite.yaml` | Firmware (ESPHome 2026.9.0), running on the device at `192.168.50.70` |
| `esphome/wake_words/` | "Hey Doofus" v2 model and manifest, from `~/mww-hey-doofus` (V5) |
| `esphome/secrets.sops.yaml` | Wi-Fi SSID/password and the API key (generated into SOPS, never printed) |
| `scripts/esphome-run.sh` | Runs ESPHome with secrets decrypted into tmpfs for one run |
| `scripts/voice/*.service` | `whisper-server`, `wyoming-whisper`, `wyoming-piper` units for VM 105 |
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

**Measured:** f16 transcribes in 0.21 s warm (first request after a cold start
takes ~34 s for SYCL kernel compilation, so the unit sends itself a warm-up
request). With `qwen27` (cut to 65,536 context — see [`GPU-VM.md`](GPU-VM.md)),
`llama-fast` and whisper's f16 model all loaded, VRAM use is 27,221/32,656 MiB,
leaving ~5.3 GiB free at idle. A 60K-token `qwen27` request ran clean
concurrently with a transcription loop (300/300 correct).

**Firewall:** ports 10200/10300 open only to the three k3s node IPs
(`192.168.50.104–106`); `whisper-server` itself binds loopback and is not
reachable off the VM at all.

⚠️ **`--local-files-only` doesn't stop Piper voice downloads.** Picking or
previewing a voice in HA's assistant settings downloads it into `/models/piper`
regardless, unpinned — outside the hash-pinned set. Harmless (it lands on
`/models` and then works offline), but worth knowing before assuming every
voice on disk was deliberately pinned.

Full build log: [`archive/VOICE-BUILD-V1.md`](archive/VOICE-BUILD-V1.md).

#### Pitched voice — `en_US-norman-medium_x0.8`

The **Doofus** assistant speaks with Norman pitched down to 0.8× at normal
speed (`tts.piper`, voice `en_US-norman-medium_x0.8`; was
`en_US-norman-medium`). It is an ordinary custom voice in `/models/piper`,
served by `wyoming-piper` itself: no extra service, port or firewall rule.

Piper has no pitch control, but `wyoming-piper` takes the playback rate from
the voice's `.onnx.json` (`audio.sample_rate`, sent in `AudioStart`) and the
speaking speed from `inference.length_scale`. The voice is the unmodified
Norman model with both scaled by 0.8: playback at 17,640 Hz instead of
22,050 lowers pitch and formants together (the slowed-tape sound), and
`length_scale` 0.8 makes Piper speak 25% faster to cancel the slowdown.
`dataset` is set to `norman_deep` so the HA dropdown labels it apart from
plain Norman. To rebuild it, or make another ratio, on `llm`:

```bash
( set -e
cd /models/piper
N=en_US-norman-medium_x0.8
sudo -u wyoming cp -p en_US-norman-medium.onnx $N.onnx
sudo -u wyoming python3 -c '
import json
d = json.load(open("en_US-norman-medium.onnx.json"))
d["audio"]["sample_rate"] = round(d["audio"]["sample_rate"] * 0.8)
d["inference"]["length_scale"] = round(d["inference"]["length_scale"] * 0.8, 3)
d["dataset"] = "norman_deep"
json.dump(d, open("en_US-norman-medium_x0.8.onnx.json", "w"), indent=2)'
)
```

`wyoming-piper` rescans the directory on every Describe, so no restart. HA
caches the voice list: reload the `piper` Wyoming integration (Settings →
Devices & services → piper → Reload), then pick the voice on the assistant.

**Verified 2026-09-18, through HA** (`/api/tts_get_url` on `tts.piper`): median
F0 95 Hz for plain Norman and 77 Hz for this voice (0.81×), at similar length
(3.87 s and 4.18 s; Piper varies ~0.6 s between runs of one sentence), and
`whisper-server` transcribed it word for word. Samples before choosing:
Norman stays intelligible to ×0.7 and garbles at ×0.6; `ryan-low` holds to ×0.6.

**Superseded:** commit `9e49e7b` did the same with a Wyoming proxy on `:10201`
that ran the audio through ffmpeg `asetrate`+`atempo`. It was deployed for an
hour and removed the same day (service, script, ufw rules, HA entry, and
the `ffmpeg` apt install it needed: exactly the 172 packages of that one
transaction, purged by list, nothing older touched): the
time-stretch can sound processed, and it was a second service and port for
what one config file does. The code is in git history.

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
adds — see "Hardware and firmware." Prompt-tuning notes and the full timing
table: [`archive/VOICE-BUILD-V2-V4.md`](archive/VOICE-BUILD-V2-V4.md).

## Hardware and firmware (V0, V3, V5)

### V0 — Hardware check (workstation, no homelab changes)

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

**V3c. First flash over USB (workstation) — done 2026-09-19.** The dev VM has no USB. Build the
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

**V3d. Adopt in HA — done 2026-09-19** (`192.168.50.70`, reserved in the
router's DHCP):

1. Find the board's IP (router DHCP table) and reserve it (V0).
2. HA → Add integration → ESPHome → host = that IP, key = `api_encryption_key`.
   Decrypt it into your clipboard on the workstation instead of printing it in
   a shared terminal.
3. Assign the device to the assistant from V2.

Later updates go over the air from the dev VM:
`scripts/esphome-run.sh run --no-logs --device 192.168.50.70`. (`upload` alone has
nothing to send: the script's build tree lives only for one run.)

**V3e. Memory baseline (the point of the lean build) — done 2026-09-19.** Record the
`Heap Free`, `Heap Max Block` and `PSRAM Free` sensors in HA at three moments:
idle, while the wake word is listening, and during a reply. **Every later
component is added one at a time and compared against these.** If the device
crashes, get a backtrace with ESPHome's Troubleshooting guide
(`scripts/esphome-run.sh logs --device …` streams logs over the API; a crash
backtrace over serial needs the workstation, since the dev VM has no USB).

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

**Wake → reply-start latency on the device is comfortably acceptable** in
real use. No per-stage figure was recorded. The pipeline alone takes
1.3–1.7 s over a websocket test
([`archive/VOICE-BUILD-V2-V4.md`](archive/VOICE-BUILD-V2-V4.md)); the device
adds on-device wake detection and the end-of-speech silence wait. HA →
Settings → Voice assistants → Debug shows per-stage timings when a number
is needed.

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
- **Custom wake word** "Hey Doofus": done 2026-09-19, below.
- **Volume on the screen**: done 2026-09-20. Slide a finger up or down
  anywhere to set the media player's volume; a bar and percentage show while
  dragging and fade 1.5 s after release. Under 25 px of travel is still a tap,
  so tap/long-press are unchanged; 260 px covers the full range.
- **Touch and announcements**: done 2026-09-19. Touch (CST816T): tap to
  talk or stop, hold for 0.8 s or longer to toggle Mic Mute. An announce-only
  `media_player` (WAV, PSRAM buffers; heap about 203 KB free, down about 5 KB)
  gives the satellite `assist_satellite.announce`, and HA scripts
  `doofus_say` (speak text) and `doofus_ask` (prompt → `conversation.fast` →
  speak) use it. The shared I2S bus means each announcement stops the wake
  word and restarts it on idle; the speaker's first start retries once
  ("Parent bus is busy"), adding about 1 s.

  No audio played from announcements until the satellite was reflashed over
  USB on 2026-09-20 (that recovery is below); the USB image clears the stored
  preferences, and the working theory is a stale saved volume/mute state from
  the earlier OTA builds. `amp`, the ES8311 volume and the media player volume
  all read correct while it was silent, so the evidence went with the wipe.

  **Never flash from a stale checkout.** A flash from a local `main` that
  predated the Wi-Fi rotation (`2feb374`) put the old password on the device
  and took it off the network; recovery was `ESPHOME_KEEP_FIRMWARE=~/fw
  scripts/esphome-run.sh compile`, `scp -3` to the workstation and
  web.esphome.io. Check `git log` against `origin/main` before every flash.
- **VAD model** in `micro_wake_word`, only if false accepts show up.

#### Custom wake word — "Hey Doofus"

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

##### The hard-negative step

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

##### Wiring it in

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
      probability_cutoff: 0.93
      sliding_window_size: 5
```

Drop the stock `okay_nabu` at that point rather than running both: each model is
a second always-running inference and its own tensor arena.

`scripts/esphome-run.sh` copies `esphome/wake_words/` into its tmpfs build
directory beside the YAML, since ESPHome resolves the local manifest path
relative to it. Pushed 2026-09-19 together with the audio fix (the stock
build's mic was dead, so its baseline was moot); it wakes at 0.98 average
probability. To update:

```bash
cd ~/homelab
scripts/esphome-run.sh run --no-logs --device 192.168.50.70
```

After the upload, record the three V3e rows again and compare.

**The firmware runs `probability_cutoff: 0.93`, because in real use recall
is the limit, not false wakes.** At the training pick of 0.97, several days of
testing gave zero false wakes but often missed the correct phrase. The cutoff
was tuned on synthetic Piper voices, and a real voice across a real room
scores lower. v2's held-back numbers (clean recall, and false accepts on
4,080 hard-negative clips) put 0.93 between these rows:

| Cutoff | Recall | False accepts |
|---:|---:|---:|
| 0.90 | 99.1% | 46 |
| 0.95 | 98.8% | 26 |
| 0.97 | 98.4% | 18 |
| 0.99 | 97.5% | 5 |

Those recall figures are for clean synthetic speech and overstate real-world
recall at every cutoff. If false wakes appear, go back up to 0.95. If misses
persist, the fix is retraining with real recordings of the owner as
positives (`~/mww-hey-doofus`), not a cutoff far below 0.90, where
hard-negative false accepts climb.

## Checklist

- [x] V1 — speech services on VM 105 (whisper-server, Wyoming bridges,
      `qwen27` cut to 65,536 context) — full log in
      [`archive/VOICE-BUILD-V1.md`](archive/VOICE-BUILD-V1.md)
- [x] V2 — `voice-db` + Home Assistant deployed and onboarded, Wyoming entries
      added, "Doofus" pipeline created
- [x] V3a/V3b — firmware secrets generated, config validated and compiled
      (Wi-Fi password rotated 2026-09-19)
- [x] V3c/V3d — flashed 2026-09-19, adopted in HA at `192.168.50.70`
- [x] V3d leftover — DHCP reservation for `192.168.50.70` confirmed
- [x] V3e — memory baseline: idle 216,164 B, conversation trough 206,956 B
- [x] V0 — audio wiring corrected to Waveshare's official examples (ES7210 +
      ES8311, shared I2S bus, GPIO15 amp enable)
- [ ] V1f leftover — `chat` and `qwen27-agent` load once with `whisper-server`
      running (rare-use presets, not yet checked)
- [x] V4 — conversation agent wired to `llama-fast`, tuned, pipeline-tested
      without hardware — full log in
      [`archive/VOICE-BUILD-V2-V4.md`](archive/VOICE-BUILD-V2-V4.md)
- [x] V4 leftover — end-to-end wake → reply latency on the real device:
      acceptable in real use
- [x] V5 — "Hey Doofus" v2 on the device (cutoff 0.93)
- [x] V5 leftover — real-world false wakes: none over several days at 0.97
- [ ] V5 — wake-word recall on real voices: judge cutoff 0.93 after a few
      days of use (see *Wiring it in*)
- [ ] V5 — display, STT fallback, metrics (deferred)
- [x] V1g — pitched voice `en_US-norman-medium_x0.8`, as a custom Piper
      voice (`.onnx.json` rate + length_scale), is the Doofus assistant's
      voice (2026-09-18)

## Related

- [`archive/VOICE-BUILD-V1.md`](archive/VOICE-BUILD-V1.md) — the V1 build log
  and its debugging record
- [`archive/VOICE-BUILD-V2-V4.md`](archive/VOICE-BUILD-V2-V4.md) — the V2 and
  V4 build log: Home Assistant onboarding, the conversation agent, and the
  no-hardware pipeline test results
- [`GPU-VM.md`](GPU-VM.md) — VM 105's GPU passthrough and the `llama.cpp`
  inference stack this shares a card with
- [`BACKLOG.md`](BACKLOG.md) — everything still open, tracked as work items
