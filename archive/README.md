# Archive

History for the homelab: build logs, incidents, migrations, and how
decisions were reached. The docs at the repo root describe only the current
state (`AGENTS.md` rule 8). Anything about *how it got that way* belongs here.

## What goes here

- The story of a change: what was found, what was tried, what was decided,
  and why the alternatives lost.
- Verification runs with dates and raw results, before/after comparisons.
- Completed runbooks and build logs (`GPU-VM-BUILD.md`, `VOICE-BUILD-*.md`).
- Corrections: "the docs used to say X, and that was wrong because Y".
- Finished backlog items, when there's more to them than the commit message.

## Conventions

- **One file per topic**, named `<TOPIC>-<WHAT>.md` in caps
  (`TAILSCALE-SUBNET-ROUTE.md`, `SAS-STORAGE-INCIDENT.md`). Append a dated
  `## YYYY-MM-DD — <event>` section to an existing topic file rather than
  starting a new one.
- **Open with an archive banner** saying what the file covers, when it was
  archived, and where the current state lives:
  `> 📦 **Archived YYYY-MM-DD.** … Current state: [../GITOPS.md](../GITOPS.md#…)`.
- **The root doc links here in one line** — e.g. "History: `archive/…`" —
  and carries none of the narrative itself.
- **Archived files are append-only records.** Don't rewrite them to match
  the present. If one is wrong, add a dated note.
- Relative links from here start with `../`.
