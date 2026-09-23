# tofu/

The layer Flux deliberately does not manage: Cloudflare, and the Proxmox guests
the cluster runs on. `GITOPS.md` → "Scope: Flux manages the cluster, not the
hypervisor" explains why a reconciler that can delete the VMs it runs on is a
circular dependency on a single host.

**Applies are run by hand from this VM, never from inside the cluster.** State is
local and gitignored; it is backed up with this VM.

> **Applied 2026-09-04. State is real.** `serial: 4`, two managed resources —
> `cloudflare_dns_record.minio_api` and `cloudflare_dns_record.db`. Both were
> imported from the live zone rather than created, and the apply that moved
> `var.tunnel_id` to `1ac59ce2-15bb-46df-967f-caa8b05881f7` is what cut live
> traffic onto the locally-managed tunnel.
>
> **Only Proxmox is left**, and it needs a token this operator can issue
> themselves. Skip to "Proxmox" at the bottom.

## What this directory does and does not own

| Object | Owner | Why |
|---|---|---|
| `minio-api` / `db` CNAMEs | **tofu** (here) | `var.tunnel_id` is the cutover lever: change it, apply, and traffic moves between tunnels |
| The tunnel itself | `scripts/cloudflared-new-local-tunnel.sh` | the provider cannot update the object at all, and `config_src` is immutable *and* ForceNew — see "Gotchas" |
| Tunnel credentials | Flux, SOPS-encrypted | a cluster secret, not an edge object |
| Ingress routing | Flux, `cloudflared/app/configmap.yaml` | the entire point of the local-management conversion |
| MinIO CORS Transform Rule | **nobody — delete it** | vestigial; no browser addresses that hostname. See "The CORS rule" below |
| Proxmox guests | **tofu, read-only** | all five imported 2026-09-04, `0 to change, 0 to destroy`; each carries `prevent_destroy` |
| VM 105 `llm` + its cloud image | **tofu, read-write** (`tofu@pve!llm`) | the one guest **authored** here, created by apply 2026-09-16 (`proxmox-llm-vm.tf`). Its token writes only to `/vms/105` — see [`../archive/GPU-VM-BUILD.md`](../archive/GPU-VM-BUILD.md) §A5, including the privsep and nearest-path traps. Refreshes normally with that token; the other five still need `-refresh=false` |

## The Cloudflare token — kept out of disk, so re-created when needed

The token used on 2026-09-04 was exported into one shell and never written
anywhere (`read -rs`, per below). That is deliberate and it has a cost: a future
Cloudflare apply needs the token again — either the same one, if it was put in
LastPass afterwards, or a fresh one made the same way.

### Why an ordinary credential will not do

None of the existing Cloudflare credentials can manage configuration, and it is
worth being precise about why, because three of them look like they might:

| Credential | What it actually is | Why not |
|---|---|---|
| Wrangler login | OAuth token, `zone:read` + `workers:*` | read-only on zones, no Zero Trust write; also OAuth, not the API token this provider takes |
| `CF_ACCESS_CLIENT_ID/SECRET` | Access **service token** | authenticates *through* Access to a protected app; it is a client credential, not a management one |
| Tunnel token | `{AccountTag,TunnelID,TunnelSecret}` | runs the tunnel, cannot configure it |
| `~/.cloudflared/cert.pem` | would grant tunnel management | **does not exist** — no `cloudflared login` was ever run, because the tunnel was created in the dashboard |

### The token that was used

Account **Sunfire** (`1b0e61d1024b78dd4bf289271823192f`), zone `sunosrs.cc`:

| Scope | Level | Needed for |
|---|---|---|
| **DNS : Edit** | Zone (`sunosrs.cc`) | importing and holding the two CNAMEs — the only writes tofu makes |
| **Zone : Read** | Zone (`sunosrs.cc`) | resolving the zone |
| **Cloudflare Tunnel : Edit** | Account | *was* requested to flip `config_src`. That turned out to be impossible at the API, and no tunnel object is managed here now — **a re-issued token does not need it** |

