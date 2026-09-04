#!/usr/bin/env bash
# Create a NEW locally-managed cloudflared tunnel and wire the cluster to it.
#
# WHY a new tunnel: config_src is immutable after creation. Proven against the
# API -- GET succeeds, PATCH {"name":...} succeeds, PATCH {"config_src":"local"}
# returns 1002 "Tunnel not found". So the existing remotely-managed tunnel can
# never become locally-managed; the only route is a new one. See tofu/README.md.
#
# YOU run this: it needs CLOUDFLARE_API_TOKEN, which lives in your shell.
#
#   export CLOUDFLARE_API_TOKEN=...      # Cloudflare Tunnel:Edit on the account
#   ./scripts/cloudflared-new-local-tunnel.sh
#
# The tunnel secret is generated here, sent once to the API, piped straight into
# sops and never printed or written in plaintext -- same discipline as
# minio-barman-account.sh.
#
# This script does NOT touch DNS and does NOT delete the old tunnel. Both are
# deliberate: DNS is managed in tofu/ and is the actual cutover, and the old
# tunnel stays alive as the rollback path until you have verified the new one.
set -euo pipefail

REPO="$HOME/homelab"
ACCOUNT="1b0e61d1024b78dd4bf289271823192f"
NAME="${TUNNEL_NAME:-sunfire-local}"
API="https://api.cloudflare.com/client/v4"
CM="$REPO/kubernetes/apps/sunfire/cloudflared/app/configmap.yaml"
OUT="$REPO/kubernetes/apps/sunfire/cloudflared/app/credentials.sops.yaml"

export SOPS_AGE_KEY_FILE="$REPO/age.key"

[ -n "${CLOUDFLARE_API_TOKEN:-}" ] || { echo "!! CLOUDFLARE_API_TOKEN is not set"; exit 1; }
command -v sops >/dev/null || { echo "!! sops not on PATH -- run from a mise-activated shell"; exit 1; }

# 32 bytes, base64. This is the only copy; it goes to the API and to sops.
SECRET=$(head -c 32 /dev/urandom | base64 -w0)

echo "   creating tunnel '$NAME' with config_src=local ..."
RESP=$(curl -s -X POST "$API/accounts/$ACCOUNT/cfd_tunnel" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$(printf '{"name":"%s","config_src":"local","tunnel_secret":"%s"}' "$NAME" "$SECRET")")

if [ "$(printf '%s' "$RESP" | jq -r '.success')" != "true" ]; then
  echo "!! tunnel creation failed:"
  printf '%s' "$RESP" | jq -c '.errors'
  exit 1
fi

TID=$(printf '%s' "$RESP" | jq -r '.result.id')
SRC=$(printf '%s' "$RESP" | jq -r '.result.config_src')
echo "   tunnel id : $TID"
echo "   config_src: $SRC"

if [ "$SRC" != "local" ]; then
  echo "!! config_src came back '$SRC', not 'local'. Refusing to continue --"
  echo "   a remotely-managed tunnel is what we already have. Delete it:"
  echo "   curl -X DELETE $API/accounts/$ACCOUNT/cfd_tunnel/$TID -H \"Authorization: Bearer \$CLOUDFLARE_API_TOKEN\""
  exit 1
fi

# credentials.json -> Secret -> sops, in one pipeline. The secret never lands.
ACCOUNT="$ACCOUNT" TID="$TID" SECRET="$SECRET" python3 -c '
import json, os, sys, yaml
creds = {"AccountTag": os.environ["ACCOUNT"],
         "TunnelID":   os.environ["TID"],
         "TunnelSecret": os.environ["SECRET"]}
body = {"apiVersion": "v1", "kind": "Secret",
        "metadata": {"name": "cloudflared-credentials", "namespace": "sunfire"},
        "type": "Opaque",
        "stringData": {"credentials.json": json.dumps(creds, separators=(",", ":"))}}
sys.stdout.write(yaml.safe_dump(body, sort_keys=False))
' | sops -e --input-type yaml --output-type yaml --filename-override "$OUT" /dev/stdin > "$OUT"
unset SECRET

enc=$(grep -cE '^[[:space:]]+credentials\.json: ENC\[' "$OUT" || true)
if [ "$enc" != 1 ]; then
  echo "!! credentials payload is not encrypted -- do NOT commit $OUT"
  exit 1
fi
echo "   wrote $OUT (encrypted)"

# Point the ConfigMap's config.yaml at the new tunnel.
sed -i -E "s|^(    tunnel: ).*|\1$TID|" "$CM"
grep -E '^    tunnel: ' "$CM"

cat <<NEXT

   Cluster manifests updated. NOTHING is live yet -- DNS still points at the old
   tunnel, so the new one has no traffic.

   Next, in order:
     1. Review:  git -C $REPO diff
     2. Set the new id in tofu:  tofu/variables.tf -> tunnel_id default
     3. Commit and push, then run 'tofu apply' to repoint both CNAMEs.
        Between those two the site returns 502 -- keep the gap short.
     4. Verify, then delete the old tunnel.
NEXT
