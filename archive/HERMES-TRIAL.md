# Hermes Agent trial — Qwen3.8-27B on the Arc card

> 📦 **Archived 2026-10-15 — trial finished, Hermes adopted.** Hermes Agent
> v2026.9.24 ran as a separate `hermes` user on the dev VM against
> `qwen27-agent`, on a throwaway clone of this repo. It was then moved to the
> `dev` user with the guardrails below. Current state:
> [`../GPU-VM.md`](../GPU-VM.md#consumers).

## Why a trial

`claude-local` was retired as too heavy for a 27B model
([`GPU-VM-BUILD.md`](GPU-VM-BUILD.md#claude-code-wrapper-retired-2026-10-14)).
The question was whether Hermes' own `patch` tool (find-and-replace with nine
matching strategies, re-indentation, a syntax check after each edit) works on
Qwen 27B, or whether Aider has to do the editing.

## Setup findings

- **No wheel install.** `pip install git+…@tag` fails by design
  (`setup.py` blocks `bdist_wheel`); the pinned `scripts/install.sh` from the
  tag with `--branch v2026.9.24` is the supported route.
- **The installer asks for sudo** for ripgrep and the Python build headers,
  even when those are present. With no password on the account it fails
  three times and carries on.
- **`auxiliary.<task>.provider: main`** works at runtime but `hermes doctor`
  resolves it with the main-model resolver and reports it unresolvable. Name
  the provider instead.
- **AGENTS.md was blocked in every session.** Hermes' context-file scanner
  (`tools/threat_patterns.py`) replaces a file with a `[BLOCKED]` notice when an
  HTML comment contains `ignore`, and AGENTS.md carried
  `<!-- doc-history:ignore -->`. The marker became `doc-history:allow`.

## Results (`qwen27-agent`, thinking off, models.ini sampling)

| Task | Outcome | Wall time | Context |
|---|---|---|---|
| SearXNG limits (YAML) | Correct in one patch, lint passed | ~27 s | ~11.8K |
| "Cut the Tool calling section 30% without dropping anything" | No pushback until asked; then a correct analysis (~16–22% possible; a careful manual pass reached 14%) | ~30 min, stopped | ~43K |
| `_is_public` for `64:ff9b::/96` and `::/96` | Half done: read `::/96` as `::ffff:0:0/96`, stated it as fact, and wrote no `::/96` test, so 49 green tests hid the gap. Added and then removed unrequested 6to4/Teredo handling | 17 min | ~37K |

- Of about a dozen `patch` calls, **one** needed a similarity match.
  Editing was not the weak point; judgement was.
- Planning text repeated two or three times in visible output despite
  thinking being off, at ~13 tok/s.
- The correct `_is_public` change landed separately (PR #151).

## What changed for the dev install

| Failure | Change |
|---|---|
| No pushback, guess stated as fact, scope creep | `agent.coding_instructions` (one rule each) and a short `SOUL.md` with the same stance |
| 30-minute runaway | `agent.max_turns: 40` |
| Green tests trusted | `verify_on_stop: auto`, plus AGENTS.md now loading |
| Repeated planning text | Non-thinking sampling in `extra_body`: 0.7 / 0.8 / 20, `presence_penalty` 1.5 (`models.ini` `[*]` carries the thinking-mode 1.0 / 0.95) |
| Secrets in a stored transcript | A never-decrypt rule in both files; `~/.hermes` on its own disk on `sas-pool`, off the boot SSD |

## Rerun of the `_is_public` task under the dev config (2026-10-15)

Same wording, run non-interactively (`hermes chat -q`, so the `clarify` rule
had nobody to ask), on a clone with the pre-fix `fetch.py`:

- **8 min 45 s**, against 17 min in the trial.
- `::/96` came back as a stated scope note and an offer, not a silent
  substitution, but it called `::/96` "6to4" (that is `2002::/16`), and
  `::192.168.50.107` still came out public.
- It kept an unrequested `addr.sixtofour` unwrap, and reported "Work is
  verified" from a probe with no `::/96` case.

Better on speed and on surfacing ambiguity; the domain error and trusting its
own tests remain.

## `clarify` with nobody to answer (2026-10-15)

Prompt: *"In scripts/llm/models.ini, raise the context of the 27B preset."*
(two 27B presets, no target size), run with `hermes chat -q`, where
`clarify` returns "Clarify tool is not available in this execution context."

| Config | Asked? | Then |
|---|---|---|
| four `coding_instructions` | yes: named both presets and asked which, and to what | guessed `qwen27` → 81,920 and edited five files, VOICE.md and the whisper unit among them |
| plus "if clarify is unavailable, stop… don't edit" | yes, and said it needed a call before editing | guessed `qwen27-agent` → 262,144, a context that can't load with MTP, with a comment asserting it fits |

The rules make it ask; nothing in the prompt makes it stop once the tool
refuses. Non-interactive modes are for questions, not edits
(`GPU-VM.md` → *Consumers*).

## `key_cmd` and in-session `/model` (2026-11-21)

After the `neo-coder` presets were renamed `heretic`, switching to
`heretic-agent` with `/model` on a laptop install failed in three layers:

- The local `config.yaml` predated the rename's config change: no
  `providers.llama.models` windows (Hermes fell back to 256,000) and every
  side task pinned to `qwen27-agent`. Fixed by installing the repo copy.
- The `/model` picker still offered `neo-coder` and `neo-coder-agent`,
  read from `~/.hermes/provider_models_cache.json`, written before the
  rename. Deleting the `custom:http://192.168.50.107:8080/v1#…` entry made
  Hermes refetch the real list.
- With the right names, the switch reported "could not reach this custom
  endpoint's model listing" and the first message failed with
  `'CommandTokenSource' object has no attribute 'strip'`. `key_cmd` makes
  the provider key a callable token source. The picker resolves it
  (`hermes_cli/model_switch_providers.py`, `materialize_probe_api_key`),
  but `_validate_switch` (`hermes_cli/model_switch.py`) passes it straight to
  `probe_api_models`, which sends `Bearer <CommandTokenSource …>` and gets
  `401`, and the agent rebuild calls `.strip()` on it. `hermes -m` at
  startup takes a different path and worked throughout.

The config moved to `key_env: LLAMA_API_KEY`, with `install.sh` copying
`~/.config/llama/api-key` into `~/.hermes/.env` (built with the `printf`
builtin, so the key is never in argv). After that, `/model heretic-agent`
switched cleanly and answered. The cost is a second plaintext copy of the key
per machine, in a mode-600 file Hermes already uses for credentials.
