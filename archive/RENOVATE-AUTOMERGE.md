# Renovate automerge — how the rules got their shape

> 📦 **Archived 2026-10-05.** The dated findings behind the Renovate
> automerge, rebase and check-gating settings. Current state:
> [../GITOPS.md](../GITOPS.md#renovate).

## 2026-09-03 — dry run

> Moved from `GITOPS.md` → *Renovate* in the 2026-10-05 docs pass, as it stood.

> **Dry run passed 2026-09-03.** Daily cron (`0 10 * * *` UTC) will open the
> first real PRs on the next run. Workflow also triggers on push to `main`
> when Renovate config changes.

## 2026-09-08 — automerge widened, checks gated, `pr` instead of `branch`

> Moved from `GITOPS.md` → *Renovate* in the 2026-10-05 docs pass, as it stood.

> **Automerge widened 2026-09-08: minor/patch/digest everywhere, majors never.**
> It had been scoped to three container images plus GitHub Actions and mise
> tools, which left every Helm/OCI chart manual — three PRs sat green and unmerged
> (kube-prometheus-stack `89.2.4` and `90.0.0`, plugin-barman-cloud `0.8.0`) not
> because Renovate was waiting for anything, but because no rule matched them.
> The blanket rules now key on `matchUpdateTypes` alone; the carve-outs are
> `kubectl`, the Actions cooldown, and 0.x deps.
>
> **0.x needs its own rule.** For a 0.x dep the breaking boundary is the minor,
> but Renovate types `0.7.1 -> 0.8.0` as *minor*, so the blanket rule would have
> automerged it — even though the preset's own commit message calls that bump
> breaking (`feat(container)!`, as plugin-barman-cloud 0.8.0 arrived). A
> `matchCurrentVersion: "/^0\\./"` rule pins those back to manual.
>
> **What gates it (2026-09-08).** `.github/workflows/validate-manifests.yaml`
> builds all 21 Kustomizations with the mise-pinned `kubectl` and checks that every
> `ks.yaml` `spec.path` resolves. `ignoreTests` is gone, so Renovate waits for it.
>
> **`automergeType` moved `branch` → `pr` the same day.** Under `branch` Renovate
> merged straight into `main` with no PR, which bypassed every `pull_request`
> trigger — and GitGuardian only posts a check on a PR. Verified by API: its check
> run is present on a PR head (`460c593`) and absent on a push to `main`
> (`c9003da`, which carries only the two GitHub Actions checks). So secret scanning
> never gated an automerged update. Under `pr` every update gets a PR, collects the
> same checks a human PR would, and Renovate merges it.
>
> **The workflow carries no `paths:` filter, deliberately.** A Renovate branch that
> touches only `mise.toml`, `tofu/` or `.github/` would otherwise produce *no* check,
> and Renovate's reading of a commit with zero checks decides between merging
> unvalidated (if it resolves green) and never merging at all (if yellow) — the
> commit status API returns `pending` for a commit with no statuses, so this is not
> a coin worth flipping. A 12s run on every PR removes the question.
>
> **The `renovate/**` push trigger was dropped 2026-09-14 — it billed double.**
> Renovate pushes the branch and opens the PR about two seconds later, so both
> triggers fired on every branch update: two runs, two jobs each, four billable
> job-minutes where two would do (GitHub rounds every job up to the minute). The
> last 100 runs before the change split 57 push / 43 `pull_request` — roughly one
> duplicate per PR. The trigger dated from `automergeType: branch`, where a branch
> could exist with no PR at all; under `pr`, with `:disableRateLimiting` leaving no
> `prConcurrentLimit` or `prHourlyLimit` to defer creation, the PR always follows
> the branch. The window it covered is two seconds wide and it fails safe: a branch
> with no PR carries zero checks, which the status API reports as `pending`, so
> Renovate declines to merge. Stuck, not unvalidated.
>
> **Chart rendering is gated too, in a second job.** `helm template` over all six
> HelmReleases, with the helm pinned in `mise.toml` and each release's own
> `spec.values`, resolving the chart the way Flux does — `chartRef` → `OCIRepository`
> for five of them, `chart.spec` → `HelmRepository` for infisical. This is what a
> chart bump actually needs: a `HelmRelease` points at an `OCIRepository` tag, so a
> version that does not exist, cannot be pulled, or breaks against our values is one
> valid-looking string that `kustomize build` reads without complaint. Script at
> `.github/scripts/render-charts.py`; it exits non-zero on the first chart that
> fails and prints helm's stderr.
>
> Neither job talks to the cluster — no kubeconfig, no installed CRDs, no real
> `Capabilities.APIVersions` — so a chart that renders can still fail to apply, and
> **a minor chart bump can still roll a live workload, including CNPG's operator and
> the Postgres pod it manages.** Reconcile-time `wait: true` plus healthChecks stay
> the last line of defence.
>
> **GitHub holds the PR, not Renovate** *(since 2026-09-21)*. `platformAutomerge:
> true` means Renovate marks a PR for auto-merge and GitHub merges it the moment
> the required checks go green, rather than Renovate reading a check status
> mid-run and deciding. The ruleset `main-required-checks` on `main` requires
> **kustomize build**, **helm template** and **GitGuardian Security Checks**, and
> deliberately leaves *"require branches to be up to date"* **off** — turning it
> on would stall every PR behind a rebase, which is the failure the `rebaseWhen`
> note below describes.
>
> This still depends on the App's "Commit statuses" read permission, the one
> missing from 2026-09-03 to 09-08. And a required check that goes red now
> genuinely blocks the merge, including for a human merging a major by hand —
> which it did not before the ruleset existed.
>
> ⚠️ **The premise this setting sat on for two weeks was wrong.** It was `false`
> because branch protection was believed unavailable "for a private repo on this
> plan". **The repo is public**, so the rule was always available. The bill: PR
> #15, an OpenTofu lockfile update, could not merge for nine days — Renovate's
> terraform manager regenerates `.terraform.lock.hcl` every run and reports it
> updated without diffing, which forces `reuseExistingBranch: false`, which
> force-pushes a byte-identical lock file, which restarts `validate-manifests`,
> which the same run then reads as pending. Every run, forever.

## 2026-09-14 — `rebaseWhen: conflicted`, and the two-merges-per-run ceiling

> Moved from `GITOPS.md` → *Renovate* in the 2026-10-05 docs pass, as it stood.

> **`rebaseWhen: conflicted` since 2026-09-14 — the default capped automerge at one
> PR per run.** `rebaseWhen` defaults to `auto`, which Renovate resolves to
> `behind-base-branch` whenever automerge is enabled. Every automerge moves `main`
> and makes Renovate restart the repository job; the restart then found each
> remaining automerge branch a commit behind, rebased it, and every force-push
> restarted `validate-manifests` — so those checks sat *pending* for the rest of
> that same run, and the run could merge nothing more. One PR merged per run while
> the rest were pushed back to pending, which is how nine PRs, all green, had
> queued up by 09-14. Under `conflicted` the branches hold still, keep their green
> checks, and the post-automerge restart takes the next eligible PR immediately.
>
> **It capped at two automerges per run while Renovate did the merging.** Renovate
> restarts the repository job exactly once — `renovateRepository(repoConfig,
> false)` in `workers/repository/index.ts`, after which the second pass logs
> "Automerged but already retried once" and stops. It is not configurable. The
> 09-14 push run that carried this change merged `secrets-operator` and `helm`,
> then finished with five eligible PRs still open. **`platformAutomerge: true`
> removed that ceiling** — GitHub merges each PR as its own checks pass, so the
> per-run limit no longer decides anything. `rebaseWhen: conflicted` still earns
> its keep by keeping green checks green and saving ~16 pointless
> `validate-manifests` jobs per run.
>
> The trade Renovate's docs name for `conflicted` — updates merging one after
> another without having been tested together, checks that ran against an older
> `main` — is the reconcile-time bet this repo already makes everywhere else. The
> docs' other objection, that automerge stalls once a PR is out of date, applies
> only where the branch rule requires up-to-date PRs, which `main-required-checks`
> deliberately does not.

## 2026-09-03 — adoption pinned to the running digests

> Moved from `GITOPS.md` → *Renovate* in the 2026-10-05 docs pass, as it stood.

> **Pinned to what was running, not to latest.** Digests were read off the live
> pods (`.status.containerStatuses[].imageID`) and mapped back to version tags,
> so adoption is a no-op rather than a silent upgrade. `kubectl diff` against the
> cluster shows *only* the four image lines and the four prune annotations.
