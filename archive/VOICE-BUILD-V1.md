# Voice assistant V1 build log — speech services on VM 105

> 📦 **Archived 2026-09-17 — completed build.** V1 (whisper-server, the Wyoming
> bridges, and the `qwen27` context cut to make room for them) is done and
> verified. This is the step-by-step build and debugging record; the resulting
> current state is summarized in [`../VOICE.md`](../VOICE.md). Everything else
> in the voice assistant project (V0, V2–V5) was still open when this was
> archived — see that file for the live plan.

Every block below ran on `llm` (`ssh llm`) and carried its own setup.

## V1a. Build `whisper-server` (SYCL)

Same toolchain as llama.cpp's F2 build
([`GPU-VM-BUILD.md`](GPU-VM-BUILD.md)). Pinned to `v1.9.4` (2026-09-11).

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

## V1b. Models and voice (pinned by revision and SHA-256)

> **f16, not q8_0.** `ggml-small.en-q8_0.bin` transcribes garbage on this SYCL
> build (found in V1f, 2026-09-17). The q8_0 file is still on `/models/whisper`,
> unused.

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

## V1c. Wyoming bridges (venvs)

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

## V1d. Units

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

## V1e. Firewall

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

## V1f. Checks

1. **Transcription works on the card.** Use a sample WAV from the whisper.cpp
   tree:

   ```bash
   W=/models/src/whisper.cpp/samples/jfk.wav
   time curl -s -F file=@$W http://127.0.0.1:8910/inference
   ```

   `journalctl -u whisper-server -b` should show the SYCL0 device and not a
   CPU fallback.

2. **⚠️ VRAM: `qwen27` + `fast` + whisper together.** This is the everyday
   combination (`chat` is rarely used, owner 2026-09-17). Fit chose 81,920
   context for `qwen27` beside `fast`, leaving ~1 GiB free. **It was cut to
   65,536 on 2026-09-17** (`scripts/llm/models.ini`), freeing ~540 MiB more
   (16,384 tokens × ~34 KiB, q8_0), so ~1.5 GiB is free against whisper
   `small.en`'s estimated ~0.5–0.8 GiB.

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
  ~220 MiB.
- **Test trap:** whisper-server sets `SO_REUSEPORT`, so a second test server
  on the same port *starts* and the kernel splits requests between the two.
  Leftover servers from earlier pastes mixed results. Kill test servers by
  `$!` PID, never `%1`.
- **Firewall:** `:10300` is refused from the dev VM (`.103`), as intended.
- **Long-context test passed:** a 60,354-token `qwen27` request
  (`../GPU-VM-BUILD.md` + `../GITOPS.md`) with `fast` and the f16 whisper
  loaded, and a transcription loop running. Prompt 104.4 s (578 tok/s),
  generation 6.76 tok/s at that depth, correct answer, no allocation failure
  (03:39:01–03:40:56 UTC). The transcription loop was **300/300 correct**
  across the whole window.
- **Grafana's "Memory used" and "CPU busy" are the VM's RAM and CPU, not the
  card.** node_exporter has no VRAM source; use `xpu-smi`. During the test,
  RAM peaked at 6.95 GiB and CPU at 23% (8 cores). The 100% CPU on the
  dashboard was the whisper.cpp build at 03:06–03:09.
- **f16 service installed:** `model size = 487.00 MB`, JFK correct in 0.22 s
  straight after restart. The restart took 13 s, not the ~34 s cold compile,
  probably because the kernels were still cached from test C; the warm-up
  covers the cold case either way.

**`chat` and `qwen27-agent` checked, 2026-09-22** (V1f leftover): both hold up
beside `whisper-server`.

- **`chat`** (262,144 ctx, beside `fast`): loaded to 30,437 / 32,656 MiB at
  peak (~2.2 GiB free). A 69,260-token request (`GPU-VM-BUILD.md` +
  `GITOPS.md`) answered correctly at 458.6 tok/s prompt / 26.9 tok/s
  generation, no allocation failure. The concurrent whisper loop was
  158/158 correct.
- **`qwen27-agent`** (~195,072 ctx, alone — `sudo llm-mode agent` stops
  `fast`): loaded to 31,666 / 32,656 MiB at peak (~990 MiB free, the
  tightest of the three presets since nothing else yields VRAM). The same
  69,302-token request answered correctly at 463.7 tok/s prompt / 6.5 tok/s
  generation, no allocation failure. The whisper loop was 72/72 correct.
  `sudo llm-mode normal` afterward restored `fast` and idle router state
  cleanly.

## V1g. Install the 65,536 `qwen27` preset

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

**Verified 2026-09-17:** loaded warm in 27 s, `/props` reports `n_ctx 65536`,
1 slot.
