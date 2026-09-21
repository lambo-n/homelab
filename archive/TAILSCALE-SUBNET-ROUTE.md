# Tailscale subnet route — history

> 📦 **Archived 2026-09-21.** How the approved `192.168.50.0/24` subnet route
> was found, why it was a gap, and how it was restricted. The current
> configuration lives in [`../GITOPS.md`](../GITOPS.md#tailscale-host) and
> [`../tailscale/policy.hujson`](../tailscale/policy.hujson).

## 2026-09-09 — found

Not by reading the docs: a client failed to reach `.101`, and `tailscale
status` reported *"Some peers are advertising routes but --accept-routes is
false"*. The route had been approved for an unknown length of time and no
document mentioned it.

`README.md` said administrative access "is SSH-mediated and recorded to
`/var/log/ts-ssh-records`". That described the `ProxyJump` path only. With the
route approved, any tailnet device running `--accept-routes` had layer-3 reach
to every port on every LAN host — Proxmox `:8006`, the k3s API, Traefik, NFS
on `.101` — without an SSH session and so without a session log.

Two conclusions were drawn, and only the second was a real gap:

1. **The session logs were not weakened.** They still captured every SSH
   session; they were never a complete record of *access*, because an L3 route
   is not an SSH session. The README sentence claimed more than the control
   delivered, and was corrected.
2. **Nothing enforced the boundary at the network layer.** The tailnet policy
   was not in the repo and its contents were unverified, so tailnet membership
   was, as far as anyone could tell, the whole security model for LAN access.

The same day, from a laptop off the LAN: before `--accept-routes`, an
unauthenticated `GET https://192.168.50.101:8006/api2/json/version` returned
`000`; after, `401`. That is where the "`000` is routing, `401` is auth" rule
in `GITOPS.md` comes from.

The decision was deferred to `BACKLOG.md` with three options: leave it,
restrict it with a policy, or drop the route for `ProxyJump` only.

## 2026-09-21 — restricted

The policy turned out to be the console default, allow-all:

```
{"src": ["*"], "dst": ["*"], "ip": ["*"]}
```

That confirmed conclusion 2. The owner chose to keep the route and restrict
it. Only the laptop and the home PC use the homelab, so the new policy grants
`autogroup:member` four destinations (gateway `:22`, PVE `:8006`, `.104`
`:80`/`:8123`, exit node) and denies everything else. The `ssh` block was left
at the console default. Reading it showed there is no `recorder`, and the
owner confirmed that `/var/log/ts-ssh-records` is written by a daemon on the
gateway, not by Tailscale. The README had labelled those logs "Tailscale SSH
recordings", and that label was corrected.

Verified from the laptop, off the LAN, with `--accept-routes`:

| Test | Result |
|---|---|
| `ssh dev 'hostname'` (ProxyJump) | `dev` |
| `curl -skI https://192.168.50.101:8006/api2/json/version` | `501 method 'HEAD' not available` — PVE answered |
| `curl -sI -H 'Host: grafana.homelab.lan' 192.168.50.104` | `302 Found` |
| `curl … http://192.168.50.107:8080/v1/models` | `000` |
| `curl … https://192.168.50.104:6443/version` | `000` |

The LLM result also closed a separate backlog item. It had asked whether
`llm`'s `ufw` rule (deny `:8080`/`:8081` from `.102`) held against a routed
device, and it had never been tested from the tailnet.

The first attempt at the curl tests failed because the pasted lines wrapped in
the laptop's fish shell. That had nothing to do with the policy.
