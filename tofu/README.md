# tofu/

The layer Flux deliberately does not manage: Cloudflare, and the Proxmox guests
the cluster runs on. `GITOPS.md` → "Scope: Flux manages the cluster, not the
hypervisor" explains why a reconciler that can delete the VMs it runs on is a
circular dependency on a single host.

**Applies are run by hand from this VM, never from inside the cluster.** State is
local and gitignored; it is backed up with this VM.

> **Nothing here has been applied.** As of 2026-09-04 there is no Cloudflare API
> token — the account is not owned by this operator — so the whole directory is
> written, validated (`tofu validate` → Success, providers resolved and locked)
> and waiting. Everything below is the shortest path from "token exists" to
> "Phase 6 closed".

## Why a new token is needed

None of the existing Cloudflare credentials can manage configuration, and it is
worth being precise about why, because three of them look like they might:

| Credential | What it actually is | Why not |
|---|---|---|
| Wrangler login | OAuth token, `zone:read` + `workers:*` | read-only on zones, no Zero Trust write; also OAuth, not the API token this provider takes |
| `CF_ACCESS_CLIENT_ID/SECRET` | Access **service token** | authenticates *through* Access to a protected app; it is a client credential, not a management one |
| Tunnel token | `{AccountTag,TunnelID,TunnelSecret}` | runs the tunnel, cannot configure it |
| `~/.cloudflared/cert.pem` | would grant tunnel management | **does not exist** — no `cloudflared login` was ever run, because the tunnel was created in the dashboard |

## The token to create

Account **Sunfire** (`1b0e61d1024b78dd4bf289271823192f`), zone `sunosrs.cc`:

| Scope | Level | Needed for |
|---|---|---|
| **Cloudflare Tunnel : Edit** | Account | flipping `config_src` — the one field blocking Phase 6 |
| **DNS : Edit** | Zone (`sunosrs.cc`) | importing and holding the two CNAMEs |
| **Zone : Read** | Zone (`sunosrs.cc`) | resolving the zone |

Add **Transform Rules : Edit** *only* if the MinIO CORS rule turns out to be
needed — see `cloudflare-transform.tf.example`, which argues it may be
vestigial and should perhaps be deleted rather than codified.

Then:

```bash
cp terraform.tfvars.example terraform.tfvars   # gitignored
$EDITOR terraform.tfvars                       # token + zone id
```

## Order of operations

1. **`tofu plan`** — expect it to fail on the DNS `import` blocks, whose IDs are
   `REPLACE_WITH_RECORD_ID` placeholders. Record IDs are unreadable without the
   token, which is exactly why they are placeholders rather than guesses. Fill
   them from `GET /zones/{zone_id}/dns_records`.
2. **`tofu plan` again** — this must report the tunnel's `config_src` changing
   `cloudflare` → `local`, the two DNS records importing with **no** changes,
   and nothing else. A DNS record showing changes means the resource body does
   not match reality; fix the config, never the zone.
3. **`tofu apply`.** The moment `config_src` flips, the already-validated
   `kubernetes/apps/sunfire/cloudflared/app/configmap.yaml` becomes live
   routing. Reloader restarts the connector on the next ConfigMap change from
   then on.
4. **Verify from outside**: both hostnames should still return `HTTP 403`
   (Cloudflare Access rejecting at the edge — the healthy signal). `502` or
   `1033` means the origin map is wrong. `sunfire/DATA-ACCESS.md` has the full
   status-code decoder.

## Proxmox

Separate token, independently obtainable, and **not** required for the
Cloudflare work above. See `proxmox-import.tf.example` — the guests must be
imported with `-generate-config-out` rather than hand-written bodies, because a
mismatched attribute here proposes replacing a running k3s node rather than
showing a cosmetic diff.

## Versions

Providers are constrained in `versions.tf` and exactly pinned by
`.terraform.lock.hcl`, which **is** committed. Renovate's terraform manager
tracks both.
