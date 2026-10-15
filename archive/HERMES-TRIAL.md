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
