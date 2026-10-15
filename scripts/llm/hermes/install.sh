#!/usr/bin/env bash
# Install or update Hermes Agent with this repo's config, on any Linux machine
# on the LAN (GPU-VM.md → Consumers). Re-run after editing config.yaml or
# SOUL.md; pass --config-only to skip the installer.
#
#   scripts/llm/hermes/install.sh [--config-only]
#
# Needs ~/.config/llama/api-key (mode 600) holding an API key for VM 105's
# router. This script never reads or prints it; copying it is the owner's step.
set -euo pipefail

VERSION=v2026.9.24
HERE=$(cd "$(dirname "$0")" && pwd)
HERMES_HOME=${HERMES_HOME:-$HOME/.hermes}
KEY=$HOME/.config/llama/api-key

if [[ ${1:-} != --config-only ]]; then
  # The tag's own installer, not the site's: that one serves main.
  url=https://raw.githubusercontent.com/NousResearch/hermes-agent/$VERSION/scripts/install.sh
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL "$url" -o "$tmp/install.sh"
  # It asks for sudo for ripgrep and build headers even when present; with no
  # answer it carries on.
  bash "$tmp/install.sh" --branch "$VERSION" --skip-setup --skip-browser \
    --skip-computer-use --non-interactive </dev/null
fi

install -d -m 700 "$HERMES_HOME"
install -m 600 "$HERE/config.yaml" "$HERMES_HOME/config.yaml"
install -m 644 "$HERE/SOUL.md" "$HERMES_HOME/SOUL.md"
echo "config.yaml and SOUL.md installed in $HERMES_HOME"

if [[ ! -s $KEY ]]; then
  echo "missing $KEY: copy the agents key there (mode 600) before using hermes" >&2
  exit 1
fi
[[ $(stat -c %a "$KEY") == 600 ]] || echo "warning: $KEY is not mode 600" >&2

# doctor exits 1 for warnings it can't fix (the npm advisories), so its status
# isn't a verdict; read the lines instead. Healthy: no ✗, routing resolves.
"$HOME/.local/bin/hermes" doctor 2>&1 | grep -E '✗|auxiliary task routing|Config version' || true
