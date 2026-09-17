# Voice assistant V2 + V4 build log — Home Assistant, `voice-db`, and the conversation agent

> 📦 **Archived 2026-09-17 — completed build.** V2 (Home Assistant + `voice-db`
> onboarded, Wyoming STT/TTS wired up) and V4 (the `llama-fast` conversation
> agent, tuned and tested end-to-end without hardware) are both done. This is
> the result record; the resulting current state is summarized in
> [`../VOICE.md`](../VOICE.md). V3 (firmware) is still open — see that file.

## V2 — Home Assistant and `voice-db`, results 2026-09-17

PR #32 merged (`8f4fe24`). First CI run failed: `render-charts.py` parsed HA's
`configuration.yaml` and rejected `!env_var`; fixed to ignore unknown tags.
`voice-db` came up healthy on `k3s-worker2`; Home Assistant on `k3s-worker1`;
the recorder created 13 tables in Postgres on first boot.

Onboarded through the UI (no YAML for any of this — see `VOICE.md` V2 for
what a rebuilt PVC needs redone):

- **Wyoming Protocol entries:** `whisper-cpp` (port `10300`) and `piper`
  (port `10200`). "Piper" in the integration search is only an alias for
  Wyoming Protocol; its port must be typed by hand — a second attempt re-used
  `10300` by accident and had to be corrected.
- **Assistant "Doofus"**, set as preferred: STT `stt.whisper_cpp`, TTS
  `tts.piper` with voice `en_US-norman-medium`.

⚠️ **Picking or previewing a voice in HA's assistant settings downloads it,
`--local-files-only` notwithstanding.** Found 2026-09-17: selecting or
previewing voices pulled `ryan-low`, `lessac-low` and `norman-medium` into
`/models/piper` from `piper-voices` `main`, unpinned — outside the hash-pinned
V1b set. `--local-files-only` only affects the `voices.json` refresh and the
OmniVoice backend, not this path. Harmless (the files land on `/models` and
then work offline), but worth knowing before assuming every voice on disk was
deliberately pinned.

## V4 — Conversation agent, results 2026-09-17

**Integration.** HA 2026.9 ships a native **llama.cpp** integration (base URL
+ API key + model) — no HACS component needed. Entry
`http://192.168.50.107:8081/v1`, streaming on, key = the cluster key from
`kubernetes/apps/observability/llm-vm/app/llm-api-key.sops.yaml` (decrypted by
the owner in their own terminal). Conversation agent `conversation.fast`,
model `fast`.

**Checked before wiring it into the pipeline:** `llama-fast` returns proper
`tool_calls` for a `HassTurnOn` definition; `n_ctx` 8192 across 4 slots; the HA
pod reaches `:8081` (`401` without a key, confirming auth is enforced).

**Doofus pipeline:** agent `conversation.fast`, **prefer handling commands
locally = on**.

⚠️ **Home Assistant device control (Assist) is deliberately OFF for now.**
With no exposed entities yet, the 4B model called `GetLiveContext` domain by
domain until HA's `MAX_TOOL_ITERATIONS = 10` (`llama_cpp/entity.py`) ran out,
producing "Unable to get response." Re-enable once real devices are exposed —
tracked in [`../BACKLOG.md`](../BACKLOG.md).

**Prompt lessons**, tested directly against `llama-fast` (14 prompts each):

- **Concrete few-shot examples leak.** A prompt with a cat example answered
  "the wifi is slow" with "move the damn cat." The example-free prompt leaked
  0/14. Describe the desired style; don't give example dialogues.
- Without an explicit rule, it claims actions it never performed ("turning off
  the lamp") — the prompt now says to report only actions a tool actually ran.
- It needs an explicit spoken-output rule (no markdown or lists; 1–3
  sentences), or it produces ~250-word bulleted answers.
- Sound effects only when asked, lowercase (Piper may spell out all-caps).
- The 4B model gets simple facts wrong (cups → ounces answered both 16 and 12
  across runs).
- Saved prompt: 1,806 characters, kept in HA only (`.storage`, not git).

## Pipeline test (no hardware)

`scripts/voice/pipeline-test.py` sends WAV files into the **Doofus** pipeline
over HA's websocket API at the STT stage — the way a satellite does — follows
it through the agent and TTS, downloads the reply audio, and prints per-stage
timings. Needs a Home Assistant long-lived token (`pipeline-test`, entered by
the owner with `read -rs`, stored SOPS-encrypted at
`scripts/voice/ha-api.sops.yaml`) and `websockets` + `aiohttp` in a throwaway
venv.

**Results, 2026-09-17** (questions spoken by Piper lessac, 0.8–2.7 s; two runs):

| Question | Path | Heard | Intent | Total |
|---|---|---|---|---|
| "What is the capital of Australia?" | LLM | exact | 727–885 ms, first token ~350 ms | **1.30–1.34 s** |
| "The wifi is so slow today, this sucks." | LLM | exact | 851–1,038 ms | **1.39–1.74 s** |
| "What time is it?" | **local** (`processed_locally: true`) | exact | 2–11 ms | **0.17–0.29 s** |

- STT: 145–251 ms, including streaming the whole clip in at once. On the real
  device audio arrives in real time and HA waits for end-of-speech silence, so
  wake → reply latency on hardware adds the length of the question plus that
  silence tail — this test measures the pipeline's own processing time, not
  the device experience. **True end-to-end latency on the real device is still
  open** — tracked in [`../BACKLOG.md`](../BACKLOG.md).
- TTS renders on fetch: 116–443 ms for an mp3 of the reply.
- Persona: on one of two runs, "capital of Australia" got a refusal ("look it
  up yourself") instead of the answer. If that keeps happening, add "always
  answer simple questions, even while complaining" to the instructions.