Do **not** add Transform Rules : Edit. The one Transform Rule in the account is
the MinIO CORS rule, and the answer there is to delete it, not to manage it —
see "The CORS rule" below.

#### Creating it

1. **dash.cloudflare.com → My Profile → API Tokens → Create Token → Create Custom Token.**
2. Permissions — both:

   | Type | Resource | Level |
   |---|---|---|
   | Zone | DNS | Edit |
   | Zone | Zone | Read |

3. **Zone Resources:** Include → Specific zone → `sunosrs.cc`.
4. Continue → Create. **The token is shown once.**

#### Loading it — without writing it to disk

```bash
read -rs CLOUDFLARE_API_TOKEN && export CLOUDFLARE_API_TOKEN
```

`read -rs` keeps it out of shell history — **but only if that line is typed and
run by itself.** Pasted as part of a multi-line block, `read` consumes the *next
pasted line* as its value, and the secret you paste afterwards executes as a
command instead (hit 2026-09-16). Run the `read` line alone, paste at the prompt,
then check the variable's prefix before using it. The provider reads
`CLOUDFLARE_API_TOKEN` natively, so nothing needs to go in `terraform.tfvars`.

#### Verify it before using it

```bash
curl -s https://api.cloudflare.com/client/v4/user/tokens/verify \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" | jq '.success, .result.status'
```

Expect `true` and `"active"`. A token missing a scope still verifies — the
scopes are checked at use, so a later 403 on a specific call means a missing
permission, not a bad token.

## Running a Cloudflare apply now

The zone id and both record ids are already in the config
(`variables.tf`, `cloudflare-dns.tf`); the discovery `curl`s that used to live
here are done. With the token exported:

```bash
tofu plan     # must be "No changes." unless you changed something on purpose
```

**A plan that proposes changes to a DNS record is a warning, not a to-do.** The
records are the live routing for both public hostnames. A diff means the config
has drifted from the zone — fix the config to match reality first, and only then
decide whether reality should change.

The one deliberate change this directory exists to make:

- **Moving traffic between tunnels** — set `var.tunnel_id` and apply. Both
  records' `content` derives from it, so a single apply re-points both
  hostnames. That is exactly how the 2026-09-04 cutover was done, and it is the
  rollback path too: the old tunnel id is recorded in `variables.tf`, though the
  old tunnel itself has since been deleted.

Verify from outside afterwards with the Worker, **not with `curl`**: both
hostnames return `HTTP 403` to anything without the Access service token,
whether the origin is healthy, broken or absent. `sunfire/DATA-ACCESS.md` has
the full status-code decoder.

## The CORS rule

`GITOPS.md` listed "MinIO CORS handled by a Cloudflare Transform Rule" as a
clickops gap. **Resolved 2026-09-04: the rule is vestigial — delete it in the
dashboard rather than codify it here.** Nothing about it belongs in tofu, so
there is no resource and no `.example` for it.

The evidence, in the app repo:

- every rendered `<img>` in a guide points at `/api/guides/media/<hash>.<ext>`
  on the Worker, same origin (`worker/api/guidesMedia.ts`, `src/lib/api.ts`)
- the Worker is the only S3 client and says so in its own header comment
  (`worker/lib/objectStore.ts`) — "the browser never signs anything and never
  talks to MinIO"
- there is no presign or signed-URL code anywhere in `worker/`, `shared/` or
  `src/`, so no browser-reachable MinIO URL is ever minted
- `minio-api.sunosrs.cc` appears in the app only as a Worker var in
  `wrangler.jsonc` — never in frontend source

And even if something did try: Access rejects a browser at the edge for want of
the service token, so the rule's response headers could never be exercised.


## Gotchas hit on the first real apply (2026-09-04)

All five are provider- or API-side, and all are recorded because the next person
will hit them identically.

