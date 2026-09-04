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
# It can be run from anywhere -- it cd's into the repo itself, because the
# toolchain pins live in ./mise.toml and the sops shim resolves to "No version
# is set for shim: sops" from any other directory.
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

# Staged here first; $OUT is only written once the payload is verified encrypted.
TMP="$(mktemp)"
chmod 600 "$TMP"
trap 'rm -f "$TMP"' EXIT

export SOPS_AGE_KEY_FILE="$REPO/age.key"

# mise resolves tool versions from the config in the CURRENT directory tree.
# sops is pinned in $REPO/mise.toml, so from anywhere else the shim exists on
# PATH and then fails at runtime with "No version is set for shim: sops".
cd "$REPO"

# Check that sops RUNS, not merely that something named sops is on PATH --
# those are different questions when shims are involved, and the difference
# only shows up after the prompt has already consumed a one-shot credential.
sops --version >/dev/null 2>&1 || {
  echo "!! sops is not runnable here. If this says 'No version is set for shim',"
  echo "   the mise config was not picked up: run 'mise install' in $REPO."
  exit 1
}
[ -t 0 ] || { echo "!! no TTY -- run this in a real terminal, not behind the '!' prefix"; exit 1; }

# Everything above must pass BEFORE prompting. The client secret is shown once
# by Infisical; failing after reading it costs the user a rotation.
printf 'Infisical machine identity Client ID: '
IFS= read -r CLIENT_ID
printf 'Infisical machine identity Client Secret (hidden): '
IFS= read -rs CLIENT_SECRET
printf '\n'

[ -n "$CLIENT_ID" ]     || { echo "!! empty client id -- nothing written";     exit 1; }
[ -n "$CLIENT_SECRET" ] || { echo "!! empty client secret -- nothing written"; exit 1; }

# Shape checks. These exist because a terminal paste of a long value is not
# reliably a paste of that value: the first real run stored the 64-char secret
# TWICE, joined by a backslash at position 64, from line-wrapping. It encrypted
# and committed cleanly and would have failed only as a Pending InfisicalSecret
# in the cluster, which is this operator's silent failure mode.
#
# Nothing here prints a value -- only what is wrong with it.
CLIENT_ID="$CLIENT_ID" CLIENT_SECRET="$CLIENT_SECRET" python3 - <<'PYCHECK' || exit 1
import os, re, sys
cid, sec = os.environ["CLIENT_ID"], os.environ["CLIENT_SECRET"]
bad = []
if not re.fullmatch(r"[0-9a-f-]{36}", cid):
    bad.append("client id is not a 36-char UUID (got %d chars)" % len(cid))
if "\\" in sec or any(c.isspace() for c in sec):
    bad.append("client secret contains a backslash or whitespace -- almost certainly a wrapped paste")
half = len(sec) // 2
if len(sec) % 2 == 0 and half and sec[:half] == sec[half:]:
    bad.append("client secret is the same value twice -- a doubled paste")
if not re.fullmatch(r"[0-9a-f]{64}", sec):
    bad.append("client secret is not 64 lowercase hex chars (got %d)" % len(sec))
if bad:
    sys.stderr.write("!! refusing to write:\n" + "".join("   - %s\n" % b for b in bad))
    sys.stderr.write("   re-run and paste again; nothing was written.\n")
    sys.exit(1)
PYCHECK

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
' | sops -e --input-type yaml --output-type yaml --filename-override "$OUT" /dev/stdin > "$TMP"
unset CLIENT_SECRET CLIENT_ID

# Prove both values encrypted BEFORE the file reaches its destination. Writing
# the redirect straight at $OUT is what the first version did, and it truncates
# the target before sops has run -- so a mid-pipeline failure leaves either an
# empty file or, if sops fails after python has written, a plaintext one sitting
# at a path the next commit would pick up.
for key in clientId clientSecret; do
  n=$(grep -cE "^[[:space:]]+${key}: ENC\[" "$TMP" || true)
  if [ "$n" != 1 ]; then
    echo "!! $key is not encrypted -- refusing to write $OUT"
    exit 1
  fi
done

mv "$TMP" "$OUT"
chmod 600 "$OUT"

echo "   wrote $OUT (both values ENC[...])"
echo "   next: wire it in -- add infisical/ks.yaml to kubernetes/apps/sunfire/kustomization.yaml"
