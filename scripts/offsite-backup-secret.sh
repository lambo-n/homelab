#!/usr/bin/env bash
# Write the `offsite-backup` Secret for the monthly restic -> Backblaze B2 job
# (kubernetes/apps/sunfire/offsite-backup/), SOPS-encrypted.
#
# YOU run this, not the assistant, for the same reason as
# minio-barman-account.sh: every credential here is generated inside the MinIO
# pod or typed at a silent prompt, piped straight into sops, and never printed
# or written in plaintext.
#
#   ./scripts/offsite-backup-secret.sh            # create (refuses if it exists)
#   ./scripts/offsite-backup-secret.sh --rotate   # new MinIO account + B2 key
#
# It asks for four things from the Backblaze console:
#   B2 key ID and application key (hidden) -- an Application Key restricted to
#     the one bucket, with Read and Write
#   S3 endpoint, e.g. s3.us-west-004.backblazeb2.com (Buckets page)
#   bucket name
#
# THE RESTIC PASSWORD IS THE ONE THAT MATTERS. It is generated here on the
# first run and kept on --rotate. Without it the B2 copy cannot be decrypted by
# anyone, you included. Back it up to LastPass straight after the first run:
#   sops -d --extract '["stringData"]["RESTIC_PASSWORD"]' <the file below>
set -euo pipefail

REPO="$HOME/homelab"
BUCKET="sunfire-guide-media"
ACCT_NAME="offsite-restic"
POLICY="$REPO/scripts/minio-offsite-policy.json"
OUT="$REPO/kubernetes/apps/sunfire/offsite-backup/app/secret.sops.yaml"

export SOPS_AGE_KEY_FILE="$REPO/age.key"

ROTATE=0
[ "${1:-}" = "--rotate" ] && ROTATE=1

if [ -f "$OUT" ] && [ "$ROTATE" -eq 0 ]; then
  echo "!! $OUT already exists."
  echo "   Pass --rotate to replace the MinIO account and B2 key."
  exit 1
fi
if [ ! -f "$OUT" ] && [ "$ROTATE" -eq 1 ]; then
  echo "!! --rotate needs an existing $OUT to keep the restic password from."
  exit 1
fi

# --- B2, from the console -------------------------------------------------
read -rp  "B2 S3 endpoint (e.g. s3.us-west-004.backblazeb2.com): " B2_ENDPOINT
read -rp  "B2 bucket name: " B2_BUCKET
read -rsp "B2 key ID (hidden): " B2_KEY_ID; echo
read -rsp "B2 application key (hidden): " B2_APP_KEY; echo
for v in B2_ENDPOINT B2_BUCKET B2_KEY_ID B2_APP_KEY; do
  [ -n "${!v}" ] || { echo "!! $v is empty"; exit 1; }
done
B2_ENDPOINT="${B2_ENDPOINT#https://}"
export B2_KEY_ID B2_APP_KEY
export RESTIC_REPOSITORY="s3:https://$B2_ENDPOINT/$B2_BUCKET/sunfire"

# --- MinIO read-only account on the media bucket --------------------------
POD=$(kubectl -n sunfire get pod -l app=minio -o jsonpath='{.items[0].metadata.name}')
[ -n "$POD" ] || { echo "!! no MinIO pod found"; exit 1; }
echo "   MinIO pod: $POD"

# Root alias, expanded INSIDE the pod (see minio-barman-account.sh).
kubectl -n sunfire exec "$POD" -- sh -c \
  'mc alias set L http://127.0.0.1:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null'
kubectl -n sunfire exec -i "$POD" -- sh -c 'cat > /tmp/offsite-policy.json' < "$POLICY"

if [ "$ROTATE" -eq 1 ]; then
  OLD=$(kubectl -n sunfire exec "$POD" -- mc --json admin user svcacct ls L 2>/dev/null \
        | python3 -c '
import json,sys
for line in sys.stdin:
    try: d = json.loads(line)
    except ValueError: continue
    if "'"$ACCT_NAME"'" in (d.get("name"), d.get("comment")):
        print(d.get("accessKey","")); break
' || true)
  if [ -n "${OLD:-}" ]; then
    kubectl -n sunfire exec "$POD" -- mc admin user svcacct rm L "$OLD"
    echo "   removed previous MinIO account"
  fi
fi

ROOT_USER=$(kubectl -n sunfire get secret minio-credentials \
  -o jsonpath='{.data.MINIO_ROOT_USER}' | base64 -d)
MINIO_JSON=$(kubectl -n sunfire exec "$POD" -- \
  mc --json admin user svcacct add L "$ROOT_USER" \
    --policy /tmp/offsite-policy.json --comment "$ACCT_NAME")
kubectl -n sunfire exec "$POD" -- rm -f /tmp/offsite-policy.json
export MINIO_JSON

# --- restic password: kept on --rotate, generated otherwise ---------------
if [ "$ROTATE" -eq 1 ]; then
  RESTIC_PASSWORD=$(sops -d --extract '["stringData"]["RESTIC_PASSWORD"]' "$OUT")
else
  RESTIC_PASSWORD=$(python3 -c 'import secrets; print(secrets.token_urlsafe(48))')
fi
export RESTIC_PASSWORD

# --- assemble and encrypt --------------------------------------------------
mkdir -p "$(dirname "$OUT")"
python3 -c '
import json, os, sys, yaml
creds = None
for line in os.environ["MINIO_JSON"].splitlines():
    try: d = json.loads(line)
    except ValueError: continue
    if d.get("accessKey") and d.get("secretKey"): creds = d
if not creds:
    sys.exit("!! could not parse accessKey/secretKey out of mc output")
body = {
    "apiVersion": "v1",
    "kind": "Secret",
    "metadata": {"name": "offsite-backup", "namespace": "sunfire"},
    "type": "Opaque",
    "stringData": {
        "RESTIC_REPOSITORY": os.environ["RESTIC_REPOSITORY"],
        "RESTIC_PASSWORD": os.environ["RESTIC_PASSWORD"],
        "B2_KEY_ID": os.environ["B2_KEY_ID"],
        "B2_APP_KEY": os.environ["B2_APP_KEY"],
        "MINIO_ACCESS_KEY": creds["accessKey"],
        "MINIO_SECRET_KEY": creds["secretKey"],
    },
}
sys.stdout.write(yaml.safe_dump(body, sort_keys=False))
' | sops -e --input-type yaml --output-type yaml \
      --filename-override "$OUT" /dev/stdin > "$OUT.tmp"
mv "$OUT.tmp" "$OUT"
unset B2_APP_KEY RESTIC_PASSWORD MINIO_JSON

# Every payload must be ENC[...]; anything else is plaintext about to be
# committed.
enc=$(grep -cE '^[[:space:]]+[A-Z0-9_]+: ENC\[' "$OUT" || true)
if [ "$enc" != 6 ]; then
  echo "!! expected 6 encrypted payloads, found $enc -- do NOT commit $OUT"
  exit 1
fi

echo
echo "   wrote $OUT (6 encrypted keys)"
echo "   repository: $RESTIC_REPOSITORY"
if [ "$ROTATE" -eq 0 ]; then
  echo
  echo "   NOW back up the restic password to LastPass. Without it the B2"
  echo "   copy is unreadable. In your own terminal:"
  echo "     sops -d --extract '[\"stringData\"][\"RESTIC_PASSWORD\"]' \\"
  echo "       $OUT"
fi