**The tunnel object cannot be managed.** `cloudflare_zero_trust_tunnel_cloudflared`
imported fine and then failed its update with `PATCH … 404 {"code":1002,"message":
"Tunnel not found"}` — on a tunnel it had read seconds earlier. Nothing declared
on it differed from reality, so it attempted a write for computed drift alone.
It is no longer in this config. If it is still in your state from an earlier
run, `tofu state rm cloudflare_zero_trust_tunnel_cloudflared.sunfire` — removing
a resource from config while it remains in state makes the next plan propose
**destroying** it, and the `prevent_destroy` guard leaves with the block.

**`config_src` is immutable after tunnel creation — proven, not inferred.**
Cloudflare reports it as `1002 Tunnel not found`, which reads like a broken id or
a bad token and is neither. Verified against the live API with one token:

| Call | Result |
|---|---|
| `GET /cfd_tunnel/{id}` | `success: true` |
| `PATCH {"name":"sunfire-homelab"}` | `success: true` — writes are permitted |
| `PATCH {"config_src":"local"}` | `1002 Tunnel not found` |

Same endpoint, same token, same tunnel: a name change succeeds and `config_src`
does not. So a remotely-created tunnel cannot become locally-managed. Reaching
local management means creating a NEW tunnel with `config_src: "local"` and
moving the CNAMEs to it.

**The configurations endpoint will not store an empty config either.** With
`source = "local"` and `config = {}` it returns `1056 Bad Configuration:
Validation failed: The config file doesn't contain any ingress rules` — it
demands ingress rules even in the case where the stored rules are ignored.

**And `config_src` is ForceNew in the provider.** Declaring it plans a
destroy-and-recreate, which mints a new UUID and orphans both CNAMEs plus the
cluster's `credentials.json`. The same field is `source` on the *configuration*
resource, which is a separate object — that is the one to use.

**Setting `source` without `config` trips a provider bug:** `Value Conversion
Error … Received unknown value, however the target type cannot handle unknown
values. Path: config`. The provider cannot represent an unknown nested `config`,
so the attribute has to be given explicitly rather than left to be computed.

Nothing user-facing broke through any of it: both hostnames stayed at `HTTP 403`
and the connector never restarted, because none of the failures reached the
edge's serving config.

## Proxmox

**Done 2026-09-04 — all five guests, clean plan.** It took two passes: the LXC
imported under `PVEAuditor`, the four VMs needed one extra privilege, granted
briefly and revoked. The `pveum` commands below can be run over SSH from the
dev VM (`ssh pve-hostconfig`, the key added for the Ansible host-config layer
— `../ansible/README.md`) as well as from a console or password login there;
either way, everything after `pveum user token add` is API only, and the token
itself is a separate credential from that key.

| Guest | Kind | State |
|---|---|---|
| `tailscale-gateway` (CTID 100, `.102`) | LXC | imported — `proxmox-container.tf` |
| `dev` (101, `.103`) | QEMU | imported — `proxmox-vms.tf`; hosts this state file |
| `k3s-control` (102, `.104`) | QEMU | imported — `proxmox-vms.tf` |
| `k3s-worker1` (103, `.105`) | QEMU | imported — `proxmox-vms.tf`; minio |
| `k3s-worker2` (104, `.106`) | QEMU | imported — `proxmox-vms.tf`; PGDATA zvol as `archive-pool:vm-104-disk-0`, scsi1, 64 GiB |

All five carry `prevent_destroy`. A config that ever proposes replacing one of
them fails the plan rather than running it.

The fifth guest was `vpn-gateway` at an unknown CTID in the earlier draft here.
It is `tailscale-gateway` at CTID 100 — outside the 101–104 run the VMs use, so
the "VMID + 2 = last octet" pattern is a coincidence of the VMs and not a rule.
Both facts came from one API call, which is the argument for reading before
writing an id.

### The privilege that blocked the four VMs

`PVEAuditor` is not enough, and the reason is worth stating precisely because
"read-only cannot read it" sounds like a contradiction:

