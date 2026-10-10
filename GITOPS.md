# GitOps — Operating Notes

**What this file is:** the flags, gotchas, config context and open items for every
tool that runs this homelab. It is organised **by tool**, because that is how you
arrive at it — something is behaving oddly, or you are about to change a chart
version, and you want to know what is already known about that specific thing.

It is not an introduction. For what the hardware is, what the cluster is *for*,
and what each tool actually does, read [`README.md`](README.md) first.

Nothing here is theory. Every ⚠️ is something that already happened on this
cluster, with the date it happened and how it was diagnosed. Several of them
describe failures that reported success — those are the ones worth reading twice.

The PGDATA zvol and worker disk growth were built via a host-side runbook, now
complete and archived at [`archive/STORAGE.md`](archive/STORAGE.md); the
resulting config is current-state reference in [`SANOID.md`](SANOID.md) (ZFS
snapshots) and [`HARDWARE.md`](HARDWARE.md). Two **repeatable** runbooks live
under `runbooks/`: [`runbooks/RESTORE.md`](runbooks/RESTORE.md) (the CNPG
restore drill) and [`runbooks/SANOID-VERIFY.md`](runbooks/SANOID-VERIFY.md)
(the snapshot rollback drill). `tofu/README.md` covers the OpenTofu root module.
Open items and remaining backlog live in [`BACKLOG.md`](BACKLOG.md), not here.

---

## Index

