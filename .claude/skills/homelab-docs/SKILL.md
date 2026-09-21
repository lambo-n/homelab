---
name: homelab-docs
description: House style and upkeep for this repo's documentation. Use when writing or editing any Markdown here (README.md, GITOPS.md, BACKLOG.md, GPU-VM.md, VOICE.md, SANOID.md, runbooks/, archive/), when a change lands that the docs describe (a dependsOn edit, a version bump, a new app, a finished backlog item, a decision), when drawing or updating a diagram, or when asked to check the docs for drift.
---

# Homelab docs

The docs in this repo are the operator's working reference *and* a public
showcase, so they have to be correct, current and readable by a stranger.
Three rules carry most of the weight:

1. **Root docs describe the present.** History goes in `archive/`.
2. **Anything a machine can derive is generated or checked, not hand-kept.**
3. **Every claim points at its source**, so a reader can verify it.

## Where things go

| File | Holds | Doesn't hold |
|---|---|---|
| `README.md` | What runs, on what hardware, why it's shaped this way; the request path; layout; the dependency graph | Per-tool flags and gotchas |
| `GITOPS.md` | One section per tool: *Config at a glance* table, gotchas as ⚠️ callouts, how to check it. *Cross-cutting decisions* and *Explicitly rejected* hold decisions and their current rationale | How a decision was reached |
| `BACKLOG.md` | Open items only, each with what it waits on and where context lives | Finished items; delete them, don't tick them |
| `GPU-VM.md`, `VOICE.md`, `SANOID.md`, `SAS-STORAGE.md`, `HARDWARE.md`, `HOST-MONITORING.md` | Current state of things outside Flux; these docs *are* the record | Build logs |
| `runbooks/` | Procedures meant to be re-run (restore drill, snapshot check) | One-off procedures once done |
| `archive/` | History: build logs, incidents, migrations, how decisions were reached, dated verification runs. See `archive/README.md` | Anything a reader needs to operate today |
| `AGENTS.md` | Rules for assistants working here | Cluster facts that belong in README/GITOPS |

A decision has two halves. The **why it's this way now** goes in the GITOPS.md
section (or *Cross-cutting decisions*), written as current state. The **story**
(options weighed, what changed, when) goes in an `archive/` topic file, and
the root doc links to it in one line: `History: archive/<FILE>.md`.

## Writing current state (AGENTS.md rule 8)

When something changes, **rewrite** the affected text to the new state. Don't
append a correction below it. Test: would the sentence still read correctly
if the homelab had always been this way? If not, it's history.

| Instead of | Write | Put the rest in |
|---|---|---|
| "Restricted 2026-09-21: the policy now grants…" | "The policy grants…" | `archive/<TOPIC>.md` → `## 2026-09-21 — restricted` |
| "An earlier revision said X; that was wrong" | the correct statement | archive, if the mistake is worth keeping |
| "PostgREST no longer depends on postgres" | "PostgREST depends on postgres-cnpg" | nowhere; the commit says it |
| "Verified 2026-09-21: returned 000" | a *Checking it* table: command → expected result | archive, with the dated raw results |
| ✅ / ~~strikethrough~~ on finished work | delete the item | archive, if there's a story |

`.github/scripts/doc-history-check.py` flags history-style wording in added
lines (it runs as a PostToolUse hook and in CI). It's a heuristic. When it
flags a line, decide; if the line really is current state and must quote a
pattern, end it with `<!-- doc-history:ignore -->`. Fix older violations in a
section when you're editing that section anyway, not as drive-by sweeps.

## House style

- **Lead with the fact, then the why.** "`reloader` has no `dependsOn`, so a
  stuck app can't hold back restarts." The *why* is what a reader can't
  reconstruct from the manifests.
- **Point at the source** with a path: `→ kubernetes/apps/…/ks.yaml`,
  `tofu/README.md:200`, `GITOPS.md` → *Section*. Cite the file that pins a
  value rather than restating it where you can.
- **⚠️ callouts are for traps that are true now**: behaviour that surprises,
  checks that lie (`403` from Access is not a health check). Not for dated
  corrections.