```
error get file local-lvm:vm-102-disk-0 from datastore local-lvm:
403 Permission check failed (/vms/102, VM.Config.Disk)
```

The VM config itself reads fine — `GET /nodes/pve/qemu/102/config` returns
`scsi0 = "local-lvm:vm-102-disk-0,iothread=1,size=15G"`, disk string included.
It is the *second* call that fails: the provider re-resolves every volume
through `GET /nodes/pve/storage/{store}/content/{volume}`, and PVE gates that
endpoint on `VM.Config.Disk` — the privilege that permits **changing** disk
configuration. The data is readable; the provider asks for it by a route that
requires write authority.

The LXC did not hit this: PVE gates container volume reads on `Datastore.Audit`,
which `PVEAuditor` has.

**How it was resolved, and how to repeat it.** A role holding *only* that one
privilege, stacked on `PVEAuditor` and removed straight after:

```bash
# on 192.168.50.101, as root
T='tofu@pve!import'
pveum role add TofuDisk --privs VM.Config.Disk   # once; it persists
pveum acl modify / --users tofu@pve --roles TofuDisk
pveum acl modify / --tokens "$T" --roles TofuDisk
#   ...generate, review, import or refresh from this VM...
pveum acl delete / --tokens "$T" --roles TofuDisk
pveum acl delete / --users tofu@pve --roles TofuDisk
```

⚠️ **Grant it to the token as well as the user** *(since 2026-09-16)*. `!import`
has been `--privsep 1` since then (below), so its rights are the *intersection*
of its own ACL and the user's. A grant on the user alone still fails with
`403 Permission check failed (/vms/103, VM.Config.Disk)`, which is exactly what
the first attempt at the 2026-09-21 worker1 refresh hit.

Stacking beats editing the base role: the revoke removes one narrow grant rather
than re-asserting a broad one, and it is checkable from here without SSH —

```bash
curl -sk -H "Authorization: PVEAPIToken=$PROXMOX_VE_API_TOKEN" \
  https://192.168.50.101:8006/api2/json/access/permissions | jq '.data["/"]'
```

`VM.Allocate` was never granted at any point, so even inside the window the
token could not replace a guest. Re-granting is needed only to regenerate a
body; ordinary `tofu plan -refresh=false` makes no Proxmox API call at all.

### The argument for read-only

Everything this import does is a read: `import` blocks, `-generate-config-out`,
and the plan that must come back clean. A token that cannot write is the thing
that makes those reads safe, because `.103` — this VM, the one holding the state
file — is itself one of the five guests being imported. With `PVEAuditor` the
worst outcome of a wrong attribute is *"plan proposes replacing `k3s-worker2`"*,
which is a diff to read. With a write-capable token the worst outcome is that
apply carries it out and takes the PGDATA zvol with it.

Widen the token later if a change genuinely needs to write, deliberately, for
that change. Do not pre-authorize it. That is exactly how the `VM.Config.Disk`
problem above was handled — one privilege, granted for one generation, revoked
straight after — and `prevent_destroy` on all five resources is the belt to that
token's braces: it does not depend on the token being read-only at all.

### On `192.168.50.101`, as root

```bash
pveum user add tofu@pve --comment "OpenTofu, read-only (homelab/tofu)"
pveum acl modify / --users tofu@pve --roles PVEAuditor
pveum user token add tofu@pve import --privsep 0
```

`--privsep 0` makes the token inherit the user's privileges — which were
auditor-only at the time, so this was not a widening.

