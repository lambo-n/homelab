# Homelab

A three-node k3s cluster on a single Proxmox host, reconciled by Flux from this
repository. It is general-purpose infrastructure — somewhere to run whatever is
better off on hardware in the house than on someone else's platform. The platform
underneath (Flux, secrets, storage, observability, backups) is shared; the
workloads on top of it come and go.

This file describes **the hardware, the platform, and what each piece of software
actually does**. For the flags, gotchas and open items on any of those pieces, read
[`GITOPS.md`](GITOPS.md) — it is organised by tool and holds everything that has
already gone wrong here, with dates.

---

## What runs on it

Everything currently deployed, one entry each. This is the section that grows as
workloads are added; the shared platform components are described further down
under [The stack](#the-stack).

| Workload | What it is for | Namespace | Reached at |
|---|---|---|---|
| **Sunfire** | Object storage and relational data for the `sunosrs.cc` Cloudflare Worker | `sunfire` | `minio-api.sunosrs.cc`, `db.sunosrs.cc` |
| **Observability** | Prometheus, Alertmanager and Grafana for the cluster itself | `observability` | `grafana.homelab.lan` (LAN only) |

Adding one means a directory under `kubernetes/apps/`, its own `ks.yaml`, and a row
above.

### Sunfire — backing a Cloudflare Worker

[`sunosrs.cc`](https://sunosrs.cc) is a React SPA plus a Cloudflare Worker for an
Old School RuneScape clan. Cloudflare is a poor place to store a few hundred
megabytes of guide screenshots and GIFs, and a worse place to keep relational
data, so the Worker offloads both here:

| The Worker needs | This homelab provides | Reached at |
|---|---|---|
| Blob storage for guide media | **MinIO**, S3-compatible | `minio-api.sunosrs.cc` |
| Structured guide metadata | **PostgreSQL** behind **PostgREST** | `db.sunosrs.cc` |

Both hostnames are Cloudflare Access–gated and reached through an outbound-only
tunnel — there is no port forwarding and no inbound firewall rule anywhere.

> **History.** The original consumer was *Sun Clan Bingo*, decommissioned
> 2026-09-02. MinIO and PostgreSQL were kept for a successor Worker and everything
> was rebranded `bingo` → `sunfire`. The successor app does not exist yet, which is
> why write volume is currently near zero.

---

## Operating assumptions

These hold for anything deployed here, not just for what happens to be running today.

**100% uptime is not guaranteed.** It is a machine in a house — prone to infrequent
power outages, and taken down by hand for maintenance. Consumers have to treat an
unreachable cluster as a normal state rather than an incident: the Sunfire Worker
serves a graceful `503` rather than a `500` and falls its image components back
cleanly. That single fact shapes an unusual number of decisions in `GITOPS.md`: it
is why secrets the cluster needs to boot stay in git rather than in a cloud vault,
and why alerting deliberately pushes nothing anywhere.

**Nothing is exposed inbound.** Public reachability is opt-in per workload, through
the cloudflared tunnel and behind Cloudflare Access. LAN-only services (Grafana
today) stay on Traefik and are deliberately kept off the tunnel.

**The repository is the desired state, and it is also the practice.** The migration
from hand-applied YAML to a fully reconciled cluster is recorded phase by phase at
the bottom of `GITOPS.md`; new workloads are expected to arrive the same way.

---

## Hardware

**One physical machine.** Everything below is a guest on it, which makes the host
a single failure domain and is the constraint behind most of the architecture.

### The host

| | |
|---|---|
| Proxmox VE | `192.168.50.101` (`pve`) |
| Also runs | the **NFS server** exporting `/archive-pool` |
| VM disks | `local-lvm` — LVM-thin on an NVMe RAID1 pair, 130.2 GiB, ~90.5 GiB free |
| Bulk storage | `archive-pool` — ZFS **3-way mirror**, 1.68 TiB usable, two-disk fault tolerance |

*Host storage figures last read from `pvesm status` on 2026-09-03; the dev VM has
no route to the pool and cannot re-check them.*

### Guests

| Guest | Type | VMID/CTID | IP | Resources |
|---|---|---|---|---|
| `tailscale-gateway` | LXC | 100 | `.102` | 1 GiB RAM, 8 GiB disk, unprivileged |
| `dev` | VM | 101 | `.103` | the workstation this repo lives on |
| `k3s-control` | VM | 102 | `.104` | 2 vCPU, 8 GiB RAM, 9.75 GiB root |
| `k3s-worker1` | VM | 103 | `.105` | 4 vCPU, 128 GiB RAM, 17.83 GiB root |
| `k3s-worker2` | VM | 104 | `.106` | 4 vCPU, 128 GiB RAM, 17.83 GiB root |

> **VMID + 2 = last octet holds for the four VMs by coincidence, not by rule** —
> the LXC at CTID 100 sits outside that run. Do not rely on it.

All five are in OpenTofu state with `prevent_destroy`, each body generated from
the live guest rather than hand-written. 256 GiB of worker RAM against ~1% CPU and
<1% memory utilisation is the reason "we have headroom" never appears as an
argument in `GITOPS.md`; the scarce resource here is **disk**, not compute.

### Where data actually sits

| Data | Lives on | Via |
|---|---|---|
| Guide media (MinIO) | `archive-pool` | NFS PV, 1 TiB nominal, `Retain` |
| PGDATA (CloudNativePG) | `archive-pool` | a 64 GiB **zvol** attached to `k3s-worker2` as a block device, ext4, mounted at `/var/lib/rancher/k3s/storage` |
| Postgres backups | `archive-pool` | into MinIO, which is itself on the pool |
| Prometheus TSDB | `k3s-worker1` root disk | `local-path`, capped by `retentionSize` |
| Legacy Postgres data | `archive-pool` | NFS PV, 100 GiB, `Retain`, no longer read |

> ⚠️ **Destroying or rebuilding `archive-pool` now takes `k3s-worker2`'s database
> disk with it**, and pool work requires that VM stopped first. This retires an
> invariant repeated across older revisions of these documents — *"no VM disk is on
> ZFS"* — which stopped being true when PGDATA moved to a zvol.

### Network

Flat `192.168.50.0/24`, gateway `.1`. No VLANs, no BGP, nothing to peer with.

- **Inbound from the internet:** none. The only path in is the outbound cloudflared
  tunnel, gated by Cloudflare Access.
- **Inbound on the LAN:** Traefik on `:80`/`:443` via k3s' klipper LoadBalancer,
  which answers on **all three** node IPs.
- **Remote administration:** Tailscale. The `tailscale-gateway` LXC is the only
  tailnet member and offers an exit node; every other host is reached by
  `ProxyJump` through it, so administrative access is SSH-mediated and recorded to
  `/var/log/ts-ssh-records`.

---

## How a public request reaches a workload

Sunfire is the only workload on the tunnel today, so its path is the worked example;
anything published later joins the same chain.

```
browser ──▶ Cloudflare edge ──▶ Access ──▶ tunnel ──▶ cloudflared pod
   │              (sunosrs.cc)   (service                    │
   │                              token)                     ├─▶ minio:9000      guide media
   └── the Worker is the ONLY S3 client;                     └─▶ postgrest:3000 ─▶ postgres-cnpg-rw
       browsers never address minio-api directly
```

Two consequences worth knowing before debugging anything:

- **A `403` from either hostname is not a health check.** Access rejects at the
  edge, *before* the tunnel, so a `403` looks identical whether the origin is
  healthy, broken or absent. The honest end-to-end test is the Worker itself,
  because it holds the Access service token.
- **`401` from PostgREST is correct.** The `anon` role is revoked; unauthenticated
  callers are supposed to be turned away.

---

## The stack

Every component, what it actually does here, and where its configuration lives.
Versions are the ones running now.

### Reconciliation

**flux-operator** `v0.59.0` — installs and manages Flux itself from a
`FluxInstance` CR, so the reconciler is declarative rather than a `flux bootstrap`
side effect. Its own install is the one imperative step in the whole system; it is
the thing that starts everything else.
→ `bootstrap/flux/flux-instance.yaml`

**Flux** `v2.9.5`, four controllers — source, kustomize, helm, notification. Polls
this repo over SSH every **1m** with a read-only deploy key and applies
`kubernetes/flux/cluster`, which fans out to one `Kustomization` per app, each
re-applying what was fetched every 30m. There is no webhook, so a push to `main`
lands within about a minute — drilled 2026-09-08, see `GITOPS.md`. Decrypts
SOPS files inline. Image automation controllers are deliberately **not** installed;
Renovate owns updates.
→ `kubernetes/flux/cluster/`, one `ks.yaml` per app

**Renovate** — opens PRs for every dependency: container images, Helm charts,
GitHub Actions, mise tools, OpenTofu providers. Runs as a self-hosted GitHub Action
on a daily cron (10:00 UTC) and on any push that changes its own config. **Minor,
patch and digest bumps automerge; majors always wait for a human** — with two
exceptions: `kubectl`, whose "minor" spans Kubernetes minors, and 0.x deps, whose
minors Renovate already types as major.
→ `.renovaterc.json5`, `.renovate/`

### Secrets

**SOPS + age** — encrypts every secret that the cluster needs in order to boot,
in this repo. Only payloads are encrypted, so resource metadata stays readable in
diffs. Flux decrypts at apply time using an in-cluster key. This is what makes a
cold start need no network beyond GitHub.
→ `.sops.yaml`, `*.sops.yaml`, `age.key` (gitignored)

**Infisical** `v0.11.8` — system of record for the *other* class of secret: the
ones that must stay byte-identical between this cluster and two Cloudflare Worker
environments. The operator materialises them into Kubernetes Secrets.
→ `kubernetes/apps/infisical/`, `kubernetes/apps/sunfire/infisical/`

| Class | Which keys | Home | Why there |
|---|---|---|---|
| Cluster-only | MinIO root, `POSTGRES_PASSWORD`, `PGRST_DB_URI`, tunnel credentials | **SOPS**, in git | Cold boot must not depend on a cloud service |
| Cross-boundary | `PGRST_JWT_SECRET`, 4× scoped MinIO Worker keys | **Infisical** | One value, three consumers, must never drift |

**Reloader** `v1.4.21` — restarts a workload when a Secret or ConfigMap it
references changes. This is a **correctness** component, not a convenience: env
vars from a `secretKeyRef` are read once at container start, so without it a
rotated secret reports success everywhere and changes nothing.
→ `kubernetes/apps/reloader/`

### Data

**MinIO** `RELEASE.2025-09-07T16-13-09Z` — S3-compatible object storage. Holds
guide media in `sunfire-guide-media` and, separately, the Postgres backups. The
Worker authenticates with a scoped service account that deliberately lacks
`s3:ListBucket`.
→ `kubernetes/apps/sunfire/minio/`

**CloudNativePG** `v1.30.0` operator, running PostgreSQL **16.15** as a
single-instance `Cluster`. Replaced a hand-rolled Deployment on 2026-09-04. One
instance, not three — three replicas on one hypervisor is theatre.
→ `kubernetes/apps/cnpg-system/`, `kubernetes/apps/sunfire/postgres-cnpg/`

**plugin-barman-cloud** `v0.14.0` — the CNPG backup plugin (separate from the
operator since barman moved out of `spec.backup`). Archives WAL continuously and
takes a daily base backup into MinIO. Proven by a restore drill, not by the
backups reporting success.
→ `kubernetes/apps/cnpg-system/plugin-barman-cloud/`

**PostgREST** `v16.2` — turns the database into a REST API so the Worker needs no
Postgres driver. Reads `postgres-cnpg-rw`. Authenticates callers with a JWT whose
signing key is the one secret shared with Cloudflare.
→ `kubernetes/apps/sunfire/postgrest/`

**cert-manager** `v1.21.1` — present **only** because the barman plugin hard-requires
it for its internal mTLS. It issues nothing else; there is no `ClusterIssuer`.
→ `kubernetes/apps/cert-manager/`

### Networking

**cloudflared** `2026.8.3` — an outbound-only tunnel to the Cloudflare edge. Since
2026-09-04 it is **locally managed**: the ingress map is a ConfigMap in this repo,
not a dashboard setting.
→ `kubernetes/apps/sunfire/cloudflared/`

**Traefik** `3.6.13` and **klipper-lb** — k3s' bundled ingress controller and
service LoadBalancer. Used today for exactly one thing: serving Grafana on the LAN.
Any future LAN-only UI goes here rather than on the tunnel.
→ ships with k3s, not managed here

**OpenTofu** `1.12.6` — declares the two Cloudflare DNS records and all five
Proxmox guests. Runs **by hand from the dev VM, never from inside the cluster** —
a reconciler that can delete the VMs it runs on is the failure mode this whole
layer split exists to avoid.
→ `tofu/`

### Observability

**kube-prometheus-stack** chart `89.2.0` — Prometheus `v3.14.0`, Alertmanager
`v0.34.0`, Grafana `13.2.1`, node-exporter and kube-state-metrics. 26 scrape
targets, 222 alert rules. Alerts fire and are visible; nothing is pushed anywhere,
deliberately.
→ `kubernetes/apps/observability/kube-prometheus-stack/`

**flux-monitoring** — PodMonitors for the Flux controllers and the operator, three
Flux alert rules, and Flux's own Grafana dashboards committed as JSON.
→ `kubernetes/apps/observability/flux-monitoring/`

> **Reaching Grafana.** Nothing resolves `homelab.lan` — add to `/etc/hosts` on any machine
> that browses it:
>
> ```
> 192.168.50.104  grafana.homelab.lan
> ```
>
> Any of the three node IPs works; Traefik's klipper LoadBalancer answers on all of them.
> The admin password is in git, encrypted — read it with
> `sops --decrypt kubernetes/apps/observability/kube-prometheus-stack/app/grafana-admin.sops.yaml`.
> Deliberately **not** added to the cloudflared tunnel: that would put an admin UI on the
> public edge and grow the tunnel's blast radius for something only ever used from this LAN.


### Host-level — outside Kubernetes entirely

**sanoid** — ZFS snapshots on the Proxmox host: 24 hourly, 30 daily, 6 monthly
across `minio-data`, `postgres-data` and the PGDATA zvol. This is the second,
independent backup layer; barman covers the database logically, sanoid covers the
volumes underneath it. Rollback was drilled, not assumed.
→ [`SANOID.md`](SANOID.md), and host config on `.101`

**mise** — pins the entire toolchain (`kubectl`, `flux`, `helm`, `sops`, `age`,
`opentofu`, `infisical`) and binds `KUBECONFIG` and `SOPS_AGE_KEY_FILE` so `sops`
finds its key with no flags. Fixes the version skew that had `kubectl` v1.30
talking to a v1.35 server.
→ `mise.toml`

### Layer split

Which tool owns what, and why Flux does not own everything:

| Layer | Tool | Why not Flux |
|---|---|---|
| PVE host config — ZFS, network, NFS exports, packages | Ansible / manual | No declarative API; Flux cannot reach it |
| VM and LXC lifecycle | OpenTofu + `bpg/proxmox` | Must survive the cluster being down |
| k3s workloads | **Flux** | This is what Flux is for |

The reasoning, and the circular-dependency argument against closing that gap, is
under *Cross-cutting decisions* in `GITOPS.md`.

---

## Repository layout

```
bootstrap/flux/flux-instance.yaml   flux-operator FluxInstance — the one imperative step
kubernetes/flux/cluster/            root sync target; every app is reached from here
kubernetes/apps/
  ├── cert-manager/       cert-manager          (exists only for the barman plugin)
  ├── cnpg-system/
  │     ├── cloudnative-pg/       CNPG operator
  │     └── plugin-barman-cloud/  backup plugin (must share the operator's namespace)
  ├── infisical/          Infisical Operator
  ├── observability/
  │     ├── kube-prometheus-stack/  Prometheus, Alertmanager, Grafana, exporters
  │     └── flux-monitoring/        PodMonitors, Flux alerts, Flux dashboards
  ├── reloader/           restarts workloads when their Secrets change
  └── sunfire/            a workload namespace — one directory per workload
        ├── storage/       NFS PV + PVC          (prune permanently disabled)
        ├── minio/         S3 object storage     → minio-api.sunosrs.cc
        ├── postgres/      legacy credential only (Deployment retired 2026-09-04)
        ├── postgres-cnpg/ CNPG Cluster + ObjectStore + ScheduledBackup
        ├── postgrest/     REST over Postgres    → db.sunosrs.cc
        ├── infisical/     InfisicalSecret CR
        └── cloudflared/   tunnel; routing in configmap.yaml
scripts/                  one-shot bootstrap scripts (tunnel, MinIO accounts, Infisical seed)
tofu/                     Proxmox guests + Cloudflare DNS — applied by hand
```

Each app is `ks.yaml` (a Flux `Kustomization`) plus `app/` (plain manifests).
Ordering is expressed with `dependsOn`:

```
storage ─┬─ minio ────────────────────┬─ cloudflared
         └─ postgres ── postgrest ────┘
                     └─ postgres-cnpg ─┬─ (also minio, plugin-barman-cloud)
cert-manager ──────┬─ plugin-barman-cloud
cloudnative-pg ────┘

infisical-secrets-operator ── sunfire-infisical
kube-prometheus-stack ── flux-monitoring
```

`reloader` and `kube-prometheus-stack` deliberately have **no** `dependsOn`:
nothing in the cluster depends on either, so neither can wedge the sunfire or cnpg
graphs. `flux-monitoring` depends on the stack only because `PodMonitor` and
`PrometheusRule` do not exist as kinds until its CRDs are registered.

> The `postgres` node is no longer a database — since 2026-09-04 that
> Kustomization holds only the `postgres-credentials` Secret. The two edges into it
> survive for different reasons: `postgres-cnpg` genuinely needs that Secret for its
> `externalClusters` reference, while `postgrest`'s edge is vestigial and should
> point at `postgres-cnpg`. Tracked under *Open items* in `GITOPS.md`.

---

## Repository boundaries

Three trees on the dev VM, deliberately siblings and never nested:

| Path | What it is | Git |
|---|---|---|
| `~/homelab/` | **This repo.** Cluster desired state | `lambo-n/homelab` (private) |
| `~/sunfire/` | The consuming app, cloned **for model context only** | `Sunfire-Team/sunfire` |
| `~/archive/` | Decommissioned Sun Clan Bingo assets, read-only | untracked, `chmod 700` |

> `~/sunfire-backend/` — the pre-GitOps manifests and plaintext copies of every
> live secret — was **deleted 2026-09-04**, once every value in it had been
> hash-verified as recoverable from SOPS or Infisical. The two that were not
> recoverable were already dead: a token for the tunnel deleted at the cutover,
> and a `PGRST_DB_URI` naming the retired `postgres` Deployment. Git history is
> the rollback path now, and **there is no plaintext secret anywhere on this VM.**

**Do not `git init` in `/home/dev` itself** — it would swallow the `~/sunfire/`
clone, `~/.ssh` and `~/.claude.json`. Keeping them siblings also means the app repo
and the infra repo can be pushed independently.

`lambo-n` rather than the `Sunfire-Team` org, deliberately: the cluster is personal
infrastructure, and org members would otherwise inherit access to the encrypted
tunnel credentials and database passwords.

**No plaintext secret may be committed to any of the three.** Only `*.sops.yaml`
may exist here; `.gitignore` refuses a bare `secret.yaml` outright so it cannot be
staged by accident.

---

## Everyday commands

Run everything from `~/homelab` — mise's tool pins and `[env]` bindings only apply
inside this directory.

```bash
mise install                              # first time, or: mise trust && mise install

flux get kustomizations                   # what is reconciling, and whether it is happy
flux reconcile source git flux-system     # fetch main now instead of waiting out the 1m poll
flux logs --level=error --all-namespaces  # what went wrong

sops kubernetes/apps/sunfire/postgres/app/secret.sops.yaml   # edit a secret in place
sops --decrypt <file>                                        # read one
sops --encrypt --filename-override <dest>.sops.yaml <src> > <dest>

cd tofu && tofu plan -refresh=false       # -refresh=false: one root module, two providers
```

> The `--filename-override` flag is required when the source file lives outside
> this repo — SOPS matches `creation_rules` against the *input* path.

**`age.key` is backed up in LastPass** (a secure note — human login from any
device). It is deliberately *not* in Infisical: a machine credential used to fetch
it would die with the VM it is stored on, which is precisely the disaster being
insured against. Without this key every secret here is unreadable, and **it must
never be `cat`-ed**, including to display it for backup.

---

## Where the details live

| Document | Covers |
|---|---|
| [`GITOPS.md`](GITOPS.md) | **Flags, gotchas, config context and open items, by tool.** Start here when something is odd |
| [`STORAGE.md`](STORAGE.md) | The PGDATA zvol and worker disk growth — runs on the Proxmox host |
| [`SANOID.md`](SANOID.md) | ZFS snapshot policy and the rollback drill — same host |
| [`RESTORE.md`](RESTORE.md) | The CNPG restore drill, step by step |
| `tofu/README.md` | The OpenTofu root module, its tokens, and the import history |
| `AGENTS.md` | Orientation for AI assistants working in this tree |
