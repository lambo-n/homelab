# The tunnel, and the one field that blocks Phase 6.
#
# `config_src` decides where cloudflared takes its ingress from:
#   "cloudflare" -- the Zero Trust dashboard (today)
#   "local"      -- a YAML file on the origin machine
#
# It is set through the API, so no Kubernetes manifest can change it. Until it
# flips, the validated ingress rules in
# kubernetes/apps/sunfire/cloudflared/app/configmap.yaml are inert: cloudflared
# reads that file for the tunnel UUID and credentials, connects, and then takes
# its routing from the edge anyway -- silently, with nothing in the logs saying
# the local rules were ignored. See GITOPS.md Phase 6.
#
# 🛑 AND IT CANNOT BE FLIPPED IN PLACE. Discovered 2026-09-04 by running the
# plan: the provider marks config_src ForceNew, so setting it to "local" here
# planned `-/+ must be replaced ... this will destroy the imported resource`.
# Replacing the tunnel mints a NEW UUID, which orphans both CNAMEs (they point
# at b42c20c1-....cfargotunnel.com) and invalidates the credentials.json the
# cluster is running. That is a self-inflicted outage, not a conversion.
#
# So config_src is left unmanaged and this resource is import-and-hold only.
# Closing the item needs a different route -- see GITOPS.md Phase 6.
#
# Verified 2026-09-04, once the token existed: the live remote ingress read
#   minio-api.sunosrs.cc -> http://minio.sunfire.svc.cluster.local:9000
#   db.sunosrs.cc        -> http://postgrest.sunfire.svc.cluster.local:3000
#   (catch-all)          -> http_status:404
# which matches configmap.yaml rule for rule and in order. The only differences
# are `originRequest:{}` (empty, a no-op) and `warp-routing`, which exists in the
# remote schema only. So nothing is dropped when local rules take over -- that
# was the one thing that could not be checked when the ConfigMap was written,
# because it was transcribed from a connector log line rather than the API.
import {
  to = cloudflare_zero_trust_tunnel_cloudflared.sunfire
  id = "${var.cloudflare_account_id}/${var.tunnel_id}"
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "sunfire" {
  account_id = var.cloudflare_account_id

  # Real name, read from the API 2026-09-04. It is "sunfire-homelab", not
  # "sunfire" as this file first guessed.
  name = "sunfire-homelab"

  # config_src is DELIBERATELY NOT SET HERE. See the block comment above:
  # the provider treats it as ForceNew, so declaring "local" plans a
  # destroy-and-recreate of the live tunnel rather than an in-place flip.
  # Leaving it unmanaged imports the tunnel and holds it without proposing
  # anything.

  lifecycle {
    # A tunnel replacement changes the UUID, which orphans both CNAMEs and
    # invalidates the credentials.json running in the cluster. There is no
    # legitimate reason for an apply here to destroy this resource, so make it
    # impossible rather than rely on reading the plan carefully every time.
    prevent_destroy = true

    # The tunnel secret is not managed here. It exists as a SOPS-encrypted
    # credentials.json in the cluster, derived from the original token, and
    # rotating it is a deliberate act -- not something an apply should do
    # because a field drifted.
    ignore_changes = [tunnel_secret]
  }
}

# ---------------------------------------------------------------------------
# The actual route to local management.
#
# `config_src` on the tunnel resource above is ForceNew and cannot be used. But
# the same field is exposed as `source` on the CONFIGURATION resource, which is
# a separate object -- so setting it here is a PUT to
# /accounts/{account}/cfd_tunnel/{tunnel}/configurations rather than a
# destroy-and-recreate of the tunnel itself.
#
# With source = "local" and no `config` block, the edge stops serving an ingress
# map and the connector falls back to the file it already has:
# kubernetes/apps/sunfire/cloudflared/app/configmap.yaml, which is validated
# (`ingress validate` -> OK) and byte-for-byte equivalent to what the dashboard
# serves today, modulo the no-op `originRequest:{}` and the remote-only
# `warp-routing` key.
#
# ROLLBACK is cheap and pre-written. Set source = "cloudflare" and restore the
# config block below, whose contents are recorded verbatim in the comment at the
# top of this file. Nothing about the tunnel identity changes either way, so the
# CNAMEs and the cluster's credentials.json are untouched.
import {
  to = cloudflare_zero_trust_tunnel_cloudflared_config.sunfire
  id = "${var.cloudflare_account_id}/${var.tunnel_id}"
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "sunfire" {
  account_id = var.cloudflare_account_id
  tunnel_id  = var.tunnel_id

  # Hand routing to the origin's YAML file. This is the whole change.
  source = "local"
}