- **Verification is behavioural.** A *Checking it* section gives a command a
  reader can run today and the result that means healthy, including what a
  failure looks like (`000` = routing/policy, any HTTP status = reachable).
- **Tables for configuration, prose for reasoning.** GITOPS sections open with
  a *Config at a glance* table.
- **Public repo.** No secret values, no personal notes, nothing you wouldn't
  want a stranger to read. Credential *locations* are fine and expected.
- Commands for the owner to run are short lines with no `<placeholders>`, and
  work in bash and fish.

## Diagrams

**The `dependsOn` graph is generated. Never draw it by hand.** It lives in
`README.md` between `<!-- depgraph:start -->` and `<!-- depgraph:end -->`.
After any `ks.yaml` change:

```bash
python3 .github/scripts/depgraph.py --write README.md
```

CI (`validate-manifests` → *kustomize build*) runs `--check` and fails the PR
if the committed graph is stale or a `dependsOn` names a Kustomization that
doesn't exist. Prose around the graph explains the *non-obvious* edges and
absences. Don't restate edges the graph already shows.

**Conceptual diagrams are hand-written**: the public request path, trust
boundaries, the layer split, anything that needs judgement about what
matters. Use Mermaid for new ones (GitHub renders it); the existing ASCII
request-path diagram can stay until that section is next rewritten.

- Name nodes after the real object (`cloudflared pod`, `postgres-cnpg-rw`,
  `192.168.50.101:8006`), not generic boxes.
- Label edges with what crosses them: port, protocol, or auth
  (`HTTPS + Access token`, `tcp:5432`).
- Use a `subgraph` per trust boundary or host (internet / Cloudflare / LAN /
  cluster), so LAN-only and tunnel paths are visibly different.
- `flowchart LR` for request paths. Keep it under about 12 nodes; split the
  diagram before it needs horizontal scrolling on GitHub.
- A diagram states current topology only; a change to it is rule 8 like any
  other text.

## Versions

Renovate bumps manifests, charts and `mise.toml`; it doesn't touch prose. So:

```bash
python3 .github/scripts/version-drift.py
```

checks every version the docs state that a file in the repo pins (charts,
image tags, mise tools) and exits 1 on drift or on a claim whose sentence no
longer matches. Run it whenever you touch README.md or GITOPS.md, and fix
drift in the same change.

- **Adding a version to prose?** Add a `CLAIMS` entry in the script in the
  same change, or cite the file instead of the number.
- **Versions no repo file pins** (chart appVersions: Prometheus, Alertmanager,
  Grafana, prometheus-operator, Reloader, barman plugin, CNPG operator; Flux
  controllers; Traefik from k3s) come from the live cluster. Read them there,
  never from memory:

  ```bash
  kubectl get pods -A -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' | sed 's/@sha256.*//' | sort -u
  ```
  ```bash
  kubectl get fluxinstance -A -o jsonpath='{.items[0].status.lastAppliedRevision}'
  ```
- Examples that illustrate a point ("the chart version is not the app
  version") shouldn't quote patch versions that will go stale; use `2.x`-style
  majors or no numbers.

## Checklists

**A change landed** (config, policy, topology):
1. Rewrite the affected sections to the new state (rule 8).
2. Record the story in `archive/`, if there is one worth keeping; link it.
3. Delete the backlog item if this finished one.
4. Run the checks below.

**Adding a workload:**
1. `kubernetes/apps/<ns>/<app>/ks.yaml` + `app/`.
2. `README.md` → *What runs on it* row; *Repository layout* tree.
3. `AGENTS.md` → *What this repo deploys* table, if it's a new namespace.
4. `depgraph.py --write README.md`.
5. A GITOPS.md section if it's a new tool with config worth knowing.
6. Any version stated in prose → a `CLAIMS` entry.

**Before committing docs:**

```bash
python3 .github/scripts/depgraph.py --check README.md
```
```bash
python3 .github/scripts/version-drift.py
```
```bash
python3 .github/scripts/doc-history-check.py --base origin/main
```

Everything goes through a branch and PR: a ruleset on `main` requires
status checks, so direct pushes are rejected even for docs.