| Tool | Jump to | The flag most likely to bite you |
|---|---|---|
| Flux / flux-operator | [↓](#flux--flux-operator) | The operator install is the one imperative step; prune is on |
| SOPS + age | [↓](#sops--age) | Lose `age.key` and every secret here is unreadable |
| Infisical | [↓](#infisical) | Cloudflare Worker secrets are **write-only** — you cannot verify a match |
| Renovate | [↓](#renovate) | Charts pinned by chart version, never by app version |
| CloudNativePG + barman | [↓](#cloudnativepg--plugin-barman-cloud) | The bootstrap still names a Service that no longer exists |
| cert-manager | [↓](#cert-manager) | Exists only for the barman plugin; no ClusterIssuer |
| Reloader | [↓](#reloader) | Without it, a rotated Secret reports success and changes nothing |
| cloudflared | [↓](#cloudflared) | `config_src` decides routing — a local file alone does nothing |
| MinIO | [↓](#minio) | The scoped policy withholds `ListBucket`, so `mc ls` cannot verify it |
| PostgREST | [↓](#postgrest) | `401` on anonymous is correct, not a fault |
| transcribe-api | [↓](#transcribe-api) | `whisper-server` serializes requests behind one GPU mutex |
| searxng | [↓](#searxng) | No redis, so the request limiter is off — fine for one caller, not a public instance |
| kube-prometheus-stack | [↓](#kube-prometheus-stack) | The Flux alert every guide gives you queries a metric that no longer exists |
| sanoid (host) | [↓](#sanoid-host) | A snapshot of a live Postgres is crash-consistent, not a backup |
| Tailscale (host) | [↓](#tailscale-host) | The policy file is a record, not applied by anything — edit it, then paste it into the console |
| OpenTofu | [↓](#opentofu) | `PVEAuditor` cannot import a QEMU guest, and the error lies about why |
| mise | [↓](#mise) | Shims must sit above the interactivity guard in `.bashrc` |
| k3s / storage substrate | [↓](#k3s--storage-substrate) | `local-path` provisions a directory, not a quota |

---

## Open items

Tracked in [`BACKLOG.md`](BACKLOG.md), not here — that file consolidates open
items from across this repo in one place. What follows below is current
per-tool reference, plus one standing record of decisions that are *closed*,
not open:

### Explicitly rejected

| Option | Why |
|---|---|
| Flux/Crossplane/tofu-controller for Proxmox | Circular dependency on a single host. Also dissolves a real boundary: the shim needs a Proxmox API token with `VM.Allocate` stored in-cluster, so cluster compromise would become hypervisor compromise — today the cluster cannot touch `.101` at all. **Revisit if** a second Proxmox node appears, *or* if a separate management cluster exists (k3s in an LXC on the host) so the reconciler no longer sits on its own substrate |
| `prometheus-pve-exporter` in-cluster | Needs a Proxmox API token in the cluster, the credential the scope split below keeps out, even read-only (`PVEAuditor`). `host-metrics` on the host exports the thin pool (including `Meta%`, which pve-exporter lacks) and pool capacity instead; every guest that matters runs its own node-exporter. **Revisit if** per-guest metrics from the Proxmox API are ever needed. See [`HOST-MONITORING.md`](HOST-MONITORING.md) |
| Flux image automation controllers | Renovate is a strict superset; they'd conflict |
| R2 for backups | The owner chose not to keep backups on Cloudflare. Off-site goes to **Backblaze B2** instead. See *Off-site backup* under CloudNativePG |
| CNPG `instances: 3` | False redundancy on one hypervisor |
| Cilium BGP / Multus | No network gear to peer with |
| `actions-runner-controller` | Another circular dependency on a single host |
| `HelmRelease` semver ranges | Runtime drift; git stops describing what's deployed |
| Per-environment Cloudflare Access service tokens | **Deliberate, decided 2026-09-02.** One `sunfire-worker` token is shared by the prod Worker, the feature Worker and local dev. Splitting it would allow revoking a leaked local/laptop token without taking production down — the same reasoning that keeps *two* MinIO service accounts one layer below. Rejected anyway: prod being down costs nothing and all stored data was non-critical, so the blast radius the split protects against was not worth the extra tokens to manage. **The asymmetry with MinIO is intentional — do not "fix" it.** ⚠️ The revisit condition was "if this cluster ever stores something that matters"; the Worker is now live on `sunosrs.cc`, so this is worth re-reading rather than assuming still-settled |

---

## Cross-cutting decisions

Two decisions that are not about any single tool, and that constrain everything
below.

### Scope: Flux manages the cluster, not the hypervisor

Flux reconciles the Kubernetes API. Proxmox VMs, ZFS datasets, and PVE config are not Kubernetes
objects, so "Flux for the whole Proxmox server" needs a shim (Crossplane `provider-proxmox-bpg`,
or `tofu-controller`).

**Rejected for now.** On a single host it's circular: Flux runs on k3s → k3s runs on VMs on `.101` →
Flux would manage those VMs. A bad reconcile destroys the cluster running the reconciler, and `.101`
is also the NFS server, so the archival data path goes with it. Both shims are community-maintained
single-vendor projects — thin bus factor for something that can delete VMs.

Layer split:

| Layer | Tool | Why not Flux |
|---|---|---|
| PVE host config (ZFS, network, NFS exports, packages) | Ansible, manual | No declarative API; Flux can't reach it |
| VM / LXC lifecycle | OpenTofu + `bpg/proxmox` | Must survive the cluster being down |
| k3s workloads | **Flux** | This is what Flux is for |

**Revisit if a second Proxmox node appears** — that breaks the circular dependency and moves
Crossplane from footgun to reasonable.

### Prune safety

- Start every Kustomization at `prune: false`; enable only after several clean reconciles.
- Annotate stateful resources: `kustomize.toolkit.fluxcd.io/prune: disabled`
- PVs are `Retain`, but a mislabeled prune deleting `minio-pvc` is the one thing
  that would actually hurt.

> **Prune is live.** `prune: true` on every app Kustomization except
> `sunfire-storage`, which stays `false` permanently. `namespace.yaml` and the
> PV/PVCs carry `kustomize.toolkit.fluxcd.io/prune: disabled`. **Removing a
> manifest from git now deletes the live object.**

---

## Flux / flux-operator

**Config at a glance**

| | |
|---|---|
| Install | `flux-operator` chart **0.59.0**, applied imperatively; `FluxInstance` in `bootstrap/flux/flux-instance.yaml` |
| Distribution | Flux **v2.9.5**, four controllers — source, kustomize, helm, notification. Image automation deliberately absent |
| Sync | `ssh://git@github.com/lambo-n/homelab.git`, `refs/heads/main`, path `kubernetes/flux/cluster`, `interval: 1m` |
| Deploy key | ed25519, **read-only**, GitHub key id `162121868`, titled `flux-homelab-deploy (k3s flux-system)`. Private half at `~/.ssh/flux-homelab-deploy` (`chmod 600`, never in git); in-cluster as Secret `flux-system` with `identity` / `identity.pub` / `known_hosts` |
| Decryption | `sops-age` Secret in `flux-system`, key name `age.agekey` |
| Networking | `networkPolicy: true` — the operator installs `allow-egress`, `allow-scraping` (port 8080, all namespaces) and `allow-webhooks` in `flux-system` |

Install controlplane.io's `flux-operator` + a `FluxInstance` CR. Flux manages itself declaratively
and Renovate can bump it. Per the reference repo, install only:

```yaml
components:
  - source-controller
  - kustomize-controller
  - helm-controller
  - notification-controller
```

> **The `flux-operator` install is the one imperative step left.** It was applied
> with `helm upgrade --install ... --version 0.59.0` rather than from git, because
> it is the thing that *starts* the reconciler. The pinned version is recorded
> above so Phase 4 can hand it to Renovate; the `FluxInstance` it manages is
> already declarative.

**Three intervals, and only one of them fetches.** These get conflated, so:

| Interval | What it actually does | Set in |
|---|---|---|
| `spec.sync.interval: 1m` | source-controller polls GitHub for new commits on `main` | `bootstrap/flux/flux-instance.yaml` |
| `fluxcd.controlplane.io/reconcileEvery: 1h` | flux-operator reconciles the `FluxInstance` — Flux's *own* install | same file, as an annotation |
| `interval: 30m` on every app | re-applies the revision already fetched, correcting drift | each `ks.yaml` |

There is no notification-controller `Receiver` and nothing pushes to Flux, so that
1m poll is the only path from a push to the cluster. `flux reconcile source git
flux-system` forces a fetch; `flux reconcile kustomization <name>` only re-applies
what is already local.

**Checking push-to-apply.** Push a throwaway app (one `pause` pod in its own deliberately prunable namespace) to `main`: it should be Ready on the cluster in under a minute with no manual reconcile, and reverting the commit should prune the Deployment *and* the namespace with no cleanup. `interval: 1m` is set explicitly in `flux-instance.yaml`; the 30m figure is the app Kustomization interval, not the source's.

> **`prune: true` on `sunfire-{minio,postgres,postgrest,cloudflared}`; `sunfire-storage` keeps `prune: false` permanently.** Removing a manifest from git deletes the live object. Prune only removes objects a Kustomization already owns and git has stopped declaring, so before enabling it on a Kustomization, dump its inventory (`kubectl get kustomization <name> -o jsonpath='{.status.inventory.entries}'`) and match it against git: a correct inventory makes enabling it an immediate no-op.
>
> ⚠️ **The parent `flux-system` Kustomization runs `prune: true`** — flux-operator sets that on the sync Kustomization by default — and the `sunfire` Namespace is in its inventory. Dropping `namespace.yaml` from git would delete the namespace, and the Kubernetes garbage collector would take every object inside with it. The `prune: disabled` annotations on the PVCs do **not** stop that: they stop Flux, not the GC cascade. PVs are `Retain`, so the data survives, but the claims would not. `namespace.yaml` carries `prune: disabled` to close it.

**Health checks and `dependsOn` are load-bearing.** A `healthCheck` naming an
object that no longer exists **fails** its Kustomization, and a failed
Kustomization blocks everything that `dependsOn` it. Deleting a Deployment
therefore means removing its healthCheck in the same commit, or its dependents
wedge instead of the change failing locally. A zero-replica Deployment, by
contrast, *is* healthy: kstatus reports it Current.

---

## SOPS + age

**Config at a glance** — `sops` **3.13.3**, `age` **1.3.2**, both pinned in `mise.toml`.
Keypair at `~/homelab/age.key` (`chmod 600`, gitignored). Public recipient in
`.sops.yaml`. Ten keys encrypted across the `*.sops.yaml` files; every payload is
`ENC[…]` and all metadata stays readable.

*Settled 2026-09-02.* Two classes of secret with genuinely different needs, so two homes.

| Class | Keys | Home | Why |
|---|---|---|---|
| **Cross-boundary** | `PGRST_JWT_SECRET`, `{PROD,FEATURE}_MINIO_{ACCESS,SECRET}_KEY` | **Infisical** (free tier) | Must stay byte-identical across the cluster *and* two Cloudflare Worker envs. Four copies synced by hand today — a real, present failure mode |
| **Cluster-only** | `MINIO_ROOT_USER/PASSWORD`, `POSTGRES_PASSWORD`, `PGRST_DB_URI`, cloudflared `token` | **SOPS + age**, in git | Nothing outside the cluster consumes them |

**Why not route everything through Infisical.** This cluster is frequently powered
off. With SOPS the secrets live in git, so a cold boot is self-contained. Routing
cluster-only secrets through a cloud API adds a hard boot-time dependency on
`app.infisical.com` (and on a free tier staying free) in exchange for nothing —
no external system reads those keys.

**Infisical relocates the bootstrap problem, it does not remove it.** The
operator authenticates with a machine-identity client ID + secret that must
already exist as a Kubernetes Secret before it can fetch anything. That
credential is seeded via SOPS — so `age.key` stays alive, holding exactly one
secret. Accepted deliberately: the alternative (hand-applied bootstrap
credential) trades a 184-byte key for a manual step on every cluster rebuild.

`age.key` itself is the one secret that can live in **neither** system — it is
the key that decrypts the others, and any machine credential used to fetch it
would die with the VM it is stored on. It lives in a personal password manager
(LastPass), reachable by human login from any device. See "Phase 2".

Flux decrypts natively via `decryption.provider: sops`. One age keypair, key stored in-cluster only.

```yaml
# .sops.yaml
creation_rules:
  - path_regex: (bootstrap|kubernetes)/.*\.sops\.ya?ml
    encrypted_regex: "^(data|stringData)$"
    mac_only_encrypted: true
    age: "age1..."
```

External Secrets Operator + 1Password is what the reference repo layers on top — **not adopted**:
1Password needs a subscription. Infisical's own Kubernetes Operator covers the
cross-boundary class natively (no ESO, no `bitwarden-sdk-server` sidecar, no
cert-manager dependency), and its CLI is in mise's registry so it pins alongside
the rest of the toolchain.

> Bitwarden Secrets Manager was the runner-up and is also free, but ESO's
> Bitwarden provider requires a `bitwarden-sdk-server` sidecar over HTTPS
> (the Rust SDK is ~150MB) plus cert-manager. More machinery for the same job.
>
> HCP Vault Secrets was ruled out outright — decommissioned, EOL 2026-07-01.

> Public recipient: `age1ncpf5hg778lpszpv0u9mm48k5sdlm4y4v4dfsnaqskuwtwfgn3eqkz25qt`
>
> Verification actually performed before committing: every `*.sops.yaml`
> round-trips to a value semantically identical to its plaintext original; every
> key under `data`/`stringData` is `ENC[…]`; and each staged blob was grepped for
> all 14 real secret values/fragments (plus the age private key) — zero hits.
>
> ✅ **`age.key` is backed up in LastPass** (secure note, human login from any
> device — deliberately *not* in Infisical, since a machine credential used to
> fetch it would die with the VM). Worth confirming LastPass PBKDF2 iterations
> read 600,000: many pre-2023 accounts were left at 5,000, and after the 2022
> vault exfiltration that setting plus master-password strength is the whole
> remaining defense. Anything added in 2026 was not in the 2022 snapshot.
>
> ⚠️ Original warning, kept for context: **`age.key` exists only on this VM and is gitignored.** Lose it and every
> secret in the repo is unrecoverable. Back it up off-VM.

> ⚠️ **Never `cat` `age.key`**, including to display it for backup — that puts it
> in shell history and agent transcripts. Copy it out by hand.

---

## Infisical

**Config at a glance**

| | |
|---|---|
| Project | `sunfire-homelab`, id `a47fcb88-5044-463e-a7c6-7119b4f3c89e` |
| Environments | `Production [prod]`, `Feature [feature]`; `staging` deleted |
| Auth | A machine identity (Universal Auth). Client ID + secret are the one bootstrap credential, SOPS-encrypted at `kubernetes/apps/sunfire/infisical/app/credentials.sops.yaml`, written by `scripts/infisical-identity-secret.sh` |
| Operator | chart **0.11.11**, own `infisical` namespace, scoped to `sunfire` |
| Seeding | `scripts/infisical-seed.py --apply` |

> ⚠️ **The environment SLUG is what the CLI and operator key off**, not the
> display name. The environments were renamed from the defaults; renaming a
> display name alone and leaving the slug is a silent trap.

Cross-boundary secrets only — see the table under [SOPS + age](#sops--age) for
which class goes where.

> **Ordering:** populate and verify Infisical *before* removing anything from
> SOPS. Until the operator is proven, the SOPS copies are the working system.

> 🛑 **Decision (2026-09-02): the Infisical → Wrangler re-push is DECLINED.**
> Briefly approved, then withdrawn before execution — no Wrangler write ever
> ran. The Worker's secrets were staged by hand at 20:20Z and are working;
> re-pushing to *prove* a byte-match is not worth touching a live production
> credential path that nobody is asking to change. Wrangler's copies remain
> asserted-equal, and that is accepted. Revisit only at a genuine rotation.
>
> Corollary: **Infisical is a backup, not a source that pushes outward.**
> Nothing reads it yet. Widening it to more Worker secrets is additive and
> safe; pushing *from* it to Cloudflare is a separate, deliberate act.

> ⚠️ **Cloudflare Worker secrets are write-only.** `wrangler secret list` returns names and types, never values, so "Wrangler byte-matches Infisical" cannot be verified. The only way to guarantee the match is to re-push from Infisical to Wrangler, which makes Infisical canonical in fact rather than in principle. Until that push, Wrangler's copies are asserted equal, not verified equal.

> 🔎 **Finding: three Worker secrets exist only in Cloudflare.**
> `wrangler secret list` shows `DISCORD_BOT_TOKEN`, `DISCORD_CLIENT_SECRET`
> and `SESSION_HASH_SECRET` beyond the cross-boundary set. Checked against
> `sunfire/.dev.vars` (gitignored, holds real values):
>
> | Secret | Local copy | If the CF account is lost |
> |---|---|---|
> | `SESSION_HASH_SECRET` | **real value present** | recoverable from `.dev.vars` |
> | `DISCORD_BOT_TOKEN` | placeholder only | regenerate in Discord dev portal |
> | `DISCORD_CLIENT_SECRET` | placeholder only | regenerate in Discord dev portal |
> | `CF_ACCESS_CLIENT_{ID,SECRET}` | placeholder only | not yet generated (pending cutover) |
>
> ⚠️ `SESSION_HASH_SECRET`'s only readable copy is in `.dev.vars`, and there is
> **no way to confirm it matches what is live** in either Worker env (Cloudflare
> is write-only). `.dev.vars` aligns with *feature* on every key that can be
> checked, but that is inference, not proof. Pushing that value to Wrangler
> would invalidate live sessions if it is wrong — so it must never be pushed,
> and if stored in Infisical it must be labelled unverified rather than
> presented as system-of-record.
>
> Not catastrophic — the Discord pair can be regenerated — but they currently
> have **no readable backup anywhere**. Since Cloudflare is write-only,
> Infisical would be the only readable copy. Argues for widening Infisical's
> remit from "cross-boundary" to "every Worker secret".
>
> Also confirmed: `.dev.vars` MinIO values hash-match the **feature** service
> account, and its `POSTGREST_JWT_SECRET` matches the cluster's — local dev,
> cluster, and Infisical all agree today. No drift.

---

## Renovate

**Config at a glance**

| | |
|---|---|
| Runner | self-hosted `renovatebot/github-action`, daily cron `0 10 * * *` UTC (3 am PDT), plus `workflow_dispatch` and push-to-`main` on config changes |
| Presets | `.renovaterc.json5` extends `home-operations/renovate-presets#8.1.0` |
| Excluded | `ignorePaths: ["**/*.sops.*"]` — encrypted files are never scanned |
| Automerge | `.renovate/autoMerge.json5` — **minor/patch/digest automerge for everything; majors never**. Exceptions: `kubectl` (never), 0.x minors (never), GitHub Actions (`minimumReleaseAge: "3 days"`). `automergeType: pr` with **`platformAutomerge: true`**: every update gets a PR, Renovate hands it to GitHub's auto-merge, and GitHub merges it when the required checks go green — decoupled from Renovate's run schedule. `rebaseWhen: conflicted` so queued branches keep their green checks |
| Pre-merge gate | `.github/workflows/validate-manifests.yaml`, two jobs — **kustomize build** (all 21 Kustomizations + a `ks.yaml` `spec.path` check, offline) and **helm template** (all 6 HelmReleases rendered from their pinned chart versions, via `.github/scripts/render-charts.py`). On `pull_request` and pushes to `main`, **no `paths:` filter**, so a check always exists. Renovate waits for both (no `ignoreTests`) |
| Bounds | `.renovate/allowedVersions.json5` — Postgres `<=17`, kubectl `~1.35` |
| App | personal GitHub App `homelab-renovate`, **separate from** the org-owned `sunfire-renovate` — org Apps cannot be installed on personal repos, and minutes bill to `lambo-n`'s personal quota |

`image-reflector-controller` and `image-automation-controller` are **not** installed. They would
fight Renovate (both rewrite tags in git), require an `ImageRepository` + `ImagePolicy` per image
plus inline `# {"$imagepolicy": ...}` markers, and cover only container tags — not Helm charts,
GitHub Actions, mise tools, or OpenTofu providers.

Confirmed by the reference repo: zero `ImagePolicy` resources across 594 files.

Use the existing self-hosted `renovatebot/github-action`, extended with
[`home-operations/renovate-presets`](https://github.com/home-operations/renovate-presets), which
already parses Flux `HelmRelease` / `OCIRepository` / `Kustomization` files.

Also: **pin exact Helm chart versions.** A `HelmRelease` with a semver range (`version: "^15.0.0"`)
auto-upgrades at runtime with no git change — that's drift, and it defeats the point.

> **How a Renovate PR merges.** Automerge covers minor/patch/digest for everything and never majors; the carve-outs are `kubectl`, the GitHub Actions cooldown, and 0.x deps. For a 0.x dep the breaking boundary is the minor, but Renovate types `0.7.1 -> 0.8.0` as *minor*, so a `matchCurrentVersion: "/^0\\./"` rule pins those to manual. Every update is a PR (`automergeType: pr`): a branch automerge bypasses every `pull_request` trigger, and GitGuardian only posts a check on a PR, so secret scanning would never gate it. `platformAutomerge: true` hands the PR to GitHub, which merges it the moment the required checks go green. The `main-required-checks` ruleset requires **kustomize build**, **helm template** and **GitGuardian Security Checks**, and leaves *"require branches to be up to date"* **off**: turning it on would stall every PR behind a rebase. This depends on the Renovate App's "Commit statuses" read permission, and a red required check blocks the merge even for a human merging a major by hand.
>
> **What `validate-manifests` checks.** `.github/workflows/validate-manifests.yaml` builds every Kustomization with the mise-pinned `kubectl` and checks that every `ks.yaml` `spec.path` resolves. A second job runs `helm template` over every HelmRelease with the mise-pinned helm and each release's own `spec.values`, resolving the chart the way Flux does (`chartRef` → `OCIRepository` for most, `chart.spec` → `HelmRepository` for infisical). Script: `.github/scripts/render-charts.py`, which exits non-zero on the first chart that fails and prints helm's stderr. A `HelmRelease` points at an `OCIRepository` tag, so a version that doesn't exist, can't be pulled, or breaks against our values is one valid-looking string that `kustomize build` reads without complaint. Neither job talks to the cluster — no kubeconfig, no installed CRDs, no real `Capabilities.APIVersions` — so a chart that renders can still fail to apply, and **a minor chart bump can still roll a live workload, including CNPG's operator and the Postgres pod it manages.** Reconcile-time `wait: true` plus healthChecks stay the last line of defence.
>
> **The workflow has no `paths:` filter and runs on `pull_request` only, deliberately.** A Renovate branch that touches only `mise.toml`, `tofu/` or `.github/` would otherwise produce *no* check, and a commit with zero checks reads as `pending` in the status API: stuck, not unvalidated. A push trigger on `renovate/**` would double-bill every update, because Renovate opens the PR about two seconds after it pushes the branch.
>
> ⚠️ **With Renovate doing the merge, the OpenTofu lockfile PR can never merge.** Renovate's terraform manager regenerates `.terraform.lock.hcl` every run and reports it updated without diffing, which forces `reuseExistingBranch: false`, which force-pushes a byte-identical lock file, which restarts `validate-manifests`, which the same run then reads as pending. Letting GitHub hold the PR (`platformAutomerge: true`) is what avoids it.

> **`rebaseWhen: conflicted`, because the default caps automerge at one PR per run.** `rebaseWhen` defaults to `auto`, which Renovate resolves to `behind-base-branch` whenever automerge is enabled. Every automerge moves `main`, so each remaining automerge branch is a commit behind, gets rebased, and the force-push restarts `validate-manifests`, leaving its checks pending for the rest of the run. Under `conflicted` the branches hold still and keep their green checks. Separately, Renovate restarts the repository job exactly once per run (not configurable), which capped Renovate-side merging at two; `platformAutomerge: true` removes that ceiling because GitHub merges each PR as its own checks pass.
>
> The trade Renovate's docs name for `conflicted` — updates merging one after another without having been tested together — is the reconcile-time bet this repo makes everywhere else. The docs' other objection, that automerge stalls once a PR is out of date, applies only where the branch rule requires up-to-date PRs, which `main-required-checks` does not.

> **Charts are pinned by CHART version, never by app version.** Both CNPG charts
> move independently of the operator and plugin they install, and the chart is what
> Flux actually installs. The same holds for reloader (a `2.x` chart installing a
> `v1.x` app) and kube-prometheus-stack, whose chart major bears no relation to
> the prometheus-operator version it ships.

---

## CloudNativePG + plugin-barman-cloud

**Config at a glance**

| | |
|---|---|
| Cluster | `postgres-cnpg`, `instances: 1`, PostgreSQL **16.15**, database `sunfire` |
| PGDATA | 64 GiB zvol `archive-pool/vm-104-disk-0` on `k3s-worker2`, via `local-path` at `/var/lib/rancher/k3s/storage` |
| Services | `postgres-cnpg-rw` (what PostgREST reads), `-ro`, `-r` |
| Backups | `plugin-barman-cloud` → `ObjectStore` on local MinIO; continuous WAL archiving plus a daily `ScheduledBackup` (`postgres-daily`) |
| Bucket setup | `scripts/minio-barman-account.sh` created the bucket and its scoped account, which — unlike the Worker accounts — holds `s3:ListBucket`, because barman lists WALs and backups |
| Bootstrap | `initdb.import`, `type: monolith`, from `externalClusters: postgres-legacy` — read once at creation, never again |

Replaces the hand-rolled Deployment. Worth it for declarative rolling upgrades, pooler, and health
checks Flux can gate on — not only backups. Note barman-cloud is now a **separate plugin**
(`plugin-barman-cloud`), not built into `spec.backup`.

`instances: 1` — three replicas on one hypervisor is theater.

> ⚠️ **The plugin chart's CRD is templated, not shipped in `crds/`.** `objectstores.barmancloud.cnpg.io` is an ordinary template (`templates/crds/crds.yaml`, gated on `.Values.crds.create`, default true). A templated CRD is part of the release manifest and Helm upgrades it normally, so **the `crds: CreateReplace` policy that kube-prometheus-stack needs would be a no-op here** and must not be copied over; the HelmRelease says so inline, since the asymmetry between the two files otherwise reads as an oversight. The CRD carries `helm.sh/resource-policy: keep`, so uninstalling the plugin leaves it and every `ObjectStore` behind.

**Checking it**

| Command | Healthy |
|---|---|
| `kubectl -n sunfire get cluster postgres-cnpg` | `Cluster in healthy state`, `1/1` |
| `kubectl -n sunfire get cluster postgres-cnpg -o yaml` (conditions) | `Ready`, `ContinuousArchiving` and `LastBackupSucceeded` all `True` |
| `kubectl -n sunfire get backup` | one `postgres-daily-…` `Backup` per day, `completed` |

Those statuses can report success without a usable backup behind them, so the proof of recoverability is the restore drill in `runbooks/RESTORE.md`, not the conditions.

> ⚠️ **The CNPG bootstrap names a Service that does not exist.** `cluster.yaml` declares `externalClusters: postgres-legacy` at `postgres.sunfire.svc.cluster.local` and imports from it. That is read **once at cluster creation and never again**, so the live Cluster is unaffected. But deleting and recreating the Cluster from git — which is exactly what a naive "let Flux rebuild it" would do — would run the bootstrap against a hostname that doesn't resolve. **Rebuild from the barman backups instead**, the path with a passing restore drill behind it (`runbooks/RESTORE.md`). The legacy `deployment.yaml` and `service.yaml` exist only in git history, in the commit that removed them.
>
> ⚠️ **For any future database cutover, freeze writes on the source between the import and the repoint, or diff the two afterwards.** During the CNPG cutover both "live" signals looked healthy throughout, yet a row uploaded in the gap reached only the old database, and CNPG later reused its id for another upload.
>
**Off-site backup goes to Backblaze B2 with restic, monthly** (see *Off-site backup* below). Cloudflare R2 was ruled out by the owner. MinIO's two buckets are `sunfire-guide-media` and `sunfire-postgres-backups`. Local backups (sanoid, barman) all land in the same chassis, so the B2 copy is the only one that survives losing `.101`, and it trails by up to a month.

ZFS redundancy + SMART already solve **drive failure**. They do not solve accidental deletion,
a bad Flux prune, or logical corruption — RAIDZ replicates a `DELETE` to every disk instantly and
the pool still scrubs clean. That risk goes *up* when automated reconciliation with `prune: true`
arrives, but it's covered locally:

- **`sanoid` ZFS snapshots** on `.101` for `archive-pool/minio-data`. Copy-on-write, single-digit GB against the pool's 1.68 TiB. ~24 hourly / 30 daily / 6 monthly. They cover the accidental-delete case that ZFS redundancy does not.
- **CNPG → MinIO**, not R2. `endpointURL: http://minio.sunfire.svc.cluster.local:9000`, with ZFS
  snapshotting the dataset underneath. Barman stays local: it is the point-in-time path. The
  off-site copy is a separate, portable `pg_dump`, so a restore after host loss needs no barman.

Residual risk: host loss costs **up to a month** of changes (the B2 snapshot cadence), plus everything that is not in that copy: barman's history, sanoid snapshots, Home Assistant, Prometheus. Those were judged not worth off-siting.

> **VolSync is not used: the off-site copy is a plain restic CronJob.** VolSync would add a copy on *different media*, which needs a destination that is not `.101`, and the cluster has none:
>
> | Destination | Why not |
> |---|---|
> | MinIO itself (restic → `s3://…`) | The repository would live inside the volume being replicated. Circular |
> | A `local-path` PVC on a worker | Workers have a few GiB free, per the [worker-disk constraint](#k3s--storage-substrate) |
> | A second NFS PV or zvol on `archive-pool` | Same pool sanoid already snapshots. A second copy that dies with the first |
>
> There is also no CSI snapshot support (`local-path` and two manual NFS PVs; `volumesnapshotclass` is not even a resource type), so VolSync would be limited to `copyMethod: Direct` — reading a live MinIO data directory rather than a point-in-time image. The restic CronJob (below) sends to B2 and mirrors MinIO through the S3 API, so neither problem arises. `archive-pool/minio-data` gets sanoid, and it holds the Postgres backups too; that is the dataset that matters, and `SANOID.md` says so.

### Off-site backup: restic → Backblaze B2

A **monthly** copy of the database and the guide media, to **Backblaze B2** with **restic**. Cloudflare was ruled out by the owner. Monthly means host loss costs up to a month of changes, accepted because the data changes rarely. Typical sizes: guide media 85 MiB, one compressed base backup ~4 MiB, the live database 30 MB.

**Mechanism:** the `offsite-backup` CronJob in
`kubernetes/apps/sunfire/offsite-backup/`. It runs **every 6 hours** and does
real work only when the newest `monthly` snapshot in the B2 repository is 30+
days old. A job pinned to the 1st would silently skip any month the cluster
was powered off that day. The repository is the only record of the last run,
so rebuilding the cluster cannot reset the clock.

| | |
|---|---|
| Database | `pg_dump -Fc` of `sunfire` as its owner (`postgres-cnpg-app`). Portable: restores with plain `pg_restore`, with no barman and no MinIO. Roles are **not** included; they are in `cluster.yaml` (`managed.roles`) and `0002_grants.sql` |
| Media | `mc mirror` of `sunfire-guide-media` to plain files, using a **read-only** MinIO account (`scripts/minio-offsite-policy.json`) |
| Repository | `s3:https://<endpoint>/<bucket>/sunfire`, client-side encrypted by restic |
| Retention | `forget --keep-monthly 12 --prune`, then `restic check` on every real run |
| Secret | `offsite-backup`, SOPS: cluster-only, so not Infisical (AGENTS.md rule 7). Written by `scripts/offsite-backup-secret.sh`, which you run yourself |
| Not included | the barman bucket (local point-in-time recovery stays on MinIO), sanoid snapshots, Home Assistant |

⚠️ **The restic password is the single point of failure.** Without it, the B2
copy cannot be decrypted by anyone. It lives in the SOPS secret **and in
LastPass**. The second copy matters because the first is on the host this
backup exists to survive.

⚠️ **B2 buckets keep every version by default.** Set the bucket's lifecycle to
"Keep only the last version", or `restic prune` deletes nothing and the bucket
grows forever. It is the same trap as versioning on the barman bucket
(`scripts/minio-barman-account.sh`).

**Restore**: the standing drill and the host-gone procedure are in
[`runbooks/OFFSITE-RESTORE.md`](runbooks/OFFSITE-RESTORE.md). In short, from any machine with
restic and the password:

```bash
export RESTIC_REPOSITORY='s3:https://<endpoint>/<bucket>/sunfire'
export AWS_ACCESS_KEY_ID=<b2 key id>
read -rs AWS_SECRET_ACCESS_KEY; export AWS_SECRET_ACCESS_KEY
read -rs RESTIC_PASSWORD; export RESTIC_PASSWORD
restic snapshots --tag monthly
restic restore latest --tag monthly --target ./restore
# ./restore/postgres/sunfire.dump  -> pg_restore -d sunfire
# ./restore/media/                 -> mc mirror back into the bucket
```

Paths in the snapshot are **relative** (`/postgres`, `/media`), because the
job runs `cd /work/data` before `restic backup`, even though `restic
snapshots` lists them as `/work/data/…`. So `--include /postgres` works, and
`--include /work/data/postgres` silently restores 0 files.

**Checking it.** `restic check` reports no errors. Right after a snapshot, a manual run of the CronJob takes the `0d old: not due` path. The proof of recoverability is restoring `sunfire.dump` **from B2** into a throwaway `postgres:16.15`: `pg_restore` exits 0 and the row hashes match the live database.

**Force a run** (e.g. to test) with
`kubectl -n sunfire create job --from=cronjob/offsite-backup offsite-manual`.
It still skips if a snapshot is under 30 days old. To force past that, lower
`MAX_AGE_DAYS` temporarily.

---

## cert-manager

> **cert-manager is now a dependency, and that voids one earlier rejection.**
> CNPG deleted the in-tree `spec.backup.barmanObjectStore` in 1.28; this cluster
> would run 1.30, so `plugin-barman-cloud` is the only way to back the database
> up at all, and the plugin requires cert-manager for the operator↔plugin mTLS.
> "External Secrets Operator drags in cert-manager" therefore stops being an
> argument against ESO — that rejection now rests solely on 1Password needing a
> subscription. Nothing else in the cluster issues certificates; ingress TLS is
> terminated by Cloudflare at the edge.
>
> **Versions are pinned by *chart*, not by app version.** Both CNPG charts move
> independently of what they carry: `cloudnative-pg` 0.29.0 → operator 1.30.0,
> `plugin-barman-cloud` 0.7.1 → plugin v0.14.0 (upstream had tagged plugin
> v0.15.0 with no chart shipping it). The chart is what Flux installs. Also
> note cert-manager's chart defaults `crds.enabled` to **false** and templates
> the CRDs behind it, so accepting the default installs an operator with no API.

> **No `ClusterIssuer` exists in this cluster.** The only Issuer is the
> self-signed one the barman plugin owns, in `cnpg-system`. That is why
> kube-prometheus-stack uses the chart's own `kube-webhook-certgen` job for its
> admission webhook rather than `certManager.enabled: true`, and why Grafana is
> served over plain HTTP on the LAN rather than TLS.

---

## Reloader

**Config at a glance** — chart **2.2.18** (appVersion `v1.4.22`), own `reloader`
namespace, `watchGlobally: true` with `reloadStrategy: default`, no `dependsOn`.
Opt-in per workload via `reloader.stakater.com/auto: "true"`. CNPG is deliberately
**not** covered — the operator watches its own secrets through the `cnpg.io/reload`
label, and annotating anything CNPG owns would be two controllers reconciling one
rollout.

> **Reloader restarts a workload when a Secret it reads changes**, so a rotated Secret takes effect without a hand-rolled restart. A workload opts in with the annotation above. To test it, rotate a Secret read through `secretKeyRef` in a throwaway namespace *without touching the Deployment*: a new pod should serve the new value within about half a minute, and Reloader's log names it (`Changes detected in '…' of type 'SECRET' …; updated '…' of type 'Deployment' …`).
>
> ⚠️ **A manual `kubectl rollout restart` does not survive Flux.** The restart annotation lands on the pod *template*, which Flux owns via server-side apply, so the next reconcile strips it and rolls the Deployment back to the git spec, restarting the pod a second time. A hand-rolled restart is a temporary state under GitOps, not a fix.

> ⚠️ **A Secret change does not restart a pod on its own.** Env vars from `secretKeyRef` are read once at container start, so a rotated Secret can report success everywhere (Flux Ready, the new value in the Secret) while the pod keeps running on the old one. Reloader restarts opted-in workloads; for anything not opted in, check pod AGE, not Kustomization status.

---

## cloudflared

**Config at a glance**

| | |
|---|---|
| Tunnel | `sunfire-local`, `1ac59ce2-15bb-46df-967f-caa8b05881f7`, `config_src: local` |
| Created by | `scripts/cloudflared-new-local-tunnel.sh` — the tunnel object is **not** managed by OpenTofu, deliberately |
| Routing | `kubernetes/apps/sunfire/cloudflared/app/configmap.yaml`, reconciled by Flux |
| Routes | `minio-api.sunosrs.cc` → `minio:9000`, `db.sunosrs.cc` → `postgrest:3000`, catch-all `http_status:404` |
| Credentials | SOPS-encrypted `credentials.sops.yaml`; Reloader restarts the connector when it changes |
| DNS | two CNAMEs in `tofu/` |

> **The tunnel is locally managed.** A local `--config` file does not win over remote config on its own: given `ingress` rules and valid credentials, cloudflared connects, then takes its routing from the edge anyway and logs nothing about it. The deciding field is `config_src` on the tunnel object (`cloudflare` for the dashboard, `local` for YAML on the origin). It is set at the API, so no manifest in this repo can change it, and it is **immutable after creation**, which Cloudflare reports as `1002 Tunnel not found` — an error that points at a wrong id or a bad token and is neither. The configurations endpoint insists on rules even in the mode that ignores them (`source: "local"` with an empty config returns `1056`). So converting an existing tunnel is a **tunnel swap**: `scripts/cloudflared-new-local-tunnel.sh` creates `sunfire-local` with `config_src: "local"`, generates the secret, sends it once, pipes it into SOPS and never prints it.
>
> **Checking it:** the connector's startup log has **no `Updated to new configuration` line** — that is what a remotely-configured connector emits when the edge pushes its ingress map, and its absence is the only direct evidence that the file is what is being read. The real end-to-end test is the Worker itself (upload, fetch and delete against MinIO), because it holds the Access service token and is the only client able to traverse edge → Access → tunnel → origin.
>
> ⚠️ **A `403` from these hostnames is not a health check.** Cloudflare Access rejects at the edge *before* the tunnel — responses carry `cf-access-aud` and `server: cloudflare` with no origin fingerprint — so a `403` is returned whether the origin is healthy, broken, or absent. It only shows that DNS resolves and the edge is up.

---

## MinIO

*Settled 2026-09-02.* Production, feature and local dev share the
`sunfire-guide-media` bucket and the `public` Postgres schema. The
per-environment split (`sunfire-guide-media-feature` + `sunfire_feature`) is
retired.

Guide media is **content, not per-environment state** — the same image is served
whichever Worker asks for it, and all three environments reach it through the one
homelab tunnel regardless. The split bought isolation nothing could use, while
costing two buckets, two policies, two schemas and four secrets kept
byte-identical across the cluster and two Worker environments.

It was also actively wrong: `wrangler dev` runs with no `--env`, so local dev
took *production* vars while `.dev.vars` supplied *feature* credentials scoped to
the feature bucket — a guaranteed `AccessDenied`, masked only by the `.invalid`
endpoints.

**Two service accounts are kept**, against the same policy and the same bucket,
purely so a leaked feature/local key can be revoked without rotating production.

**Versioning is enabled** on `sunfire-guide-media`. Feature and local dev hold
`s3:DeleteObject` on what is the only copy of every guide image in MinIO.
Versioning makes an overwrite or delete recoverable; it is not a substitute for
backups — see *Off-site backup* above and [`SANOID.md`](SANOID.md).

> **Container gotchas when working on MinIO from a pod.** `kubectl cp` fails —
> the image has no `tar`, so pipe via `cat` on stdin. It also lacks `sed`, `grep`
> and `awk`. And `mc ls` / `mc stat` **cannot** verify the scoped policy, because
> that policy deliberately withholds `s3:ListBucket` — verify with put/get/delete
> instead. Full procedure in `sunfire/homelab/RUNBOOK.md`.

---

## PostgREST

> **`401` on an anonymous request is the correct answer, not a fault.**
> `0002_grants.sql` revokes `anon`, so both `/` (the OpenAPI spec) and any table
> route reject unauthenticated callers. The healthy end-to-end signal is an
> authenticated `HTTP 206` with a `Content-Range` header (`0-0/<row count>`).

> ⚠️ **`PGRST_DB_URI` is cluster-only and lives in SOPS.** Changing which database
> PostgREST reads needs no Cloudflare Worker change at all — the JWT signing key,
> `POSTGREST_URL`, the Access service token and every `MINIO_*` value are
> untouched by it. That is what made the CNPG cutover a one-side operation.

---

## transcribe-api

**Config at a glance** — own `transcribe` namespace, one Deployment
(`kubernetes/apps/transcribe/api/app/`), `LoadBalancer` Service on `:8000`
(klipper, every node IP — same mechanism as Traefik and Home Assistant).
No custom image: a stock `python:*-slim` (Renovate-tracked; see the pinned
digest in `deployment.yaml` rather than a version here) installs `ffmpeg` and
its Python deps (`fastapi`, `uvicorn`, `wyoming`) at container start. No
`dependsOn` — it only calls out to VM 105, nothing in-cluster.

`POST /transcribe` decodes the uploaded audio with `ffmpeg` and speaks the
Wyoming protocol to `wyoming-whisper:10300` on VM 105, the same STT backend
`voice/home-assistant` calls — reachable because the three k3s node IPs are
already `ufw`-allowed for that port (see `VOICE.md`), so this opens nothing
new on VM 105's firewall. `GET /transcribe.sh` serves the CLI client from the
same pod, so a LAN device fetches it with `curl -O` instead of it being
copied around by hand.

> ⚠️ **No auth, LAN-only, on purpose** — same posture as the rest of the
> voice stack. A device that isn't on the LAN relays through the dev VM's SSH
> access instead of the service being opened to the tailnet: see
> `scripts/transcribe-remote.sh`.

> ⚠️ **`whisper-server` serializes every request behind one GPU mutex**
> (`examples/server/server.cpp`, `whisper_mutex`), verified by reading the
> source and firing two concurrent requests. A long transcription here queues
> behind, or ahead of, a Doofus voice command on VM 105 — accepted as a rare,
> low-cost tradeoff rather than something to build a priority queue around.

**Checking it** — from any LAN device:

```bash
curl -F file=@some.mp3 http://192.168.50.104:8000/transcribe
```

A healthy response is `{"text": "..."}`. Any of the three node IPs work.

---

## searxng

**Config at a glance** — own `search` namespace, one Deployment
(`kubernetes/apps/search/searxng/app/`), `LoadBalancer` Service on `:8080`
(klipper, every node IP). The official `searxng/searxng` image (Renovate-tracked;
see the pinned digest in `deployment.yaml`), configured with a single
`settings.yml` ConfigMap that sets `use_default_settings: true` and overrides
only `instance_name`, `limiter: false` and `search.formats` (`html` + `json`).
The session key arrives as `SEARXNG_SECRET` from the SOPS-encrypted `searxng`
Secret. No `dependsOn` — nothing in-cluster depends on it yet.

It is the metasearch backend for the `web_search` tool the `llm` CLI on VM 105
calls (`scripts/llm/tools/tools.py`; `GPU-VM.md` → *Tool calling*, which also
covers `fetch_url`). `search.formats: json` is what that tool consumes; the
`html` format stays enabled so the instance is also usable from a browser
directly.

> ⚠️ **No auth, LAN-only, no redis.** Same posture as `transcribe-api` — a
> single caller (the LLM tool harness), not a public instance, so the request
> limiter that needs redis to back it is left off rather than standing up a
> redis deployment for one consumer.

> ⚠️ **The session key is a SOPS secret even though SearXNG has no login.** A
> committed `secret_key` is a plaintext secret in a public repo (GitGuardian
> flags it, and `AGENTS.md` rule 5 allows none), whatever it protects. It signs
> session cookies only, so `scripts/searxng-secret.sh --rotate` is cheap: it
> just invalidates cookies. The script is owner-run, like the other credential
> scripts, and `ks.yaml` carries the `decryption` block that lets Flux read it.

**Checking it** — from any LAN device:

```bash
curl 'http://192.168.50.104:8080/search?q=test&format=json'
```

A healthy response is a JSON body with a non-empty `results` array. Any of
the three node IPs work; the web UI is the same URL without `format=json`.

---

## kube-prometheus-stack

**Config at a glance**

| | |
|---|---|
| Chart | **92.2.0** (appVersion `v0.94.1`), `observability` namespace, no `dependsOn` |
| Prometheus | 60s scrape, `retention: 15d`, `retentionSize: 3GiB`, ~79,000 active series, pinned to **k3s-worker1** |
| Storage | `local-path` — TSDB 8Gi nominal, Grafana 2Gi, Alertmanager 1Gi, all on worker1 |
| Grafana | LAN-only Traefik Ingress, no host rule (reached by node IP alone); admin password in `grafana-admin.sops.yaml`; Reloader-annotated |
| Alerting | Alertmanager on the chart's `null` receiver. Flux alerts on two paths — a notification-controller `Provider`/`Alert`, and a `PrometheusRule` over `flux_resource_info` |
| Selectors | all four `*NilUsesHelmValues: false`, so monitors and rules are picked up from any namespace without a release label |

> **Alerting is in-cluster only, deliberately.** Alertmanager keeps the chart's default
> `null` receiver: alerts fire and are visible, and nothing is pushed anywhere. This
> cluster does not guarantee 100% uptime — `AGENTS.md` records that it is prone to
> infrequent power outages and is taken down by hand for maintenance — so a webhook would
> deliver a storm of `KubeNodeNotReady` / `TargetDown` / `KubePodNotReady` on every power
> cycle, which is how an alert channel becomes something nobody reads. The in-cluster
> destination also needs no secret and no internet egress at the moment of failure, which
> is worth something for an alert about the cluster being broken. **Add a receiver the
> day this cluster is expected to stay up**, not before.
>
> Alertmanager has no authentication of its own and so gets no Ingress; it is reached
> through Grafana's provisioned Alertmanager datasource, behind the one login that exists,
> or by port-forward. Don't declare that datasource explicitly: the chart already ships it whenever
> `alertmanager.enabled` is true, and a second same-named entry in one provisioning file is
> accepted silently — Grafana keeps one and the UI looks correct either way. Read the rendered
> ConfigMap to check.

> ⚠️ **The Flux alert every guide gives you does not work on Flux v2.9, and it fails
> silently**. Upstream's monitoring example, the Flux docs and every
> post derived from them alert on
> `gotk_reconcile_condition{type="Ready",status="False"}`. That metric does not exist.
> Verified at the source, against kustomize-controller's raw `/metrics`: the only `gotk_`
> families it exports are `gotk_reconcile_duration_seconds`, `gotk_event_http_*` and
> `gotk_token_cache*`. Neither `gotk_reconcile_condition` nor `gotk_suspend_status` is
> among them, and no flag turns them on — the controllers stopped exporting per-resource
> status gauges.
>
> The failure mode is the part worth keeping. A `PrometheusRule` over a metric that
> returns no series reports `health: ok, state: inactive` — indistinguishable, on every
> screen Prometheus offers, from a cluster where nothing is wrong. It had to be caught by
> asking Prometheus whether the *input* existed, which is not a thing anyone thinks to do
> to a rule that looks healthy. **The alert that tells you Flux is broken is the one most
> likely to be quietly broken itself**, which is the whole argument for the deliberate
> failure test recorded under [Phase 7](archive/GITOPS-MIGRATION.md#phase-7--observability--done-2026-09-04).
>
> Per-resource status now comes from **flux-operator**, not from Flux, as
> `flux_resource_info` — one series per object with `ready`, `suspended` and `reason` as
> labels, confirmed covering all eight kinds this cluster uses and updating within 30s in
> both directions. A consequence worth naming: these alerts now depend on flux-operator,
> which this file chose over `flux bootstrap` for unrelated reasons. Swapping the install
> method would blind them.
>
> The same defect is in upstream's `cluster.json` dashboard — `gotk_resource_info`, a
> `customresource_kind` label and `suspended="true"`, none of which exist. Patched with 26
> substitutions and every resulting query re-run against the live Prometheus (21
> Kustomizations/HelmReleases, 7 sources, 0 failing). **The patch is recorded in
> `flux-monitoring/app/kustomization.yaml`** so a refresh from upstream re-applies it
> rather than silently reverting to a blank dashboard. `control-plane.json` is verbatim;
> its `controller_runtime_*` and `workqueue_*` metrics are still exported.

> ⚠️ **k3s serves the apiserver's metrics on the kubelet endpoint, so Prometheus stored
> the control plane twice**. Without the drop below, the first run came in at **149,807
> active series**. At a 60s interval that is roughly 5.5 GiB over 15 days, so
> `retentionSize: 4GiB` would have quietly truncated `retention: 15d` to about ten — the
> two settings disagreeing, with only the enforced one telling the truth and nothing
> reporting the discrepancy.
>
> **43% of the entire TSDB was one duplicate.** k3s runs the whole control plane in a
> single process behind a single metrics registry, so scraping port 10250 on `k3s-control`
> returns the full apiserver, etcd and scheduler metric set on top of the kubelet's own —
> 64,638 of the kubelet job's 81,443 series, every one of them already collected by the
> `apiserver` job, stored again under a `job` label that made them look like kubelet
> metrics. Nothing about this is visible in a health signal: 26/26 targets up, no errors,
> Prometheus simply doing twice the work. A further 19,272 apiserver histogram series
> belonged to families no enabled rule or dashboard reads.
>
> Dropped via `metricRelabelings` on both ServiceMonitors: **65,810 series**, ~2.4 GiB at
> 15 days, so the retention promise and the size guard now agree. `apiserver_request_
> duration_seconds_bucket` and its `_sli` twin are deliberately kept — the
> `kubeApiserverBurnrate`/`Histogram`/`Slos` groups are built on them.
>
> **`retention: 15d` is the binding limit, not `retentionSize`.** Check: the oldest sample is about 15 days old (time retention drops whole blocks, so a little over), `prometheus_tsdb_time_retentions_total` increases and `prometheus_tsdb_size_retentions_total` stays **0**. The TSDB levels off near 2.5 GB with 60–78k head series, depending on pod churn. Measure through the apiserver service proxy, because the image is distroless (no `wget`, no `sh`).
>
> **`retentionSize` is 3GiB so that Prometheus's own cap sits under the node's eviction line** (kubelet hard eviction is `nodefs.available<5%`), and worker1's disk is 32 GB for the same reason.
>
> ⚠️ **`metricRelabelings` REPLACES the chart's list, it does not extend it.** Helm merges
> maps and replaces lists, so overriding the key silently discards the chart's own
> bucket-thinning rule. Both overrides repeat that first entry verbatim, and it has to be
> re-copied on a chart bump.

> **Storage: the TSDB is on `k3s-worker1`, and that placement is load-bearing.** Three
> constraints, in order:
>
> 1. **It cannot go on NFS.** Prometheus does not support non-POSIX filesystems, and NFS in
>    practice is one — mmap and file locking are exactly what a TSDB leans on. That rules
>    out `archive-pool`, the only redundant storage this cluster has, and leaves
>    `local-path`, which means a node's root disk.
> 2. **It must not share a filesystem with PGDATA.** `k3s-worker2`'s `local-path` directory
>    *is* the PGDATA zvol — `archive/STORAGE.md` §1–5 exists to make that true. `local-path`
>    provisions a directory, not a quota, so a runaway TSDB there would fill the database's
>    filesystem and undo exactly the separation that document was written to create.
>    Prometheus, Alertmanager and Grafana are therefore all pinned to `k3s-worker1`, whose
>    only tenant is MinIO — and MinIO's data is on NFS, so the worst case here is
>    DiskPressure on one node rather than a dead database.
> 3. **Worker1's root disk is 30.2 GiB and also holds the image store**, with ~14 GB free.
>    Hence `retentionSize`, the 60s scrape interval, and no Thanos. See the retention
>    note above.
>
> Note that per-PVC usage figures from the kubelet are meaningless here: `local-path` is a
> bind mount of a directory on the root filesystem, so every PVC on the node reports the
> whole filesystem's usage. The node-level number is the only real one.

> **k3s exposes no controller-manager, scheduler, kube-proxy or etcd metrics.** All four
> bind to `127.0.0.1`; verified by probing `.104` and `.105` — 10249, 10257, 10259 and 2381
> all closed from off-host. This is also a sqlite k3s, so there is no etcd at all. Their
> ServiceMonitors *and* their default rule groups are disabled: left on, they would sit
> permanently firing against metrics that never arrive, which is the ordinary way an alert
> console becomes furniture.

---

## sanoid (host)

**Config at a glance** — runs on the Proxmox host `.101`, not in the cluster.
**Four** datasets: `minio-data`, the PGDATA zvol
`vm-104-disk-0`, and `ts-ssh-records` on `archive-pool`, plus `sas-pool/data` on
`sas-pool`. Policy 24 hourly / 30 daily / 6 monthly, `sanoid.timer` active.
Procedure and the rollback drill: [`SANOID.md`](SANOID.md).

> **What `sanoid` does and does not cover.** It snapshots ZFS datasets across both
> `archive-pool` and `sas-pool`. **The k3s VMs are not covered**: their disks are
> on `local-lvm` (LVM-thin).
> VM-level recovery is Proxmox `vzdump` or the OpenTofu rebuild in Phase 6 — not
> this line item. Do not let a green sanoid dashboard read as "the cluster is
> backed up".
>
> **A snapshot of a live Postgres is crash-consistent, not a backup.** Rolling
> one back is equivalent to yanking power: Postgres will WAL-replay and usually
> come up, but that is not PITR and it will not survive logical corruption. That
> asymmetry is exactly why CNPG + `plugin-barman-cloud` is in this same phase and
> not deferred — sanoid protects the *volume*, barman protects the *database*.
> Neither one substitutes for the other.

---

## Tailscale (host)

**Config at a glance** — the `tailscale-gateway` LXC (CTID 100, `192.168.50.102`)
is the only homelab node on the tailnet; the other members are the owner's
laptop and home PC. It is host-level: neither Flux nor OpenTofu configures it,
and `tofu/proxmox/proxmox-container.tf` describes the container, not its Tailscale
state.

| | |
|---|---|
| Exit node | offered, `AllowedIPs` includes `0.0.0.0/0` and `::/0` |
| Subnet router | advertises **and has approved** `192.168.50.0/24` — `PrimaryRoutes: ["192.168.50.0/24"]` |
| Tailnet policy | [`tailscale/policy.hujson`](tailscale/policy.hujson) — grants below, default deny |
| SSH session logs | written by a daemon on the gateway, **not** Tailscale's recorder (the policy has no `recorder`), to `/var/log/ts-ssh-records` on the `/archive-pool/ts-ssh-records` bind mount (`archive/STORAGE.md:416-448`, `archive/SAS-RECLAIM.md`) |

**What the subnet route reaches.** Only what the policy grants, from
`autogroup:member`:

| Grant | For |
|---|---|
| gateway `100.75.44.72` `tcp:22` | the `ProxyJump` hop |
| `192.168.50.101` `tcp:8006` | Proxmox UI/API |
| `192.168.50.104` `tcp:80`, `tcp:8123` | Traefik (Grafana) and Home Assistant |
| `autogroup:internet` | the exit node |

Everything else through the route is denied: NFS, the k3s API, the LLM API,
SSH straight to a guest, and traffic between the laptop and the home PC.
`ProxyJump` to every host in `ssh-config` works, because the second hop is the
gateway's *own* LAN traffic, which grants do not govern. The `ssh` block is the
console default (check mode, `autogroup:self`).

> ⚠️ **The granted ports are a second way in, and they produce no session
> log.** The logs cover SSH through the gateway. A routed request to `:8006`
> or Traefik never opens an SSH session, so it is not recorded. The policy
> limits *where* a routed device can go, not whether that is logged.

> ⚠️ **The file is the record, not the source.** Nothing applies it. Edit
> `tailscale/policy.hujson` first, then paste the whole file into admin console
> → Access controls, and keep them identical. If a paste locks you out, paste
> `{"src": ["*"], "dst": ["*"], "ip": ["*"]}` back in as the only grant.

**Checking it**, from a tailnet device off the LAN with `--accept-routes`, as
fish-safe one-liners:

| Test | Expect |
|---|---|
| `ssh dev 'hostname'` | `dev` |
| `curl -skI https://192.168.50.101:8006/api2/json/version \| head -1` | any HTTP status (`501` — PVE refuses `HEAD`) |
| `curl -sI 192.168.50.104 \| head -1` | `302 Found` |
| `curl -s -m5 -o /dev/null -w '%{http_code}' http://192.168.50.107:8080/v1/models` | `000` |
| `curl -sk -m5 -o /dev/null -w '%{http_code}' https://192.168.50.104:6443/version` | `000` |

Read `000` as routing or policy and any HTTP status as reachable. A `401` or
`501` means TLS completed and PVE answered, so they are diagnosed in different
places. `tailscale status --json` → `PrimaryRoutes` on the gateway peer shows
whether the route itself is up.

**Handy consequence.** With `--accept-routes` on, the Proxmox API answers from
the laptop, so hardware enumeration for [`HARDWARE.md`](HARDWARE.md) does not
need the dev VM.

**What this does not cover.** `.101` accepts no SSH key from a laptop — only
one dedicated key from the dev VM, scoped to the Ansible host-config layer
(`ansible/README.md`; the Proxmox API token path is separate, see
`tofu/README.md` → *Proxmox*) — and the dev VM has no route to the *pool* —
NFS `2049`/`111` are not reachable from it (`tofu/proxmox/variables.tf`). Those facts don't
depend on the tailnet.

History (how the route was found, the allow-all policy it replaced, the
verification runs): [`archive/TAILSCALE-SUBNET-ROUTE.md`](archive/TAILSCALE-SUBNET-ROUTE.md).

---

## OpenTofu

**Config at a glance**

| | |
|---|---|
| Version | **1.13.1**, pinned in `mise.toml`. State lives on the dev VM and is backed up with it |
| Applies | run **by hand from the dev VM, never reconciled from inside the cluster** — see the [scope split](#scope-flux-manages-the-cluster-not-the-hypervisor) |
| Layout | two roots with separate state: `tofu/proxmox/` and `tofu/cloudflare/`. A plan in one needs no token for the other |
| Proxmox | `tofu/proxmox/proxmox-vms.tf` (dev, control, two workers) + `tofu/proxmox/proxmox-container.tf` (`tailscale-gateway`, CTID 100). All five carry `prevent_destroy`; every body generated from the live guest with `-generate-config-out`, then reviewed |
| Proxmox token | `tofu@pve`, **read-only** (`PVEAuditor`). `VM.Allocate` was never granted, at any point |
| Cloudflare | two resources only — `cloudflare_dns_record.minio_api` and `.db`. `tofu/cloudflare/cloudflare-tunnel.tf` is a comment block explaining why no tunnel object is managed |
| Detail | `tofu/README.md` |

> ⚠️ **`PVEAuditor` cannot import a QEMU guest, and the error names the wrong cause**
> Generation failed on every VM with
> `403 Permission check failed (/vms/102, VM.Config.Disk)`.
>
> The VM config itself reads fine — `GET /nodes/pve/qemu/102/config` returns
> `scsi0 = "local-lvm:vm-102-disk-0,iothread=1,size=15G"`, disk string and all. It is the
> *second* call that fails: bpg/proxmox re-resolves every volume through
> `GET /nodes/pve/storage/{store}/content/{volume}`, and PVE gates that endpoint on
> `VM.Config.Disk` — the privilege that permits **changing** disk configuration. The data
> is readable by a token that already has it; the provider asks for it by a route that
> requires write authority. "Read-only cannot read it" is not a contradiction, it is an
> authorization model that does not separate those two things at that endpoint.
>
> The LXC was unaffected — PVE gates container volume reads on `Datastore.Audit`, which
> `PVEAuditor` has — which is why one of five landed before the rest.
>
> **Resolved by a scoped, temporary grant rather than by weakening the rule.** A `TofuDisk`
> role holding *only* `VM.Config.Disk` was stacked on `PVEAuditor` for the generation and
> removed immediately after:
>
> ```
> pveum role add TofuDisk --privs VM.Config.Disk
> pveum acl modify / --users tofu@pve --roles PVEAuditor,TofuDisk
> ...generate, review, import...
> pveum acl delete / --users tofu@pve --roles TofuDisk
> ```
>
> Stacking a one-privilege role beats editing the base role: the revoke removes a narrow
> grant instead of re-asserting a broad one, and `/access/permissions` shows plainly
> whether it is in effect. Re-granting is needed only to regenerate a body — day-to-day
> `tofu plan -refresh=false` makes no Proxmox API call at all.
>
> `VM.Allocate` was never granted, at any point. Even mid-window, replacing a guest was not
> something this token could do.

> **Why the Proxmox token is read-only.** The whole point of this import is to get the
> guests *described* in code — it is not a step toward reconciling them. GITOPS.md already
> rejects a reconciler that can delete the VMs it runs on; a write-capable token sitting on
> this VM is a weaker version of the same hazard, since `.103` is itself one of the guests
> in state. The finding above was the first real bill for that choice, and it was paid
> deliberately and briefly rather than by permanently widening the token.

> **Generated bodies need editing before they validate.** Four attributes came out of
> `-generate-config-out` as empty or zero values for unset optionals and were then rejected
> by the provider's *own* validators: `affinity = ""`, `hugepages = ""`, `units = 0`, and
> `timeout_* ` (client-side patience Proxmox does not store, which otherwise produces a
> permanent phantom "update in-place"). The container added `entrypoint = ""`, rejected the
> same way, while `template_file_id = ""` looks identical and *cannot* be removed because
> the schema marks it required. Generation and validation disagreeing is a provider bug,
> not a fact about the hypervisor — delete the attribute and let the default stand.

> **Each provider has its own root module and state.** `tofu/cloudflare/` plans with a full
> refresh and needs only `CLOUDFLARE_API_TOKEN`; `tofu/proxmox/` needs only
> `PROXMOX_VE_API_TOKEN`. `-refresh=false` is still the everyday Proxmox command, because the
> read-only token cannot refresh the four imported VMs (above), not because of Cloudflare.

> `opentofu` is now pinned in `mise.toml` (1.12.6). Until this phase it is an
> unused pin — the layer-split table under "Scope" named OpenTofu as the VM
> lifecycle tool while nothing in the toolchain provided it, so the row described
> an intention rather than a capability. State lives on this VM and is backed up
> with it; **applies are run by hand from here, never reconciled from inside the
> cluster** — that is the whole point of the [rejection](#explicitly-rejected).

---

## mise

Reference repo uses it for env binding only:

```toml
[env]
KUBECONFIG = "{{config_root}}/kubeconfig"
SOPS_AGE_KEY_FILE = "{{config_root}}/age.key"
```

Also use `[tools]` to pin `kubectl`/`flux`/`helm`/`sops`/`age` — fixes the v1.30/v1.35 skew.
Renovate has a first-class `mise` manager (updates the *first* listed version per tool only).

---

> ⚠️ **Tool pins and `[env]` only apply inside this directory.** Running `sops`
> or `helm` from `~` or `/tmp` fails with *"No version is set for shim"*, and
> `SOPS_AGE_KEY_FILE` is unset there too. `cd ~/homelab` first.

---

## k3s / storage substrate

**Config at a glance**

| | |
|---|---|
| Pool | `archive-pool`: a 3-way mirror, 1.68 TiB (`pvesm status` on `.101`). The two drives the rebuild freed are `llm-pool` and a cold spare ([`HARDWARE.md`](HARDWARE.md)) |
| PGDATA | a 64 GiB **zvol** on `archive-pool`, attached to `k3s-worker2` as a virtual disk and mounted at `/var/lib/rancher/k3s/storage`, the path `local-path` provisions into |
| Other VM disks | `local-lvm` (a Dell BOSS-S2 pair of M.2 **SATA** SSDs), except VM 105's models disk on `llm-pool` |
| Worker root disks | the OS and the container image store only; no database data lands there |
| Zvol settings | `volblocksize=8K`, `compression=lz4`, `sync=standard` |
| Host-side procedure | [`archive/STORAGE.md`](archive/STORAGE.md) |

> ⚠️ **The zvol ties `archive-pool` to `k3s-worker2`.** Destroying, exporting or rebuilding `archive-pool` takes that VM's data disk with it, so pool work requires `k3s-worker2` stopped first. No other guest's disk is on ZFS except VM 105's models disk on `llm-pool`.

> **Why a zvol: not NFS, and not `local-path` on the root disk.** CNPG explicitly discourages NFS for PGDATA (fsync and locking semantics); a zvol is block storage, single-writer by construction, with no network filesystem in the path. `local-path` on the node's root disk would share a filesystem with the OS and the image store, and a bigger shared filesystem is the same absent boundary. On its own block device the device is the ceiling, and on `archive-pool` it sits on the redundant storage that exists for this: a 3-way mirror (two disks of fault tolerance) with sanoid snapshots of PGDATA, against one RAID1 pair and no snapshots on `local-lvm`.
>
> **`cluster.yaml`'s `storage:` is `64Gi`, matching the zvol, because `local-path` does not enforce the number it is given.** The PVC binds and reports its request while the real ceiling is whatever is free on the node (see the quota warning below). CNPG keeps unarchived WAL in PGDATA until the archiver drains it, and MinIO being unreachable is an expected state on a cluster that is frequently powered off, so WAL accumulating against a small ceiling is a path to plan for, not a tail risk. No CNPG setting bounds it without also throwing away recoverability; the fix is a real device.
>
> **Two costs.** PGDATA and its barman backups share a pool, where a `local-path` layout would have put them on different media. Both are on the same *host*, which dominates the risk, and the answer if separation ever matters is the off-host copy (*Off-site backup* above), not a different local disk. And pool work needs `k3s-worker2` stopped (above).
>
> **`volblocksize=8K`, set at creation and immutable afterwards.** Postgres pages are 8K; recent ZFS defaults to 16K, and the mismatch is permanent write amplification. Keep `compression=lz4`; leave `sync=standard` — never `sync=disabled` under a database.
>
> **`SANOID.md` lists the zvol and `archive-pool/minio-data` as the two live datasets.** `minio-data` carries both the guide media and every Postgres backup, so it is the one that matters most.

> ⚠️ **`local-path` provisions a directory, not a quota.** Every PVC on a node
> shares that node's filesystem, and the requested `storage:` figure is inert
> metadata — the same is true of the NFS PVs, where the real cap is the ZFS
> dataset quota. Two consequences already recorded elsewhere: PGDATA needed the
> zvol, and the Prometheus TSDB had to be pinned to the node
> that is *not* worker2. It also means per-PVC usage from the kubelet is
> meaningless — every PVC on a node reports the whole filesystem's usage, so the
> node-level number is the only real one.

---

## Migration history

The homelab was moved to GitOps in seven phases between 2026-09-02 and
2026-09-04. All seven are complete, and the findings each phase produced have
moved up into the tool sections above. The timeline itself, and the pre-GitOps
context it grew out of, are archived at
[`archive/GITOPS-MIGRATION.md`](archive/GITOPS-MIGRATION.md) — other documents
that say "see GITOPS.md Phase N" mean the tool section a phase number maps to
there.
