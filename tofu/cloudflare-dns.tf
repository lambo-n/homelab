# The two public hostnames, as CNAMEs onto the tunnel.
#
# These already exist and already point at <tunnel-id>.cfargotunnel.com -- the
# local-management conversion did not touch them, because it reused the same
# tunnel UUID. These blocks exist to bring them under management WITHOUT
# recreating them, which is what the import blocks are for.
#
# Both are proxied. That is load-bearing, not cosmetic: an unproxied record
# would expose the origin directly and bypass the Cloudflare Access policy that
# is the outermost layer of the access model (sunfire/homelab/README.md).

import {
  to = cloudflare_dns_record.minio_api
  id = "${var.cloudflare_zone_id}/REPLACE_WITH_RECORD_ID"
}

resource "cloudflare_dns_record" "minio_api" {
  zone_id = var.cloudflare_zone_id
  name    = "minio-api"
  type    = "CNAME"
  content = "${var.tunnel_id}.cfargotunnel.com"
  proxied = true
  ttl     = 1 # 1 = automatic; required when proxied
  comment = "S3 API. Worker signs SigV4 against this host; the signature covers Host."
}

import {
  to = cloudflare_dns_record.db
  id = "${var.cloudflare_zone_id}/REPLACE_WITH_RECORD_ID"
}

resource "cloudflare_dns_record" "db" {
  zone_id = var.cloudflare_zone_id
  name    = "db"
  type    = "CNAME"
  content = "${var.tunnel_id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
  comment = "PostgREST."
}
