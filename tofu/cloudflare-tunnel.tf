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
# Flipping this one attribute is what makes the ConfigMap live routing.
import {
  to = cloudflare_zero_trust_tunnel_cloudflared.sunfire
  id = "${var.cloudflare_account_id}/${var.tunnel_id}"
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "sunfire" {
  account_id = var.cloudflare_account_id
  name       = "sunfire"

  # THE change. Everything else in this file is import-and-hold.
  config_src = "local"

  lifecycle {
    # The tunnel secret is not managed here. It exists as a SOPS-encrypted
    # credentials.json in the cluster, derived from the original token, and
    # rotating it is a deliberate act -- not something an apply should do
    # because a field drifted.
    ignore_changes = [tunnel_secret]
  }
}
