# ---------------------------------------------------------------------------
# No tunnel resources are managed here, deliberately. This file is the record of
# why, because both facts below cost a detour to establish and both are reported
# by the API in ways that point at the wrong cause.
#
# 1. `config_src` is IMMUTABLE after tunnel creation.
#
#    Cloudflare reports the refusal as `1002 Tunnel not found`, which reads like
#    a wrong id or an under-scoped token and is neither. Isolated with three
#    calls, one token, one tunnel:
#
#      GET   /cfd_tunnel/{id}                 -> success: true
#      PATCH {"name":"sunfire-homelab"}       -> success: true   (writes allowed)
#      PATCH {"config_src":"local"}           -> 1002 Tunnel not found
#
#    Writes are permitted; that one field is not editable. So the original
#    remotely-managed tunnel could never be converted, and the only route to
#    local management was a NEW tunnel created with config_src: "local".
#    That is what scripts/cloudflared-new-local-tunnel.sh does.
#
# 2. The configurations endpoint will not store an empty config.
#
#    `source = "local"` with `config = {}` returns `1056 Bad Configuration:
#    Validation failed: The config file doesn't contain any ingress rules` -- it
#    insists on ingress rules even when setting the mode that makes stored rules
#    irrelevant. So there was no way to hand routing to the origin through that
#    resource either.
#
# 3. The provider cannot update the tunnel object at all.
#
#    `cloudflare_zero_trust_tunnel_cloudflared` imported cleanly and then failed
#    its update with the same 1002, on a tunnel it had read seconds earlier,
#    with nothing declared that differed from reality. Managing that object buys
#    nothing anyway: its identity is the only thing that matters and must never
#    change.
#
# The tunnel in use is created and owned OUTSIDE tofu, by the script above, and
# its credentials live SOPS-encrypted in the cluster. What tofu owns is DNS --
# see cloudflare-dns.tf, where `var.tunnel_id` is what actually cuts traffic
# from one tunnel to the other.
# ---------------------------------------------------------------------------