> 🔴 **That stopped being safe on 2026-09-16.** `tofu@pve` has to gain write
> roles on `/vms/105` and the storages for the `!llm` token to work at all — a
> privsep token's rights are the **intersection** of its own ACLs and its user's,
> so a token cannot exceed its user ([`../archive/GPU-VM-BUILD.md`](../archive/GPU-VM-BUILD.md) §A5). With
> `--privsep 0`, `!import` would inherit every one of those write roles and stop
> being read-only. ✅ **Done 2026-09-16** — switched to `--privsep 1` with its own
> `PVEAuditor` grant at `/`, *before* the user was widened:
>
> ```bash
> pveum user token modify tofu@pve import --privsep 1
> pveum acl modify / --tokens 'tofu@pve!import' --roles PVEAuditor
> pveum user permissions 'tofu@pve!import' --path /vms/105   # audit only
> ```
>
> Verified afterwards: that last command returns the seven auditor privileges
> only, although `tofu@pve` itself now holds `TofuVM` on `/vms/105`. Switching
> the flag does **not** regenerate the secret, so the LastPass copy stays valid.

The `token add` command prints the secret **once**; it is a UUID, and the
provider wants it joined to the token's full name.

### Back on this VM

```bash
read -rs PROXMOX_VE_API_TOKEN && export PROXMOX_VE_API_TOKEN
# paste exactly:  tofu@pve!import=<uuid>
```

`providers.tf` leaves `api_token` null so the provider picks this up from the
environment; the endpoint is already a default in `variables.tf`. Verify before
using it — this also confirms 8006 is reachable, which is the one port that is:

```bash
curl -sk -H "Authorization: PVEAPIToken=$PROXMOX_VE_API_TOKEN" \
  https://192.168.50.101:8006/api2/json/version | jq .data.version
```

### Enumerating the guests without SSH

This is how CTID 100 was found, and it is the call to repeat rather than trust
the table above if anything has changed. `qm list` shows QEMU only, so an LXC is
invisible to it; `/cluster/resources` returns both kinds at once:

```bash
curl -sk -H "Authorization: PVEAPIToken=$PROXMOX_VE_API_TOKEN" \
  'https://192.168.50.101:8006/api2/json/cluster/resources?type=vm' \
  | jq -r '.data[] | "\(.type)\t\(.vmid)\t\(.node)\t\(.name)"' | sort
```

Import IDs are `<node>/<vmid>` for both kinds; the node is `pve`. As of
2026-09-04 it returns exactly the five rows in the table above.

### The sequence — for the next guest, or to regenerate an existing body

All five are imported, so this is the procedure to repeat rather than a to-do.
Write the `import` block first, with no resource body, then:

```bash
tofu plan -refresh=false -generate-config-out=proxmox-generated.tf
```

**`-refresh=false` is not optional here.** Both providers live in this one root
module, so any plan refreshes the two Cloudflare DNS records too — and with no
`CLOUDFLARE_API_TOKEN` exported that fails with `9106 Missing X-Auth-Key,
X-Auth-Email or Authorization headers` before it ever gets to Proxmox. Skipping
refresh is what lets one token's work proceed without the other's. (The real
fix is separate root modules with separate state; it has not been done.)

Then **read** `proxmox-generated.tf` before anything else — it is gitignored
precisely so a generated file cannot be committed unreviewed. Fold what is worth
keeping into a real `.tf` file, delete the noise, and run `tofu plan` again.

**Expect the generated file not to validate.** Five attributes were emitted as
empty or zero values for unset optionals and then rejected by the provider's
*own* validators — generation and validation disagree, which is a provider bug
rather than a fact about the hypervisor. Delete the attribute and let the schema
default stand:

| Attribute | What the validator says |
|---|---|
| `affinity = ""` | must contain numbers or number ranges separated by `,` |
| `hugepages = ""` | expected one of `["1024" "2" "any"]` |
| `units = 0` | expected units in the range (1 - 262144) |
| `entrypoint = ""` (LXC) | Disallow Invalid Characters |

`template_file_id = ""` looks like one of these and is not: the schema marks it
required, so removing it fails with "Missing required argument". Keep it.

