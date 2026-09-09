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

Three runbooks hold procedures that cannot run from inside the cluster:
[`STORAGE.md`](STORAGE.md) (PGDATA zvol, worker disk growth — on the Proxmox
host), [`SANOID.md`](SANOID.md) (ZFS snapshots, same host), and
[`RESTORE.md`](RESTORE.md) (the CNPG restore drill). `tofu/README.md` covers the
OpenTofu root module.

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
| kube-prometheus-stack | [↓](#kube-prometheus-stack) | The Flux alert every guide gives you queries a metric that no longer exists |
| sanoid (host) | [↓](#sanoid-host) | A snapshot of a live Postgres is crash-consistent, not a backup |
| Tailscale (host) | [↓](#tailscale-host) | The approved subnet route reaches the whole LAN, and nothing records it |
| OpenTofu | [↓](#opentofu) | `PVEAuditor` cannot import a QEMU guest, and the error lies about why |
| mise | [↓](#mise) | Shims must sit above the interactivity guard in `.bashrc` |
| k3s / storage substrate | [↓](#k3s--storage-substrate) | `local-path` provisions a directory, not a quota |

---

## Open items

Everything the phased migration left deliberately unfinished. Nothing here is
blocking; each entry says what it is waiting on.

### Waiting on a decision

- [ ] **Retire the legacy NFS PV/PVC** (`postgres-pvc` → `postgres-pv`, 100 GiB,
      `Retain`). Still bound, still holding the pre-cutover data. They live in
      `sunfire-storage` where prune is permanently disabled, so removing them is a
      manual act a git edit cannot do by accident. The clock is the decay note under
      [CloudNativePG](#cloudnativepg--plugin-barman-cloud): when rolling back would
      lose more than it saves, there is nothing left to keep them for.
- [ ] **Verify the 15-day retention projection** — due around **2026-09-19**. The
      figure is derived from 65,810 active series, not measured. Check that
      `retention: 15d` is what is actually happening rather than `retentionSize: 4GiB`
      truncating it; the whole point of that finding is that the two can disagree in
      silence. See [kube-prometheus-stack](#kube-prometheus-stack).
- [ ] **Decide what the `192.168.50.0/24` subnet route is allowed to reach**
      *(raised 2026-09-09)*. It is approved today, so tailnet membership alone
      grants layer-3 access to every port on the LAN — see
      [Tailscale](#tailscale-host). Three options: leave it (one operator, four
      devices, and the honest documentation now exists); restrict it with a
      Tailscale ACL so only named devices may use the route; or drop the route and
      go back to `ProxyJump` only, which costs the ability to reach `:8006` and
      Grafana without a jump host. **Not urgent** — this is the same "100% uptime
      is not guaranteed, nothing here is worth much" calculus as the rest of
      `README.md`'s operating assumptions. It is listed because it was undocumented,
      not because it is wrong.
- [ ] **Repoint `sunfire-postgrest`'s `dependsOn`** at `sunfire-postgres-cnpg`. It
      still names `sunfire-postgres`, which since 2026-09-04 holds only a Secret.
      Harmless — a secret-only Kustomization is always Ready — but the edge no longer
      means what it says.

### Blocked on a layer that does not exist yet

- [ ] **Pin `sanoid` in Ansible/host config.** It is host-level, not a Kubernetes
      object, so neither Flux nor OpenTofu reconciles it. Needs the host-config layer
      named in the [scope split](#scope-flux-manages-the-cluster-not-the-hypervisor).
- [ ] **Split the OpenTofu root module in two.** Both providers share one root, so a
      Proxmox-only plan still refreshes Cloudflare and dies without that token.
      `-refresh=false` is the workaround in use. See [OpenTofu](#opentofu).

### Backlog — not now

- [ ] kubeconform or [`flux-schema`](https://github.com/fluxcd/flux-schema) validation in CI
      *(my own recommendation — the reference repo does **not** do this)*
- [ ] Loki + Promtail for logs — the third Flux dashboard (`logs.json`) is deliberately not
      deployed because there is nothing to back it. Wants its own storage answer first:
      the TSDB argument in Phase 7 applies again, and worker1's root disk is already the
      constraint
- [ ] Talos Linux for the k3s nodes — the real endgame for declarative node config, but a rebuild
- [ ] Gateway API / Envoy Gateway instead of Traefik Ingress (CRDs already present)
- [ ] ~~External Secrets Operator~~ — superseded by the Infisical Operator for the cross-boundary class; SOPS keeps the cluster-only class


### Explicitly rejected

| Option | Why |
|---|---|
| Flux/Crossplane/tofu-controller for Proxmox | Circular dependency on a single host. Also dissolves a real boundary: the shim needs a Proxmox API token with `VM.Allocate` stored in-cluster, so cluster compromise would become hypervisor compromise — today the cluster cannot touch `.101` at all. **Revisit if** a second Proxmox node appears, *or* if a separate management cluster exists (k3s in an LXC on the host) so the reconciler no longer sits on its own substrate |
| Flux image automation controllers | Renovate is a strict superset; they'd conflict |
| R2 for backups | Original reason (shared 10 GB free tier) is void — app decommissioned. Still rejected: nothing here is worth off-siting yet. Revisit per successor app |
| CNPG `instances: 3` | False redundancy on one hypervisor |
| Cilium BGP / Multus | No network gear to peer with |
| `actions-runner-controller` | Another circular dependency on a single host |
| `HelmRelease` semver ranges | Runtime drift; git stops describing what's deployed |
| Per-environment Cloudflare Access service tokens | **Deliberate, decided 2026-09-02.** One `sunfire-worker` token is shared by the prod Worker, the feature Worker and local dev, per `ZEROTRUST.md`. Splitting it would allow revoking a leaked local/laptop token without taking production down — the same reasoning that keeps *two* MinIO service accounts one layer below. Rejected anyway: prod being down costs nothing and all stored data is non-critical, so the blast radius the split protects against is not worth the extra tokens to manage. **The asymmetry with MinIO is intentional — do not "fix" it.** Revisit only if this cluster ever stores something that matters |

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
- PVs are `Retain`, but a mislabeled prune deleting `postgres-pvc` / `minio-pvc` is the one thing
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

> **Push-to-apply drilled 2026-09-08.** A throwaway `gitops-canary` app — one
> `pause` pod in its own deliberately prunable namespace — was pushed to `main` and
> was Ready on the cluster in under a minute with no manual reconcile
> (`Applied revision: refs/heads/main@sha1:0e426d41`, pod 57s old before anything
> was forced). Reverting the commit pruned the Deployment *and* the namespace with
> no manual cleanup, which is the half that `prune: true` had never been shown to do
> for a whole app. Both commits stay in history: `0e426d4` and its revert `fd38c81`.
>
> `interval: 1m` was written into `flux-instance.yaml` after this drill. Until then
> the field was absent and the cluster ran on flux-operator's unstated default, which
> is why `README.md` had claimed the poll was 30m — that number is the app
> Kustomization interval, not the source's.

> **Adoption result.** The live cluster had been running four unpinned `:latest`
> tags; the repo carries digest pins, so adoption rolled all four Deployments —
> the Phase 1 pinning finally reaching the cluster. Verified after reconcile:
>
> - all four Deployments 1/1 Ready on the pinned digests
> - `postgres` took its intended patch upgrade **16 → 16.15**; the log shows a
>   clean `database system was shut down` → `ready to accept connections`, so the
>   NFS data directory replayed rather than reinitialised
> - `postgrest` reconnected and loaded its schema cache (1 relation)
> - `cloudflared` re-established the tunnel; all QUIC/TCP/API prechecks pass
> - **`minio-pv` / `postgres-pv` were not recreated** — both still carry their
>   original `07:05:44Z` creation timestamp, `Bound`, `Retain`
> - all five SOPS secrets decrypted in-cluster and applied
>
> **Prune enabled (2026-09-03).** `prune: true` on `sunfire-{minio,postgres,postgrest,cloudflared}`.
> `sunfire-storage` keeps `prune: false` permanently. Removing a manifest from
> git now deletes the live object.
>
> Before enabling, each Kustomization's inventory was dumped and matched against
> its git content — 6/2/4/3/3/4 objects, nothing unexpected adopted from the
> hand-applied era. That inventory check, not the reconcile count, is what makes
> this safe: prune only removes objects a Kustomization already owns and git no
> longer declares, so a correct inventory means enabling it is an immediate no-op.
>
> **Found while doing it:** the parent `flux-system` Kustomization was already
> running `prune: true` — flux-operator sets that on the sync Kustomization by
> default — and the `sunfire` Namespace sits in its inventory. Dropping
> `namespace.yaml` from git would therefore have deleted the namespace, and the
> Kubernetes garbage collector would have taken every object inside with it. The
> `prune: disabled` annotations on the PVCs do **not** stop that: they stop Flux,
> not the GC cascade. PVs are `Retain` so the data survives, but the claims would
> not. `namespace.yaml` now carries `prune: disabled` to close it. This hazard
> predated enabling prune on the app Kustomizations.

**Health checks and `dependsOn` are load-bearing.** A `healthCheck` naming an
object that no longer exists **fails** its Kustomization, and a failed
Kustomization blocks everything that `dependsOn` it. This bit on 2026-09-04 while
deleting the legacy `postgres` Deployment: the healthCheck had to be removed in
the same commit, or `sunfire-postgrest` and `sunfire-postgres-cnpg` would both
have wedged rather than the change failing locally. A zero-replica Deployment, by
contrast, *is* healthy — kstatus reports it Current, verified the same day.

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
| Operator | chart **0.11.8**, own `infisical` namespace, scoped to `sunfire` |
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

> ⚠️ **Correction (2026-09-02): Cloudflare Worker secrets are write-only.**
> `wrangler secret list` returns names and types only — never values. So
> "verify Wrangler byte-matches Infisical" cannot be done, and this plan
> previously assumed it could. The *only* way to guarantee the match is to
> re-push from Infisical to Wrangler, making Infisical canonical in fact
> rather than in principle. Until that push happens, Wrangler's copies are
> asserted equal, not verified equal.

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
| Automerge | `.renovate/autoMerge.json5` — **minor/patch/digest automerge for everything; majors never**. Exceptions: `kubectl` (never), 0.x minors (never), GitHub Actions (`minimumReleaseAge: "3 days"`). `automergeType: pr` with `platformAutomerge: false`: every update gets a PR and Renovate merges it once checks pass |
| Pre-merge gate | `.github/workflows/validate-manifests.yaml`, two jobs — **kustomize build** (all 21 Kustomizations + a `ks.yaml` `spec.path` check, offline) and **helm template** (all 6 HelmReleases rendered from their pinned chart versions, via `.github/scripts/render-charts.py`). On `pull_request` and `renovate/**` pushes, **no `paths:` filter**, so a check always exists. Renovate waits for both (no `ignoreTests`) |
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

> **Dry run passed 2026-09-03.** Daily cron (`0 10 * * *` UTC) will open the
> first real PRs on the next run. Workflow also triggers on push to `main`
> when Renovate config changes.

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
> a coin worth flipping. A 12s run on every push removes the question. The
> `renovate/**` push trigger is kept even under `pr` mode, since the branch is
> pushed before the PR exists.
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
> Two mechanical consequences of gating on a check read *during* a Renovate run:
> an update whose CI is still pending merges on the next run, so automerges can lag
> up to a day; and it depends on the App's "Commit statuses" read permission, the
> one missing from 2026-09-03 to 09-08. Branch protection would let GitHub merge on
> green instead, but it is not available for a private repo on this plan — which
> also means a red check does **not** block a human from merging a major by hand.
> It is information, not enforcement.

> **Pinned to what was running, not to latest.** Digests were read off the live
> pods (`.status.containerStatuses[].imageID`) and mapped back to version tags,
> so adoption is a no-op rather than a silent upgrade. `kubectl diff` against the
> cluster shows *only* the four image lines and the four prune annotations.

> **Charts are pinned by CHART version, never by app version.** Both CNPG charts
> move independently of the operator and plugin they install, and the chart is what
> Flux actually installs. The same holds for reloader (`2.2.16` → appVersion
> `v1.4.21`) and kube-prometheus-stack (`89.2.0` → appVersion `v0.93.1`).

---

## CloudNativePG + plugin-barman-cloud

**Config at a glance**

| | |
|---|---|
| Cluster | `postgres-cnpg`, `instances: 1`, PostgreSQL **16.15**, database `sunfire` |
| PGDATA | 64 GiB zvol `archive-pool/vm-104-disk-0` on `k3s-worker2`, via `local-path` at `/var/lib/rancher/k3s/storage` |
| Services | `postgres-cnpg-rw` (what PostgREST reads), `-ro`, `-r` |
| Backups | `plugin-barman-cloud` → `ObjectStore` on local MinIO; continuous WAL archiving plus a daily `ScheduledBackup` (`postgres-daily`) |
| Bucket setup | `scripts/minio-barman-account.sh` created the bucket and its scoped account |
| Bootstrap | `initdb.import`, `type: monolith`, from `externalClusters: postgres-legacy` — read once at creation, never again |

Replaces the hand-rolled Deployment. Worth it for declarative rolling upgrades, pooler, and health
checks Flux can gate on — not only backups. Note barman-cloud is now a **separate plugin**
(`plugin-barman-cloud`), not built into `spec.backup`.

`instances: 1` — three replicas on one hypervisor is theater.

> **Plugin chart 0.8.0 landed 2026-09-08, and its CRD is templated, not shipped in
> `crds/`.** Both 0.7.1 and 0.8.0 carry `objectstores.barmancloud.cnpg.io` as an
> ordinary template (`templates/crds/crds.yaml`, gated on `.Values.crds.create`,
> default true) — confirmed by pulling both charts from ghcr. That matters because
> a templated CRD is part of the release manifest and Helm upgrades it normally, so
> **the `crds: CreateReplace` policy that kube-prometheus-stack needs would be a
> no-op here** and must not be copied over. The HelmRelease says so inline, since
> the asymmetry between the two files otherwise reads as an oversight. The CRD also
> carries `helm.sh/resource-policy: keep`, so uninstalling the plugin leaves it and
> every `ObjectStore` behind.
>
> Verified after the upgrade: `plugin-barman-cloud.v2` reports `Helm upgrade
> succeeded`, the pod is 1/1, and the Cluster's `ContinuousArchiving` condition
> still carries its original `2026-09-04` `lastTransitionTime` — it never flipped,
> so WAL archiving did not break across the upgrade. `Ready` and
> `ConsistentSystemID` did re-transition at 18:19, i.e. the database was briefly
> not-Ready while the plugin rolled. A *base* backup under 0.8.0 had not yet run at
> that point; `LastBackupSucceeded` was still 02:30, from before.

> ✅ **CNPG is live and verified 2026-09-04.** Bootstrapped in 76 seconds from the
> live Deployment via `bootstrap.initdb.import` (monolith). Verified, not assumed:
>
> | Check | Result |
> |---|---|
> | Cluster phase | `Cluster in healthy state`, 1/1, primary `postgres-cnpg-1` |
> | Roles imported | all four, `authenticator` with `rolcanlogin=t rolinherit=f` |
> | Memberships | `authenticator → anon`, `authenticator → sunfire_readwrite` |
> | Table | `public.guide_media_assets`, owner `sunfire` |
> | PGDATA location | `/var/lib/rancher/k3s/storage/pvc-…` on `k3s-worker2` — **the zvol** |
> | WAL archiving | `archived_count=1`, `failed_count=0`, `ContinuousArchiving=True` |
> | Base backup | on-demand `Backup` completed; `LastBackupSucceeded=True` |
> | Objects in MinIO | `base/20260904T005414/{backup.info,data.tar.gz}` + 4 WAL segments |
>
> The kubelet's per-volume stats make the storage split visible: `pgdata` reports
> **62.44 GiB** capacity while the pod's other volumes report 17.83 GiB — the root
> disk. PGDATA genuinely is not sharing a filesystem with the OS.
>
> ⚠️ **This is not the cutover.** `PGRST_DB_URI` still names
> `postgres.sunfire.svc.cluster.local`, so PostgREST reads the *old* Deployment and
> the CNPG cluster sits idle apart from archiving. **Both databases are live and
> will now drift.** Repointing PostgREST at `postgres-cnpg-rw` is its own commit,
> and `RESTORE.md` should run before it — the drill is what proves the new stack is
> recoverable, and it is far cheaper to find a problem while the old Deployment is
> still authoritative.

> ⚠️ **The CNPG bootstrap still names the legacy Service, and that is not a live
> dependency — until it is.** `cluster.yaml` declares
> `externalClusters: postgres-legacy` at `postgres.sunfire.svc.cluster.local` and
> imports from it. That is read **once at cluster creation and never again**;
> `postgres-cnpg` is `Initialized`, so it will not reach for it. But deleting and
> recreating that Cluster from git — which is exactly what a naive "let Flux
> rebuild it" would do — would run the bootstrap against a hostname that no
> longer resolves, since the Service was deleted on 2026-09-04. **Rebuild from
> the barman backups instead**, which is the path with a passing restore drill
> behind it. Reviving the legacy source is now a git-history operation: recover
> `deployment.yaml` and `service.yaml` from the commit that removed them. The
> live Cluster is unaffected either way — verified `healthy` with the dangling
> reference in place.
>
> ⚠️ **The rollback value decays, so this is a soft deadline rather than none.**
> The legacy data is frozen at the 2026-09-04 cutover. Every write CNPG takes
> since makes rolling back to it a data-loss event rather than a recovery, and at
> some point the honest recovery path is the backups, not this. Near-zero today
> only because the new Worker does not exist yet. This is the clock the PV/PVC
> item above is waiting on — when rolling back would lose more than it saves,
> there is nothing left to keep them for.
>
> **Loose end, not urgent:** `sunfire-postgrest` still `dependsOn:
> sunfire-postgres`, which now resolves to a Kustomization holding one Secret.
> Harmless — it is always Ready — but the edge no longer means what it says.
> PostgREST's real dependency is `sunfire-postgres-cnpg`. Worth correcting the
> next time that file is touched, not on its own.

**R2 rejected** — but note the original reasoning is now void. It was: the 10 GB free tier is
shared with the production bingo app's buckets, so backups would push it toward billing. **That app
is decommissioned (2026-09-02)**; there is no shared budget and no gallery data to protect. Any
claim in this file that gallery pictures/videos live in MinIO is obsolete — MinIO has zero buckets.

The conclusion still stands, for a simpler reason: **there is currently nothing here worth backing
up off-site.** Revisit this properly when a successor app defines real data — at that point the
decision should be made on that data's value, not inherited from the bingo-era constraint.

ZFS redundancy + SMART already solve **drive failure**. They do not solve accidental deletion,
a bad Flux prune, or logical corruption — RAIDZ replicates a `DELETE` to every disk instantly and
the pool still scrubs clean. That risk goes *up* when automated reconciliation with `prune: true`
arrives, but it's covered locally:

- **`sanoid` ZFS snapshots** on `.101` for `archive-pool/minio-data` and `archive-pool/postgres-data`.
  Copy-on-write, single-digit GB against the pool's 1.68 TiB (measured post-rebuild). ~24 hourly / 30 daily
  / 6 monthly. **Set this up when the pool is recreated** — a fresh pool is the natural moment, and
  snapshots cover the accidental-delete case that ZFS redundancy does not.
- **CNPG → MinIO**, not R2. `endpointURL: http://minio.sunfire.svc.cluster.local:9000`, with ZFS
  snapshotting the dataset underneath. One-line change if offsite is ever wanted.

Accepted residual risk: host loss (PSU/HBA, pool corruption, fire/theft). Data is classified
non-essential archival; this is a deliberate decision, not an oversight. Cheap future options if
that changes: `zfs send` to an external USB drive rotated quarterly, or `syncoid` over Tailscale.

> **VolSync is deferred, not scheduled** *(2026-09-03)*. The line item read
> "VolSync for the MinIO PVC (only non-DB stateful volume)" and never said where
> the replica would go. Working that through, there is no answer on this cluster:
>
> | Destination | Why not |
> |---|---|
> | MinIO itself (restic → `s3://…`) | The repository would live inside the volume being replicated. Circular |
> | A `local-path` PVC on a worker | 2.7 GiB free, per the [worker-disk blocker](#k3s--storage-substrate) |
> | A second NFS PV or zvol on `archive-pool` | Same pool sanoid already snapshots. A second copy that dies with the first |
>
> The [PGDATA zvol decision](#k3s--storage-substrate) does not change this. It gives `archive-pool`
> a block-device path it did not have before, but VolSync's source here is
> MinIO's PV — which is already *on* `archive-pool`. A destination on the same
> pool replicates a volume onto itself at one remove.
>
> There is also no CSI snapshot support here (`local-path` and two manual NFS
> PVs; `volumesnapshotclass` is not even a resource type), so VolSync would be
> limited to `copyMethod: Direct` — reading a live MinIO data directory rather
> than a point-in-time image of it.
>
> What VolSync would genuinely add is a copy on *different media* in restic's
> file-level, verifiable format. That only becomes real when a destination exists
> that is not `.101` — which is the same condition already written into "Backups:
> local only": revisit when a successor app defines data whose value justifies
> going off-host. Until then this is machinery guarding a copy against nothing.
> `archive-pool/minio-data` gets sanoid, and after the CNPG cutover it holds the
> Postgres backups too — that is the dataset that matters, and `SANOID.md`
> already says so.

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

**Config at a glance** — chart **2.2.16** (appVersion `v1.4.21`), own `reloader`
namespace, `watchGlobally: true` with `reloadStrategy: default`, no `dependsOn`.
Opt-in per workload via `reloader.stakater.com/auto: "true"`. CNPG is deliberately
**not** covered — the operator watches its own secrets through the `cnpg.io/reload`
label, and annotating anything CNPG owns would be two controllers reconciling one
rollout.

> ✅ **Reloader deployed and proven 2026-09-04** (Phase 6, pulled forward). Not
> assumed to work — tested the same way the backups were. A throwaway
> `reloader-drill` namespace held a Deployment reading one value from a Secret
> via `secretKeyRef`. Rotating the Secret `v1` → `v2`, **without touching the
> Deployment at all**, produced a new pod serving `value=v2` in ~33 seconds, and
> Reloader's own log named it:
>
> ```
> Changes detected in 'probe' of type 'SECRET' in namespace 'reloader-drill';
> updated 'probe' of type 'Deployment' in namespace 'reloader-drill'
> ```
>
> Namespace torn down afterwards. All four sunfire Deployments now carry the
> annotation, so the gap below is closed going forward.
>
> **Second-order finding: a manual `kubectl rollout restart` does not survive
> Flux.** The restart annotation lands on the pod *template*, which Flux owns via
> server-side apply — so the next reconcile strips it and rolls the Deployment
> back to the git spec, restarting the pod a second time. Harmless here (the
> Secret change is what actually persisted, and PostgREST came back on
> `postgres-cnpg-rw` either way), but it means a hand-rolled restart is a
> temporary state under GitOps, not a fix. With Reloader in place there is no
> longer a reason to reach for one.

> ⚠️ **A Secret change does not restart the pod — the cutover silently no-opped
> at first** *(found 2026-09-04)*. After the `PGRST_DB_URI` commit, Flux reported
> `sunfire-postgrest` Ready at the new revision and the in-cluster Secret held the
> new host — but `kubectl get pods` showed the PostgREST pod still **84 minutes
> old**. Env vars from `secretKeyRef` are read once at container start, so
> PostgREST was still connected to the *old* database while every status signal
> said the cutover had landed. A `kubectl rollout restart` fixed it, and the logs
> then named `postgres-cnpg-rw` explicitly.
>
> This is the sharpest argument yet for **Reloader**, which sits in Phase 6 as a
> convenience item. It is not a convenience: without it, every future secret
> rotation — the JWT signing key, the MinIO Worker credentials, the tunnel token —
> reports success and changes nothing until someone notices. Worth promoting.
> Until it lands, treat "rolled a Secret" as an incomplete action: check pod AGE,
> not Kustomization status.
>
> Cutover verification, for the record: PostgREST logs name
> `postgres-cnpg-rw.sunfire.svc.cluster.local:5432` and load a schema cache of 1
> relation; the CNPG cluster shows `authenticator` connected from the PostgREST
> pod; and a signed request returns `HTTP 206` with `Content-Range: 0-0/57` while
> an anonymous one returns `401`.
>
> **No Cloudflare Worker maintenance was required**, as predicted:
> `PGRST_JWT_SECRET` was untouched (sha256 identical before and after), and
> `POSTGREST_URL`, `POSTGREST_SCHEMA`, the Access service token and every
> `MINIO_*` value are unaffected. `PGRST_DB_URI` is cluster-only; the Worker never
> sees it. No Wrangler push, no app redeploy.

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

> ✅ **Locally-managed tunnel, done 2026-09-04 — and it took a new tunnel.**
> `config_src` is **immutable after creation**, which Cloudflare reports as
> `1002 Tunnel not found`. That error points at a wrong id or a bad token and is
> neither; isolating it took three calls on one token against one tunnel:
> `GET` succeeds, `PATCH {"name":…}` succeeds, `PATCH {"config_src":"local"}`
> returns 1002. Writes are permitted; that field is not editable. The
> configurations endpoint refuses the other route too — `source: "local"` with an
> empty config returns `1056 … doesn't contain any ingress rules`, insisting on
> rules even in the mode that ignores them.
>
> So the conversion was a **tunnel swap**: `scripts/cloudflared-new-local-tunnel.sh`
> creates `sunfire-local` with `config_src: "local"`, generates the secret, sends
> it once, pipes it into SOPS and never prints it. Flux applied the new
> credentials and ConfigMap, **Reloader restarted the connector** (installed
> earlier the same day for exactly this), and one pre-staged `tofu apply` moved
> both CNAMEs. End state: new tunnel `local`/`healthy`/4 connections, old tunnel
> `down`/0 and kept as the rollback path — until the verification below passed,
> at which point it was deleted and `cloudflared-token` left the repo with it.
>
> ✅ **Verified end to end by the Worker 2026-09-04**: upload, fetch and delete
> against MinIO all work through the new tunnel. That is the test that counts,
> since the Worker holds the Access service token and is the only client able to
> traverse edge → Access → tunnel → origin. The old tunnel was deleted only
> after that passed.
>
> Proof it is genuinely local: the connector's startup log has **no
> `Updated to new configuration` line**. That line is what a remotely-configured
> connector emits when the edge pushes its ingress map, and its absence is the
> only direct evidence that the file is what is being read.
>
> ⚠️ **A `403` from these hostnames is not a health check.** Cloudflare Access
> rejects at the edge *before* the tunnel — responses carry `cf-access-aud` and
> `server: cloudflare` with no origin fingerprint — so a `403` is returned
> whether the origin is healthy, broken, or absent. This file and
> `sunfire/CUTOVER.md` both treat `403` as the healthy signal; it only ever
> demonstrated that DNS resolves and the edge is up. The honest end-to-end test
> is the Worker itself, since it holds the Access service token and is the only
> client that can traverse the whole path.

> ⚠️ **Local config does not beat remote config — `config_src` decides**
> *(found 2026-09-04)*. Converting cloudflared to local management is two
> changes, not one, and only the first is a Kubernetes change.
>
> The credential half went cleanly. The token decodes to `{a,t,s}`, which maps
> exactly onto `{AccountTag,TunnelID,TunnelSecret}` — so a `credentials.json`
> built from it runs the *same* tunnel, with no new tunnel, no DNS edit, no
> Access change and no Worker secret. `cloudflared-token` stays in git as the
> rollback path.
>
> The ingress half did not. Given a `--config` file containing `ingress` rules
> **and** a valid credentials file, cloudflared connects, then takes its routing
> from the edge anyway and logs nothing about it. The only tell is content: the
> config it logged carried `warp-routing`, which the local file does not. The
> deciding field is `config_src` on the tunnel object — `cloudflare` (dashboard)
> or `local` (YAML on the origin) — and it is set at the API, so no manifest in
> this repo can change it.
>
> Consequence for sequencing: **the ConfigMap is inert until `config_src`
> flips**, and it is worth flipping only with the local rules already verified,
> which they are (`ingress validate` → OK; `ingress rule` resolves both
> hostnames to the right services and everything else to the 404 catch-all).
> The tidiest way to do it is the OpenTofu module (see [OpenTofu](#opentofu)), whose
> `cloudflare_zero_trust_tunnel_cloudflared` resource takes `config_src` — that
> closes this item and the Cloudflare-clickops item together, rather than
> spending a manual dashboard action on it now.
>
> Verified unaffected throughout: both hostnames returned `HTTP 403` before and
> after (Access rejecting at the edge, which is the healthy signal — a broken
> origin map would be `502`/`1033`), and all four QUIC connections re-registered.

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
That also meant the conversion required **no Worker secret writes at all** — the
feature account is re-scoped by editing its policy, not by swapping credentials.

Done while both buckets and both schemas were empty and before tunnel cutover:
no data moved, and no application code changed (`MINIO_BUCKET` and
`POSTGREST_SCHEMA` were already config vars). This was the cheapest the change
could ever be; after cutover it would mean migrating live objects and rows.

**Versioning is enabled** on `sunfire-guide-media`. Feature and local dev hold
`s3:DeleteObject` on what is now the only copy of every guide image, and there
are still no backups (Phase 5). Versioning makes an overwrite or delete
recoverable; it is not a substitute for snapshots, and Phase 5 matters more now.

> ✅ **Cluster converted 2026-09-02**, all four steps applied and verified:
> feature service account re-scoped to `sunfire-guide-media/*` (policy edited,
> credential untouched — no Worker secret rotated); `PGRST_DB_SCHEMAS=public`
> (schema cache 2 relations → 1); `sunfire_feature` dropped via a guarded
> `DO` block that refuses on a non-empty table; feature bucket removed.
>
> End-to-end proof: the **feature** credential performs PutObject, GetObject
> (exact byte round-trip) and DeleteObject against `sunfire-guide-media`. Probe
> purged with `--versions --force`; bucket empty.
>
> Procedure retained in `sunfire/homelab/RUNBOOK.md` → "Unified media store —
> cluster conversion" for a rebuild. Two traps recorded there: `kubectl cp`
> fails on the MinIO pod (no `tar` — pipe via `cat` on stdin), and `mc ls`/`mc
> stat` **cannot** verify this policy because both need the deliberately-denied
> `s3:ListBucket` and return `Access Denied` for every bucket either way. Verify
> with put/get/delete, not with a listing.

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
> authenticated `HTTP 206` with `Content-Range: 0-0/57`, which is what the CNPG
> cutover was verified with on 2026-09-04.

> ⚠️ **`PGRST_DB_URI` is cluster-only and lives in SOPS.** Changing which database
> PostgREST reads needs no Cloudflare Worker change at all — the JWT signing key,
> `POSTGREST_URL`, the Access service token and every `MINIO_*` value are
> untouched by it. That is what made the CNPG cutover a one-side operation.

---

## kube-prometheus-stack

**Config at a glance**

| | |
|---|---|
| Chart | **89.2.0** (appVersion `v0.93.1`), `observability` namespace, no `dependsOn` |
| Prometheus | 60s scrape, `retention: 15d`, `retentionSize: 4GiB`, ~65,810 active series, pinned to **k3s-worker1** |
| Storage | `local-path` — TSDB 8Gi nominal, Grafana 2Gi, Alertmanager 1Gi, all on worker1 |
| Grafana | LAN-only Traefik Ingress at `grafana.homelab.lan`; admin password in `grafana-admin.sops.yaml`; Reloader-annotated |
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
> or by port-forward. An earlier revision declared that datasource explicitly and put two
> same-named entries in one provisioning file — the chart already ships it whenever
> `alertmanager.enabled` is true. Grafana kept one of them without complaining and the UI
> looked correct either way; found by reading the rendered ConfigMap.

> ⚠️ **The Flux alert every guide gives you does not work on Flux v2.9, and it fails
> silently** *(found 2026-09-04)*. Upstream's monitoring example, the Flux docs and every
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
> failure test recorded under [Phase 7](#phase-7--observability--done-2026-09-04).
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
> the control plane twice** *(found 2026-09-04)*. The first run came in at **149,807
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
>    *is* the PGDATA zvol — `STORAGE.md` §1–5 exists to make that true. `local-path`
>    provisions a directory, not a quota, so a runaway TSDB there would fill the database's
>    filesystem and undo exactly the separation that document was written to create.
>    Prometheus, Alertmanager and Grafana are therefore all pinned to `k3s-worker1`, whose
>    only tenant is MinIO — and MinIO's data is on NFS, so the worst case here is
>    DiskPressure on one node rather than a dead database.
> 3. **Worker1's root disk is 17.83 GiB and also holds the image store.** 9.65 GiB used /
>    7.31 GiB free after this phase. Hence `retentionSize`, the 60s scrape interval, and no
>    Thanos.
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
**Four** datasets: `minio-data`, `postgres-data`, the PGDATA zvol
`vm-104-disk-0`, and `ts-ssh-records` (added 2026-09-09). Policy 24 hourly / 30 daily / 6 monthly, `sanoid.timer` active.
Procedure and the rollback drill: [`SANOID.md`](SANOID.md).

> **What `sanoid` does and does not cover.** It snapshots ZFS datasets, and the
> only ZFS on `.101` is `archive-pool` — i.e. `archive-pool/minio-data`,
> `archive-pool/postgres-data`, the PGDATA zvol, and `archive-pool/ts-ssh-records`.
> **The k3s VMs are not covered**: their disks are on `local-lvm` (LVM-thin).
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
is the **only** tailnet member. It is host-level: neither Flux nor OpenTofu
configures it, and `tofu/proxmox-container.tf` describes the container, not its
Tailscale state. It provides two things:

| | |
|---|---|
| Exit node | offered, `AllowedIPs` includes `0.0.0.0/0` and `::/0` |
| Subnet router | advertises **and has approved** `192.168.50.0/24` — `PrimaryRoutes: ["192.168.50.0/24"]` |
| SSH session recording | `/var/log/ts-ssh-records`, on the `/archive-pool/ts-ssh-records` bind mount (`STORAGE.md:416-448`, `SAS-RECLAIM.md`) |

> ⚠️ **The subnet route is a second way in, and it is not the recorded one**
> *(found 2026-09-09)*. `README.md` asserted that administrative access "is
> SSH-mediated and recorded to `/var/log/ts-ssh-records`". That describes the
> `ProxyJump` path and nothing else. With `192.168.50.0/24` approved, any device
> on this tailnet running `tailscale set --accept-routes` gets **layer-3 reach to
> every port on every host on the LAN** — Proxmox `:8006`, the k3s API server,
> Traefik, NFS on `.101` — without opening an SSH session, and therefore without
> producing a session recording.
>
> Two things follow, and only the second is a real gap:
>
> 1. **The recordings are not weakened.** They still capture every SSH session
>    that happens. They were simply never a complete record of *access*, because
>    an L3 route is not an SSH session. The control does what it says; the
>    sentence in `README.md` claimed more than the control delivers.
> 2. **Nothing enforces the boundary at the network layer.** The route was
>    approved in the admin console; approval is per-route, and Tailscale ACLs —
>    which *could* restrict who may use it — are not in this repo and their
>    contents are unverified from here. So the honest statement is: reachability
>    is governed by tailnet membership, and tailnet membership is currently the
>    whole security model for LAN access.
>
> **How it was found.** Not by reading the docs — by a client failing to reach
> `.101` and `tailscale status` reporting *"Some peers are advertising routes but
> --accept-routes is false"*. The route had been approved for an unknown length
> of time and no document mentioned it. `tailscale status --json` is the check;
> `PrimaryRoutes` on a peer is the field that matters.

**The upside, which is real.** The route is why hardware enumeration for
[`HARDWARE.md`](HARDWARE.md) does not require sitting on the dev VM: with
`--accept-routes` on, the Proxmox API on `192.168.50.101:8006` answers from any
tailnet device. That does not widen anything — it uses a path that was already
open — but it is worth knowing before anyone plans a trip to a different machine.

**Verified 2026-09-09** from a laptop on the tailnet, off the LAN. The test is
the *shape* of the failure, not success: before `--accept-routes`, an
unauthenticated `GET /api2/json/version` returned HTTP `000` — no connection at
all. After, the same call returned **`401`**. A `401` means TLS completed and PVE
declined the credentials, so the route is up and the remaining problem is a
token. Treat `000` as routing and `401` as auth; they are diagnosed in different
places.

**What is not affected.** `.101` still accepts no SSH key from the dev VM or from
a laptop (`tofu/README.md:200`), and the dev VM still has no route to the *pool*
— NFS `2049`/`111` are not reachable from it (`variables.tf`). Those are separate
facts from the subnet route and remain true.

---

## OpenTofu

**Config at a glance**

| | |
|---|---|
| Version | **1.12.6**, pinned in `mise.toml`. State lives on the dev VM and is backed up with it |
| Applies | run **by hand from the dev VM, never reconciled from inside the cluster** — see the [scope split](#scope-flux-manages-the-cluster-not-the-hypervisor) |
| Proxmox | `tofu/proxmox-vms.tf` (dev, control, two workers) + `tofu/proxmox-container.tf` (`tailscale-gateway`, CTID 100). All five carry `prevent_destroy`; every body generated from the live guest with `-generate-config-out`, then reviewed |
| Proxmox token | `tofu@pve`, **read-only** (`PVEAuditor`). `VM.Allocate` was never granted, at any point |
| Cloudflare | two resources only — `cloudflare_dns_record.minio_api` and `.db`. `tofu/cloudflare-tunnel.tf` is a comment block explaining why no tunnel object is managed |
| Detail | `tofu/README.md` |

> ⚠️ **`PVEAuditor` cannot import a QEMU guest, and the error names the wrong cause**
> *(found 2026-09-04)*. Generation failed on every VM with
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

> **Both providers share one root module, so every plan wants both tokens.** A Proxmox-only
> plan still refreshes the two Cloudflare DNS records and dies on
> `9106 Missing X-Auth-Key, X-Auth-Email or Authorization headers`. `-refresh=false` is the
> workaround and is written into the runbook; separate root modules with separate state is
> the fix, and has not been done.

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
> `SOPS_AGE_KEY_FILE` is unset there too. `cd ~/homelab` first. Hit twice on
> 2026-09-04.

---

## k3s / storage substrate

> Figures refreshed 2026-09-03 from `pvesm status` on `.101`. The pool rebuild in
> `POOL-DOWNSIZE.md` is **complete**: 5 × 1.92 TB raidz2 (5.03 TiB) became a
> 3-way mirror (1.68 TiB), freeing two drives. Earlier revisions of this table
> read "~14 TB, ZFS w/ redundancy", then "8.72 TiB raw / 5.03 TiB usable" — both
> are now historical.
>
> ⚠️ **The "no VM disk is on ZFS" invariant is being retired deliberately.**
> It appears in this file, `HOMELAB.md`, `POOL-DOWNSIZE.md` §1 and the
> assistant's stored memory, always as the reason `archive-pool` could be
> destroyed without touching a VM. Phase 5 puts PGDATA on a **zvol** on that
> pool, so from that point on: destroying, exporting or rebuilding
> `archive-pool` takes `k3s-worker2`'s data disk with it, and pool work requires
> the VM stopped first. Nothing else changes — the other four guests stay on
> `local-lvm`.

> ✅ **Blocker found and cleared 2026-09-03: the worker root disks were 9.75 GiB.**
> Phase 5's original decision — move PGDATA onto `local-path` — quietly assumed
> the k3s nodes had room for it. They did not. Measured from the kubelet
> (`/api/v1/nodes/<node>/proxy/stats/summary`):
>
> | Node | Root fs | Used | Available | After `lvextend` |
> |---|---|---|---|---|
> | `k3s-control` | 9.75 GiB | 4.45 | 4.78 | *not yet grown* |
> | `k3s-worker1` (minio) | 9.75 GiB | 6.51 | 2.72 | **17.83 GiB, 10.45 free** |
> | `k3s-worker2` (postgres) | 9.75 GiB | 6.54 | **2.69** | **17.83 GiB, 10.42 free** |
>
> The cause was the stock Ubuntu Server installer: an 18.22 GiB VG on `sda3`
> with only a 10 GiB root LV carved out of it. No Proxmox resize and no
> thin-pool space were needed — `lvextend -l +100%FREE` plus `resize2fs`, online,
> on each worker. `STORAGE.md` §6 records it.
>
> Note `.status.allocatable.ephemeral-storage` still reports the pre-growth
> figure afterwards: kubelet caches it from cadvisor machine info and refreshes
> on restart. Eviction and `DiskPressure` use the live stats and were correct
> immediately, so this is cosmetic unless a pod declares an explicit
> `ephemeral-storage` request. Nothing here does.
>
> This did **not** make `local-path` on the root disk an acceptable home for
> PGDATA — a bigger shared filesystem is the same absent boundary. The zvol
> decision below stands on its own reasoning.
>
> `cluster.yaml` originally asked for `storage: 20Gi` on `k3s-worker2`.
> **local-path does not enforce that number** — it provisions a directory, not a
> quota — so the PVC binds, reports 20Gi, and the real ceiling is 2.69 GiB shared
> with the OS and the container images. Nothing fails at apply time. The database
> is empty today, so bootstrap would *succeed*, and the misconfiguration would
> surface later as node-level `DiskPressure` on the node running Postgres,
> PostgREST and the kubelet's image store.
>
> The WAL case is what makes this urgent rather than untidy. CNPG keeps
> unarchived WAL in PGDATA until the archiver drains it, and this cluster does not
> guarantee 100% uptime — power outages and by-hand maintenance both take it down,
> so MinIO being unreachable is an expected state rather than an exception, and WAL
> accumulating against a 2.69 GiB ceiling is a path to plan for, not a tail risk.
> There is no CNPG knob that bounds it without also throwing away recoverability;
> the fix is a real device.
>
> ✅ **Resolved by the zvol decision below, not by growing the root disk.**
> Growing the root disk would have left the database sharing a filesystem with
> the OS and the image store — a bigger disk, same absent boundary. Putting
> PGDATA on its own block device makes the device the ceiling, and putting that
> device on `archive-pool` puts it on the storage that exists for exactly this.
> `storage:` is now `64Gi`, matching the zvol, so the manifest states a number
> something actually enforces. The root disks still grow to ~24 GiB, for
> container-image churn only. Host-side procedure: `STORAGE.md`.
>
> One thing this does *not* invalidate: the manifests are correct. All three
> objects pass
> `kubectl apply --dry-run=server` against the live CRDs, the `dependsOn` targets
> all exist, `sunfire/role: postgres` is on `k3s-worker2`, and the SOPS
> `authenticator` password was confirmed byte-identical to the one embedded in
> the live `PGRST_DB_URI`. The design is sound; the substrate was never sized
> for it.

> **PGDATA moves off NFS onto a zvol on `archive-pool`** *(decided 2026-09-03;
> supersedes the `local-path` decision taken earlier the same day)*. The old
> Deployment kept its data directory on `.101:/archive-pool` over **NFS**. The
> CNPG Cluster keeps it on the same pool, but as a **block device**: a zvol
> attached to `k3s-worker2` as a virtual disk and mounted at
> `/var/lib/rancher/k3s/storage`, the path `local-path` already provisions into.
>
> **What the earlier decision got wrong.** It ranked "retires the single-writer
> NFS hazard" as the first and heaviest reason to abandon the pool. That is not
> what happened on 2026-09-02. Commit `6d51959` records the actual cause:
> `maxUnavailable` of 25% rounds down to 0 on `replicas: 1`, so Kubernetes
> started the replacement pod before stopping the old one and both mounted the
> same directory. That is **RollingUpdate on a ReadWriteMany volume** — it would
> occur on any RWX backend and has nothing to do with NFS semantics. It was
> already fixed by `strategy: Recreate` in that same commit, and CNPG does not
> use a Deployment at all, so it cannot recur under CNPG regardless of storage.
> The argument was retired twice over before it was written down.
>
> What survives is the second reason — **CNPG explicitly discourages NFS for
> PGDATA** (fsync and locking semantics). That is an objection to *NFS*, not to
> *archive-pool*, and a zvol answers it: it is block storage, single-writer by
> construction, with no network filesystem in the path.
>
> | | `local-path` on `local-lvm` | **zvol on `archive-pool`** |
> |---|---|---|
> | CNPG's NFS objection | avoided | avoided — block, not NFS |
> | Space | 90.5 GiB, shared with all five guests | **1.68 TiB, 0.01% used** |
> | Fault tolerance | RAID1, one disk | 3-way mirror, **two disks** |
> | sanoid snapshots of PGDATA | **none** | **yes** |
> | Enforced ceiling | the device | the device |
> | Kubernetes changes | none | none |
>
> The snapshot row carries the most weight. The `local-path` version explicitly
> accepted "losing `k3s-worker2` means restore-from-backup, not a snapshot
> rollback" as a cost; on a zvol that cost simply does not arise, and `SANOID.md`
> stops having a hole where the database used to be.
>
> **Three costs, stated plainly.** *(1)* It retires the "no VM disk is on ZFS"
> invariant — see the warning under "Current State"; pool work now requires
> `k3s-worker2` stopped. *(2)* ~~SATA SSD mirror instead of NVMe, so higher fsync
> latency.~~ **Withdrawn 2026-09-09: this cost does not exist.** `local-lvm` is
> not NVMe — it is a Dell BOSS-S2 pair of M.2 **SATA** SSDs (`HARDWARE.md`), so
> both sides of this comparison are SATA and the fsync trade is a wash. The
> claim was inherited from `README.md`, which asserted NVMe until the devices
> were enumerated. *(3)* PGDATA and its barman
> backups now share a pool, where the `local-path` plan had them on different
> media. Both were always on the same *host*, which dominates the risk — but the
> separation is genuinely reduced, and the answer if that ever matters is the
> off-host option already named under "Backups: local only", not a different
> local disk.
>
> **`volblocksize=8K`, set at creation and immutable afterwards.** Postgres pages
> are 8K; recent ZFS defaults to 16K, and the mismatch is permanent write
> amplification. Keep `compression=lz4`; leave `sync=standard` — never
> `sync=disabled` under a database.
>
> Consequence for `SANOID.md`: `archive-pool/postgres-data` (the NFS dataset) is
> the **legacy** rollback path and stops changing at cutover, while the new zvol
> and `archive-pool/minio-data` are the two live datasets. `minio-data` still
> carries both the guide media and every Postgres backup, so it remains the one
> that matters most.
>
> The worker root filesystems are still growing 9.75 → ~24 GiB, but for
> **container-image churn only** — 6.5 of 9.75 GiB is already used. No database
> data lands there. See `STORAGE.md`.

> **Three steps are yours, not the assistant's** *(was two; the disk grow is
> new)*. `kubectl exec` against a pod is
> refused by this environment's tooling, and `.101` has no SSH key for the dev
> VM. So: `scripts/minio-barman-account.sh` (creates the backup bucket and a
> service account scoped to it, and writes the credential into the repo already
> SOPS-encrypted — the keys are generated in the pod, piped into `sops`, and
> never printed), and `SANOID.md` in full. The barman account deliberately
> **does** hold `s3:ListBucket`, unlike the Worker accounts one layer down —
> barman needs to list WALs and backups. Same reasoning, opposite answer; it is
> not a copy-paste slip.
>
> The third is **`STORAGE.md`** — creating the PGDATA zvol on `archive-pool`,
> attaching it to `k3s-worker2`, and growing the three root disks for image
> churn. Proxmox has no Kubernetes API to reach it through, and the zvol now
> gates the CNPG cutover. `RESTORE.md` is likewise yours to execute end to end;
> it is written and blocked on the same volume, since a restore drill needs a
> second PGDATA alongside the live one.

> ⚠️ **`local-path` provisions a directory, not a quota.** Every PVC on a node
> shares that node's filesystem, and the requested `storage:` figure is inert
> metadata — the same is true of the NFS PVs, where the real cap is the ZFS
> dataset quota. Two consequences already recorded elsewhere: PGDATA needed the
> zvol and its three guards, and the Prometheus TSDB had to be pinned to the node
> that is *not* worker2. It also means per-PVC usage from the kubelet is
> meaningless — every PVC on a node reports the whole filesystem's usage, so the
> node-level number is the only real one.

---

## Migration history

The homelab was moved to GitOps in seven phases between **2026-09-02 and
2026-09-04**. All seven are complete, and the "Known gaps" list they were written
against is fully closed.

These headings are kept because other documents link to them by number —
`STORAGE.md`, `SANOID.md`, `RESTORE.md`, `tofu/README.md` and three files in the
separate `~/sunfire/` repo all say *"see GITOPS.md Phase N"*. The findings each
phase produced have moved up into the tool sections above; what remains here is
the timeline and what was verified when.

### Phase 1 — Prerequisites ✅ *done 2026-09-02*

mise installed and pinning `kubectl`/`flux2`/`helm`/`sops`/`age`; all four
workload images moved off `:latest` onto `tag@sha256:digest`, resolved from the
digests **actually running** so adoption upgraded nothing by accident. The one
real change was `postgres:16` → `16.15`, because the running pod sat on an older
now-untagged 16.x. → [Renovate](#renovate), [mise](#mise)

### Phase 2 — Secrets ✅ *done 2026-09-02*

All five secrets encrypted as `*.sops.yaml` with age; `.gitignore` set to refuse a
bare `secret.yaml` outright; `age.key` backed up to LastPass. One item deferred to
Phase 3 (the in-cluster `sops-age` Secret, which needs Flux to exist).
→ [SOPS + age](#sops--age)

### Phase 2b — Infisical ✅ *done 2026-09-04*

Cross-boundary secrets (`PGRST_JWT_SECRET`, four scoped MinIO Worker keys) moved
to Infisical as system of record, with the Infisical Operator reconciling them
into the cluster. `minio-worker-credentials` — a Secret no Deployment referenced,
sitting in the cluster purely as a filing cabinet — was moved and deleted, all
four values sha256-matched. → [Infisical](#infisical)

### Phase 3 — Flux ✅ *done 2026-09-02*

`flux-operator` + a `FluxInstance` running four controllers, syncing
`kubernetes/flux/cluster` over SSH with a read-only deploy key. The live cluster
was **adopted**, not recreated: the NFS PVs were taken over in place. `prune: true`
followed on 2026-09-03 after clean reconciles. → [Flux](#flux--flux-operator)

### Phase 4 — Renovate ✅ *done 2026-09-03*

Self-hosted `renovatebot/github-action` on a daily cron, extended with
`home-operations/renovate-presets` so it parses `HelmRelease`, `OCIRepository` and
`Kustomization` files. `**/*.sops.*` excluded from scanning.
→ [Renovate](#renovate)

### Phase 5 — Data protection ✅ *done 2026-09-04*

The largest phase. PostgreSQL became a CNPG `Cluster` with PGDATA on a 64 GiB zvol
on `archive-pool`; WAL archived continuously plus a daily base backup into MinIO
via `plugin-barman-cloud`; `sanoid` snapshotting all three ZFS datasets on `.101`.
cert-manager and Reloader were both pulled in as dependencies discovered along the
way.

**Two things were tested rather than assumed, which is the point of the phase:**

- **Restore drill** (`RESTORE.md`) — recovered into a scratch namespace in 56s,
  row counts matched exactly, `authenticator`'s SCRAM hash fingerprint was
  identical to the source, and PITR landed *between* two marker writes rather than
  merely somewhere after the base backup. Wrote nothing to the backup bucket and
  left no orphans.
- **Snapshot rollback** (`SANOID.md` §4) — both clone tests passed. The zvol clone
  returned the same filesystem UUID it was created with, and the `minio-data` clone
  contained the Postgres backups as well as the guide media.

PostgREST was cut over to `postgres-cnpg-rw` afterwards and verified end to end
(`HTTP 206`, `Content-Range: 0-0/57`; `401` anonymous), with no Cloudflare Worker
change required. The legacy `postgres` Deployment was retired later the same day —
scaled to zero, then deleted and pruned, at 0 PostgREST restarts.
→ [CloudNativePG](#cloudnativepg--plugin-barman-cloud), [sanoid](#sanoid-host),
[k3s / storage substrate](#k3s--storage-substrate)

### Phase 6 — Close the clickops gaps ✅ *done 2026-09-04*

Everything that lived in a web dashboard rather than in git. The cloudflared tunnel
became **locally managed** — which required minting a new tunnel, because
`config_src` is immutable after creation. Reloader was deployed. All five Proxmox
guests were imported into OpenTofu state without recreation, `0 to change, 0 to
destroy`, every body generated from the live guest and reviewed rather than
hand-written. The MinIO CORS Transform Rule was resolved by **deleting the
question**: it is vestigial, because no browser ever addresses
`minio-api.sunosrs.cc`. → [cloudflared](#cloudflared), [OpenTofu](#opentofu)

### Phase 7 — Observability ✅ *done 2026-09-04*

kube-prometheus-stack in an `observability` namespace — 26/26 targets up, 222/222
rules healthy — plus Flux reconcile-failure alerting on two independent paths, and
Flux's own Grafana dashboards. Closed the last entry in "Known gaps".

Verified by **causing a failure**: a Kustomization pointed at a nonexistent path
produced `FluxKustomizationArtifactfailed` in Alertmanager within seconds, and put
`FluxReconciliationFailure` into `pending` on the same event. That test is what
surfaced two faults that every health signal called healthy — see
[kube-prometheus-stack](#kube-prometheus-stack).

---

## Context that predates the migration

> **The Sun Clan Bingo app is decommissioned (2026-09-02)**, but MinIO and
> PostgreSQL are being **kept** for a new Cloudflare Worker, rebranded `bingo`
> → `sunfire`. Namespaces cannot be renamed, so the namespace is deleted and
> recreated; node labels, the Postgres database, its owner, and
> `bingo_readwrite` → `sunfire_readwrite` move with it. Sequence:
> `POOL-DOWNSIZE.md` §3/§5. Tunnel/zone swap: `sunfire/CUTOVER.md` and `sunfire/homelab/RUNBOOK.md`.
>
> **Ordering note for Phase 3.** These four Deployments are currently empty
> shells — zero buckets, zero tables. Porting them to Flux as-is has little
> value; standing the *new Worker's* stack up under Flux from day one has a lot.
> Prefer the latter ordering, and treat the `sunfire` rebuild as the natural
> moment to do it — the manifests are being rewritten anyway.

> **Repository separation** *(settled 2026-09-02)*: three sibling trees under `/home/dev`, never nested.
>
> | Path | Repo | Role |
> |---|---|---|
> | `~/homelab/` | `lambo-n/homelab` (private) | GitOps source of truth — this plan, executable |
> | `~/sunfire/` | `Sunfire-Team/sunfire` | Consuming app; cloned **for model context only**, read-only here |
> | `~/sunfire-backend/` | untracked, `chmod 600` | Pre-GitOps hand-applied manifests + plaintext secrets; rollback path |
>
> **Do not `git init` in `/home/dev` itself** — it would swallow the `~/sunfire/`
> clone, `~/.ssh`, and `~/.claude.json`. Keeping `~/sunfire/` a sibling means the
> app repo and the infra repo can be committed and pushed independently, and the
> `~/homelab` `.gitignore` never has to reason about a nested working tree.
>
> Chose `lambo-n` over the `Sunfire-Team` org: the cluster is personal infra, and
> org members would otherwise inherit access to the encrypted tunnel token and DB
> credentials.

**Superseded 2026-09-04:** `~/sunfire-backend/` no longer exists. Every value in
it was hash-verified against SOPS and Infisical first; the only two that were
irrecoverable were already dead (a token for the deleted tunnel, and a
pre-cutover `PGRST_DB_URI`). The rollback path is git history. `~/archive/` now
holds the decommissioned bingo assets, `chmod 700`.
