#!/usr/bin/env bash
# Write the `searxng` Secret (kubernetes/apps/search/searxng/), SOPS-encrypted.
#
# YOU run this, not the assistant, for the same reason as
# offsite-backup-secret.sh: the key is generated here, piped straight into
# sops, and never printed or written in plaintext.
#
#   ./scripts/searxng-secret.sh            # create (refuses if it exists)
#   ./scripts/searxng-secret.sh --rotate   # new key
#
# SearXNG signs its session cookies with this key (`SEARXNG_SECRET`). It has no
# login, so rotating it only invalidates cookies; nothing else depends on it.
set -euo pipefail

REPO="$HOME/homelab"
OUT="$REPO/kubernetes/apps/search/searxng/app/secret.sops.yaml"

export SOPS_AGE_KEY_FILE="$REPO/age.key"

ROTATE=0
[ "${1:-}" = "--rotate" ] && ROTATE=1

if [ -f "$OUT" ] && [ "$ROTATE" -eq 0 ]; then
  echo "!! $OUT already exists."
  echo "   Pass --rotate to replace the key."
  exit 1
fi
if [ ! -f "$OUT" ] && [ "$ROTATE" -eq 1 ]; then
  echo "!! --rotate needs an existing $OUT."
  exit 1
fi

mkdir -p "$(dirname "$OUT")"
python3 -c '
import secrets, sys, yaml
body = {
    "apiVersion": "v1",
    "kind": "Secret",
    "metadata": {"name": "searxng", "namespace": "search"},
    "type": "Opaque",
    "stringData": {"SEARXNG_SECRET": secrets.token_hex(32)},
}
sys.stdout.write(yaml.safe_dump(body, sort_keys=False))
' | sops -e --input-type yaml --output-type yaml \
      --filename-override "$OUT" /dev/stdin > "$OUT.tmp"
mv "$OUT.tmp" "$OUT"

# The payload must be ENC[...]; anything else is plaintext about to be committed.
enc=$(grep -cE '^[[:space:]]+SEARXNG_SECRET: ENC\[' "$OUT" || true)
if [ "$enc" != 1 ]; then
  echo "!! expected 1 encrypted payload, found $enc -- do NOT commit $OUT"
  exit 1
fi

echo "   wrote $OUT (1 encrypted key)"