`timeout_*` is the subtle one — it validates fine and is still wrong. Those
attributes are *this client's* patience, not anything Proxmox stores, so import
reads them as null, the schema defaults re-add them, and you get a permanent
"update in-place" whose entire diff is timeouts: a diff no apply against the
host could ever settle. `proxmox-container.tf` ignores them in a `lifecycle`
block; the VM bodies omit them.

One warning is expected and unfixable: `network_device.enabled` is deprecated,
and the provider's advice ("remove the block instead") does not apply to an
interface that is enabled and real. Deleting just the attribute fails with
"Incorrect attribute value type" — `network_device` is a typed object list, so
every attribute must be present.

**Then the plan must say "No changes."** Anything else is real. Fix the config;
never the machine. A generated body carries every computed attribute the
provider felt like emitting, and some of them — disk layout above all — plan a
**replacement** rather than an update when they are even slightly wrong. On
`k3s-worker2` that is the database, which is why all five resources carry
`prevent_destroy`: the guard turns that mistake into a failed plan.

Two things the bpg provider will not do over an API token alone, neither of
which this import needs: file uploads and some disk operations want root SSH to
the node. If a future change hits that wall, that is a separate decision about a
separate credential — not a reason to widen this one.

## Where each credential lives

Written 2026-09-15, after half an hour was spent looking for a Proxmox token
that had never been stored anywhere. **Infra credentials go to LastPass and are
exported per shell. They are deliberately not in Infisical and not in SOPS.**

| Credential | Lives in | Used as | Notes |
|---|---|---|---|
| `tofu@pve!import` | **LastPass** | `PROXMOX_VE_API_TOKEN` | `PVEAuditor`, read-only, **`--privsep 1` since 2026-09-16** — which is what keeps it read-only now that `tofu@pve` holds write roles on `/vms/105`. Regenerated 2026-09-09 ([`../archive/SAS-RECLAIM.md`](../archive/SAS-RECLAIM.md) §5) and again 2026-09-15 — Proxmox shows a token secret **once**, so a lost one is replaced, never recovered. |
| `tofu@pve!llm` | **LastPass** | `PROXMOX_VE_API_TOKEN` | Created 2026-09-16, `--privsep 1`. Writes only to `/vms/105`, plus the three storages, the PCI mapping, the bridge, and `Sys.AccessNetwork` on `/nodes/pve` so the node can download the cloud image (the narrow alternative to `Sys.Modify`). See [`../archive/GPU-VM-BUILD.md`](../archive/GPU-VM-BUILD.md) §A5 — including why `tofu@pve` itself must hold these roles for the token to have them. |
| Cloudflare API token | **Nowhere, by design** — re-created when needed (see "The Cloudflare token" above); put it in LastPass if you make one | `CLOUDFLARE_API_TOKEN` | Required scopes are above. **Only needed when a plan refreshes or changes the Cloudflare records.** A `-refresh=false` plan that leaves them untouched makes no Cloudflare API calls and runs without it (verified 2026-09-16; the import section below relies on the same fact). |
| `age.key` | `~/homelab/age.key` (gitignored) + **LastPass** | `sops` | Bootstrap secret — it decrypts the others. Never printed, never committed. |
| Cluster-only secrets | **git**, as `*.sops.yaml` | Flux → k8s Secrets | MinIO root, `POSTGRES_PASSWORD`, `PGRST_DB_URI`, tunnel token. |
| Cross-boundary secrets | **Infisical** (`prod` / `feature`) | operator → k8s Secret, Worker env | `POSTGREST_JWT_SECRET` + the four scoped MinIO Worker keys — the ones that must stay byte-identical on both sides. |
| Infisical machine identity | **SOPS**, seeded into the cluster | operator auth | Which is why `age.key` still holds exactly one secret. |

**Why the hypervisor token is not in Infisical:** the Infisical operator runs
inside the cluster, on VMs this directory manages. Putting the token that
rebuilds those VMs behind a service that needs them running is a bootstrap loop
— the same reasoning that keeps `age.key` in LastPass. Recovery has to be a human
login from any device.

