#!/usr/bin/env bash
# Create the MinIO bucket and scoped service account that CNPG's barman-cloud
# plugin backs up into, and write the credential into the repo SOPS-encrypted.
#
# YOU run this, not the assistant, so the credential never appears in any
# assistant output (AGENTS.md rule 3). The keys are generated inside the pod,
# piped straight into sops, and never printed or written in plaintext. (This
# once also said the assistant could not `kubectl exec`. That is no longer true.)
#
#   ./scripts/minio-barman-account.sh            # create (refuses if it exists)
#   ./scripts/minio-barman-account.sh --rotate   # replace an existing account
#
# Afterwards: review the diff, commit, push. Flux does the rest.
#
# Two traps from RUNBOOK.md are already handled below:
#   * the `mc alias set` must expand $MINIO_ROOT_* INSIDE the pod -- if the host
#     expands them first, mc still says "Added successfully" and every later
#     call 403s;
#   * `kubectl cp` does not work against this image (no `tar`), and the image
#     has no sed/grep/awk, so the policy goes in over stdin via `cat` and all
#     parsing happens here on the host.
set -euo pipefail

REPO="$HOME/homelab"
BUCKET="sunfire-postgres-backups"
ACCT_NAME="cnpg-barman"
POLICY="$REPO/scripts/minio-barman-policy.json"
OUT="$REPO/kubernetes/apps/sunfire/postgres-cnpg/app/objectstore-secret.sops.yaml"

export SOPS_AGE_KEY_FILE="$REPO/age.key"

ROTATE=0
[ "${1:-}" = "--rotate" ] && ROTATE=1

if [ -f "$OUT" ] && [ "$ROTATE" -eq 0 ]; then
  echo "!! $OUT already exists."
  echo "   Pass --rotate to replace the account and overwrite it."
  exit 1
fi

POD=$(kubectl -n sunfire get pod -l app=minio -o jsonpath='{.items[0].metadata.name}')
[ -n "$POD" ] || { echo "!! no MinIO pod found"; exit 1; }
echo "   MinIO pod: $POD"

# Root alias, expanded inside the pod.
kubectl -n sunfire exec "$POD" -- sh -c \
  'mc alias set L http://127.0.0.1:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null'

# Bucket. `mc mb --ignore-existing` is idempotent.
kubectl -n sunfire exec "$POD" -- mc mb --ignore-existing "L/$BUCKET"
echo "   bucket ready: $BUCKET"

# NOTE: versioning is deliberately NOT enabled on this bucket, unlike
# sunfire-guide-media. Barman manages its own retention and expires old
# backups by deleting objects; versioning would keep every one of those
# deletions as a version, so the bucket would grow without bound and the
# retentionPolicy in the ObjectStore would quietly stop reclaiming anything.

kubectl -n sunfire exec -i "$POD" -- sh -c 'cat > /tmp/barman-policy.json' < "$POLICY"

if [ "$ROTATE" -eq 1 ]; then
  OLD=$(kubectl -n sunfire exec "$POD" -- mc --json admin user svcacct ls L 2>/dev/null \
        | python3 -c '
import json,sys
for line in sys.stdin:
    try: d = json.loads(line)
    except ValueError: continue
    if d.get("name") == "'"$ACCT_NAME"'" or d.get("comment") == "'"$ACCT_NAME"'":
        print(d.get("accessKey","")); break
' || true)
  if [ -n "${OLD:-}" ]; then
    kubectl -n sunfire exec "$POD" -- mc admin user svcacct rm L "$OLD"
    echo "   removed previous service account"
  fi
fi

# Create the scoped account. Output is JSON on stdout; it holds the only copy
# of the secret key, so it goes straight into the pipeline below.
CREDS=$(kubectl -n sunfire exec "$POD" -- \
  mc --json admin user svcacct add L "$(kubectl -n sunfire get secret minio-credentials \
      -o jsonpath='{.data.MINIO_ROOT_USER}' | base64 -d)" \
      --policy /tmp/barman-policy.json --comment "$ACCT_NAME")

kubectl -n sunfire exec "$POD" -- rm -f /tmp/barman-policy.json

mkdir -p "$(dirname "$OUT")"
printf '%s' "$CREDS" | python3 -c '
import json, sys, yaml
creds = None
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
    except ValueError:
        continue
    if d.get("accessKey") and d.get("secretKey"):
        creds = d
if not creds:
    sys.exit("!! could not parse accessKey/secretKey out of mc output")
body = {
    "apiVersion": "v1",
    "kind": "Secret",
    "metadata": {"name": "postgres-backup-s3", "namespace": "sunfire"},
    "type": "Opaque",
    "stringData": {
        "ACCESS_KEY_ID": creds["accessKey"],
        "ACCESS_SECRET_KEY": creds["secretKey"],
    },
}
sys.stdout.write(yaml.safe_dump(body, sort_keys=False))
' | sops -e --input-type yaml --output-type yaml --filename-override "$OUT" /dev/stdin > "$OUT"

# Prove it round-trips and that nothing plaintext landed in the file.
sops -d "$OUT" | python3 -c '
import sys, yaml
d = yaml.safe_load(sys.stdin)["stringData"]
assert d["ACCESS_KEY_ID"] and d["ACCESS_SECRET_KEY"], "empty credential"
print("   access key id length:", len(d["ACCESS_KEY_ID"]))
print("   secret key length   :", len(d["ACCESS_SECRET_KEY"]))
'
# Both payloads must be ENC[...]; anything else means a plaintext key is sitting
# in a file about to be committed. grep -E has no lookahead, so count the
# encrypted lines rather than trying to match the negative case.
enc=$(grep -cE '^[[:space:]]+ACCESS_(KEY_ID|SECRET_KEY): ENC\[' "$OUT" || true)
if [ "$enc" != 2 ]; then
  echo "!! expected 2 encrypted payloads, found $enc -- do NOT commit $OUT"
  exit 1
fi

echo
echo "   wrote $OUT"
echo "   Scoped to $BUCKET only -- it cannot touch sunfire-guide-media."
echo "   Review the diff, then commit and push."
