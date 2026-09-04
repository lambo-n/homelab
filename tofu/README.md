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

### Creating it

1. **dash.cloudflare.com → My Profile → API Tokens → Create Token → Create Custom Token.**
2. Permissions — all three, exactly:

   | Type | Resource | Level |
   |---|---|---|
   | Account | Cloudflare Tunnel | Edit |
   | Zone | DNS | Edit |
   | Zone | Zone | Read |

3. **Account Resources:** Include → Sunfire.
   **Zone Resources:** Include → Specific zone → `sunosrs.cc`.
4. Continue → Create. **The token is shown once.**

### Loading it — without writing it to disk

```bash
read -rs CLOUDFLARE_API_TOKEN && export CLOUDFLARE_API_TOKEN
```

`read -rs` keeps it out of shell history. The provider reads
`CLOUDFLARE_API_TOKEN` natively, so nothing needs to go in `terraform.tfvars`.

### Verify it before using it

```bash
curl -s https://api.cloudflare.com/client/v4/user/tokens/verify \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" | jq '.success, .result.status'
```

Expect `true` and `"active"`. A token missing a scope still verifies — the
scopes are checked at use, so a later 403 on a specific call means a missing
permission, not a bad token.

### The two IDs the config needs

```bash
# Zone id
curl -s "https://api.cloudflare.com/client/v4/zones?name=sunosrs.cc" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" | jq -r '.result[0].id'

# DNS record ids -- these replace REPLACE_WITH_RECORD_ID in cloudflare-dns.tf
ZONE=<zone id from above>
for h in minio-api db; do
  printf '%s ' "$h"
  curl -s "https://api.cloudflare.com/client/v4/zones/$ZONE/dns_records?name=$h.sunosrs.cc" \
    -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" | jq -r '.result[0].id'
done
```

Put the zone id in `terraform.tfvars` (it is not secret) and paste each record
id into the matching `import` block.

### Worth reading before the apply

```bash
curl -s "https://api.cloudflare.com/client/v4/accounts/1b0e61d1024b78dd4bf289271823192f/cfd_tunnel/b42c20c1-2d20-43ee-a17c-15f9849e5f13/configurations" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" | jq '.result.config'
```

That is the dashboard ingress the connector is using today. It should match
`kubernetes/apps/sunfire/cloudflared/app/configmap.yaml` rule for rule, modulo
the `warp-routing` key that only exists in the remote schema. **If it does not
match, stop** -- the local rules are what take over the moment `config_src`
flips, and a difference here is a difference in live routing.

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

## Gotchas hit on the first real apply (2026-09-04)

Both are provider-side, and both are recorded because the next person will hit
them identically.

**The tunnel object cannot be managed.** `cloudflare_zero_trust_tunnel_cloudflared`
imported fine and then failed its update with `PATCH … 404 {"code":1002,"message":
"Tunnel not found"}` — on a tunnel it had read seconds earlier. Nothing declared
on it differed from reality, so it attempted a write for computed drift alone.
It is no longer in this config. If it is still in your state from an earlier
run, `tofu state rm cloudflare_zero_trust_tunnel_cloudflared.sunfire` — removing
a resource from config while it remains in state makes the next plan propose
**destroying** it, and the `prevent_destroy` guard leaves with the block.

**`config_src` is ForceNew on the tunnel, and unusable.** Declaring it plans a
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

Separate token, independently obtainable, and **not** required for the
Cloudflare work above. See `proxmox-import.tf.example` — the guests must be
imported with `-generate-config-out` rather than hand-written bodies, because a
mismatched attribute here proposes replacing a running k3s node rather than
showing a cosmetic diff.

## Versions

Providers are constrained in `versions.tf` and exactly pinned by
`.terraform.lock.hcl`, which **is** committed. Renovate's terraform manager
tracks both.