**`terraform.tfvars` stays absent.** `variables.tf` leaves both tokens `null` so
the providers read them from the environment; a tfvars file would put them on
disk, which `AGENTS.md` rule 6 forbids outright.

## Versions

Providers are constrained in `versions.tf` and exactly pinned by
`.terraform.lock.hcl`, which **is** committed. Renovate's terraform manager
tracks both.

> ⚠️ **Renovate bumps the constraint; only `tofu init` refreshes the lock.**
> Found 2026-09-15: `versions.tf` had been raised to `bpg/proxmox ~> 0.113` and
> `cloudflare ~> 5.24`, but the lock still carried the 0.112 package and the old
> cloudflare constraint line. The result is that **every tofu command fails
> outright** on a fresh checkout or after a cache clear:
>
> ```
> Error: Required plugins are not installed
>   - registry.opentofu.org/bpg/proxmox: there is no package for
>     registry.opentofu.org/bpg/proxmox 0.113.1 cached in .terraform/providers
> ```
>
> **After merging any Renovate provider PR, run `tofu init` here and commit the
> resulting `.terraform.lock.hcl`.** There is no CI that would catch it — the
> only workflow is `validate-manifests.yaml`, which covers `kubernetes/`, not
> `tofu/`.

## State drift: a plan can say "0 changes" and still leave the state stale

**A `plan` never writes refreshed state. Only an `apply` does.** That distinction
cost this repo a latent broken plan for six days, and it is worth understanding
before it happens again.

On 2026-09-09 the LXC's bind mount was repointed on the host with `pct set`
(`../archive/SAS-RECLAIM.md` §3), because `mount_point.volume` is ForceNew and changing it
in tofu would plan a destroy/recreate of the tailnet gateway. The config was then
reconciled and verified with `tofu plan -target=...` — which **refreshed in
memory, reported `0 to change`, and exited without persisting anything.** The
state file on disk still said `/mnt/sas1/tailscale-gateway-logs`.

That is invisible until someone runs the repo's *documented everyday command*,
which disables refresh precisely because `PVEAuditor` cannot refresh the four
VMs (see "The privilege that blocked the four VMs"):

```
$ tofu plan -refresh=false
  ~ volume = "/mnt/sas1/tailscale-gateway-logs" -> "/archive-pool/ts-ssh-records" # forces replacement
Error: Resource instance cannot be destroyed
  ... proxmox_virtual_environment_container.tailscale_gateway has prevent_destroy set
```

With refresh off, stale state *is* reality as far as the plan is concerned, so it
proposes destroying the container that is the only tailnet member, the exit node,
and the `ProxyJump` for every SSH entry. `prevent_destroy` refuses — correctly —
but the refusal **fails the whole plan**, so no other change can be planned until
this is fixed.

### The fix: persist the refresh, once

Needs the read-only `tofu@pve!import` token. Target the container: an untargeted
refresh also touches the four VMs, which 403 on `VM.Config.Disk` under
`PVEAuditor`.

```bash
export PROXMOX_VE_API_TOKEN='tofu@pve!import=<uuid>'   # from LastPass
# CLOUDFLARE_API_TOKEN not needed: -refresh=false makes no Cloudflare API calls
cd ~/homelab/tofu
tofu apply -refresh-only -target=proxmox_virtual_environment_container.tailscale_gateway
```

Read the proposed state change before accepting: the only difference should be
`path_in_datastore` moving to `/archive-pool/ts-ssh-records`. **`-refresh-only`
cannot create, destroy or modify infrastructure** — it only reconciles state with
what the API reports, which is why it is safe to run with `prevent_destroy` in
place and a read-only token.

Then confirm the everyday command is clean again:

```bash
tofu plan -refresh=false     # expect: No changes.
```

**The general rule:** whenever a change is made on the host and reconciled in
config afterwards — the "config-follows-reality" shape this repo uses for
anything ForceNew — finish with `tofu apply -refresh-only`, not `tofu plan`.
