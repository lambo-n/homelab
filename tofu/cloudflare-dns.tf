# The two public hostnames, as CNAMEs onto the tunnel.
#
# Both records predate this config. The import blocks brought them under
# management WITHOUT recreating them -- imported and applied 2026-09-04, and
# they are now in state. The blocks stay because they are a no-op once the
# resource is in state, and they are the documentation of where these came from.
#
# The apply that followed is what actually performed the tunnel cutover: the
# local-management conversion needed a NEW tunnel (config_src is immutable), so
# `content` moved from the old UUID to the new one on both records at once.
# That is why var.tunnel_id is a variable and not a literal.
#
# Both are proxied. That is load-bearing, not cosmetic: an unproxied record
# would expose the origin directly and bypass the Cloudflare Access policy that
# is the outermost layer of the access model (sunfire/homelab/README.md).

import {
  to = cloudflare_dns_record.minio_api
  id = "${var.cloudflare_zone_id}/963e0e236db13d9629adc61bd284a8e1"
}

resource "cloudflare_dns_record" "minio_api" {
  zone_id = var.cloudflare_zone_id
  name    = "minio-api.sunosrs.cc"
  type    = "CNAME"
  content = "${var.tunnel_id}.cfargotunnel.com"
  proxied = true
  ttl     = 1 # 1 = automatic; required when proxied
  comment = "S3 API. Worker signs SigV4 against this host; the signature covers Host."
}

import {
  to = cloudflare_dns_record.db
  id = "${var.cloudflare_zone_id}/20bfe3eaabd1cc62870990a4c30ada7c"
}

resource "cloudflare_dns_record" "db" {
  zone_id = var.cloudflare_zone_id
  name    = "db.sunosrs.cc"
  type    = "CNAME"
  content = "${var.tunnel_id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
  comment = "PostgREST."
}
