#!/usr/bin/env bash
# Swap the cloudflared tunnel token in the SOPS-encrypted secret.
#
# Reads the raw token from a file (default ~/.tunnel-token), validates it,
# writes it into kubernetes/apps/sunfire/cloudflared/app/secret.sops.yaml, and
# leaves the commit/push to the caller. The token is never echoed.
#
# Quirk 5 (CUTOVER.md): a trailing newline invalidates the token, so strip.
set -euo pipefail

REPO="$HOME/homelab"
SECRET="$REPO/kubernetes/apps/sunfire/cloudflared/app/secret.sops.yaml"
SRC="${1:-$HOME/.tunnel-token}"

export SOPS_AGE_KEY_FILE="$REPO/age.key"

[ -f "$SRC" ] || { echo "!! no token file at $SRC"; exit 1; }

python3 - "$SRC" "$SECRET" <<'PY'
import base64, json, subprocess, sys, os

src, secret = sys.argv[1], sys.argv[2]
tok = open(src, 'rb').read().decode('utf-8', 'strict').strip()

if not tok:
    sys.exit("!! token file is empty")
if any(c.isspace() for c in tok):
    sys.exit("!! token contains interior whitespace -- likely a bad paste")

# Quirk 2: the token is base64 JSON {"a": account, "t": tunnel uuid, "s": secret}.
try:
    payload = json.loads(base64.b64decode(tok + '=' * (-len(tok) % 4)))
except Exception as e:
    sys.exit(f"!! token is not base64 JSON ({e}) -- copy the raw token, not the install command")
missing = {'a', 't', 's'} - set(payload)
if missing:
    sys.exit(f"!! token JSON missing key(s): {sorted(missing)}")

old = subprocess.run(['sops', '-d', secret], capture_output=True, text=True, check=True).stdout
old_tok = next(l.split(':', 1)[1].strip() for l in old.splitlines() if l.strip().startswith('token:'))
old_payload = json.loads(base64.b64decode(old_tok + '=' * (-len(old_tok) % 4)))

print(f"   old account {old_payload['a'][:8]}…  tunnel {old_payload['t'][:8]}…")
print(f"   new account {payload['a'][:8]}…  tunnel {payload['t'][:8]}…")
if payload['a'] == old_payload['a']:
    print("   !! WARNING: same account tag as the token already in git.")
    print("      Quirk 2: moving accounts is necessarily a NEW token. Check you")
    print("      copied from the Sunfire account, not the retired one.")
if payload['t'] == old_payload['t']:
    print("   !! WARNING: same tunnel UUID -- this looks like the existing token.")

subprocess.run(['sops', 'set', secret, '["stringData"]["token"]', json.dumps(tok)], check=True)
print("   wrote new token into secret.sops.yaml")
PY

# Confirm it round-trips and that no newline snuck in.
sops -d "$SECRET" | python3 -c '
import sys, yaml
t = yaml.safe_load(sys.stdin)["stringData"]["token"]
assert t == t.strip(), "!! stored token has surrounding whitespace"
print(f"   verified: decrypts to {len(t)} chars, no stray whitespace")
'
