#!/usr/bin/env bash
# Write the Infisical machine-identity credentials into a SOPS-encrypted Secret.
#
# This is the ONE bootstrap credential the hybrid secrets model needs: the
# operator authenticates with it before it can fetch anything else, so it cannot
# itself come from Infisical. GITOPS.md "Secrets: hybrid" accepts that
# deliberately -- age.key stays alive holding exactly one secret.
#
# YOU run this, from a REAL terminal: it prompts with input hidden, and a
# hidden prompt needs a TTY. Running it behind the `!` prefix silently reads
# empty input and writes nothing.
#
#   ./scripts/infisical-identity-secret.sh
#
# Values are read into variables, piped straight into sops, and never printed,
# never written in plaintext and never placed in argv -- same discipline as
# cloudflared-new-local-tunnel.sh and minio-barman-account.sh.
#
# Where the values come from, in the Infisical dashboard:
#   Organization Access Control -> Identities -> the project's machine identity
#   -> Universal Auth. The Client ID is displayed. The Client Secret is shown
#   ONCE at creation -- if it was not saved, create a new client secret there
#   and this script takes the new one. Old secrets can be revoked afterwards.
set -euo pipefail

REPO="$HOME/homelab"
OUT="$REPO/kubernetes/apps/sunfire/infisical/app/credentials.sops.yaml"

export SOPS_AGE_KEY_FILE="$REPO/age.key"
command -v sops >/dev/null || { echo "!! sops not on PATH -- run from a mise-activated shell"; exit 1; }
[ -t 0 ] || { echo "!! no TTY -- run this in a real terminal, not behind the '!' prefix"; exit 1; }

printf 'Infisical machine identity Client ID: '
IFS= read -r CLIENT_ID
printf 'Infisical machine identity Client Secret (hidden): '
IFS= read -rs CLIENT_SECRET
printf '\n'

[ -n "$CLIENT_ID" ]     || { echo "!! empty client id -- nothing written";     exit 1; }
[ -n "$CLIENT_SECRET" ] || { echo "!! empty client secret -- nothing written"; exit 1; }

# The operator reads these two keys by these exact names; they are not
# arbitrary. See the credentialsRef in infisicalsecret.yaml.
CLIENT_ID="$CLIENT_ID" CLIENT_SECRET="$CLIENT_SECRET" python3 -c '
import os, sys, yaml
body = {"apiVersion": "v1", "kind": "Secret",
        "metadata": {"name": "infisical-machine-identity", "namespace": "sunfire"},
        "type": "Opaque",
        "stringData": {"clientId":     os.environ["CLIENT_ID"],
                       "clientSecret": os.environ["CLIENT_SECRET"]}}
sys.stdout.write(yaml.safe_dump(body, sort_keys=False))
' | sops -e --input-type yaml --output-type yaml --filename-override "$OUT" /dev/stdin > "$OUT"
unset CLIENT_SECRET CLIENT_ID

# Prove both values encrypted. A plaintext credential committed to a private
# repo is still a plaintext credential.
for key in clientId clientSecret; do
  n=$(grep -cE "^[[:space:]]+${key}: ENC\[" "$OUT" || true)
  if [ "$n" != 1 ]; then
    echo "!! $key is not encrypted in $OUT -- do NOT commit it"
    exit 1
  fi
done

echo "   wrote $OUT (both values ENC[...])"
echo "   next: wire it in -- add infisical/ks.yaml to kubernetes/apps/sunfire/kustomization.yaml"
