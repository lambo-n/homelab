#!/usr/bin/env bash
# Transcribe an audio file from a machine that is NOT on the homelab LAN, by
# relaying through the dev VM's SSH access to it. The transcribe service is
# deliberately LAN-only (see homelab/README.md -> Transcribe), so this pipes
# the decoded audio straight through an SSH session rather than opening the
# service to the tailnet.
#
# Usage:
#   transcribe-remote.sh <audio-file> [output.txt]
#
# Assumes the `dev` host alias from homelab/ssh-config is loaded on this
# machine (Host dev -> 192.168.50.103 via ProxyJump tailscale-gateway).
# Override with DEV_VM=<other-alias> if you're using a different one.
#
# Needs locally: ffmpeg, ssh (with homelab/ssh-config included), and either
# jq or python3.

set -euo pipefail

usage() {
    echo "Usage: $0 <audio-file> [output.txt]" >&2
    echo "  DEV_VM=<ssh-alias> overrides the default ('dev')." >&2
    exit 1
}

dev_vm="${DEV_VM:-dev}"
node_ip="${TRANSCRIBE_HOST:-192.168.50.104}"

[[ $# -ge 1 ]] || usage
input="$1"
output="${2:-${input%.*}.txt}"

[[ -f "$input" ]] || { echo "No such file: $input" >&2; exit 1; }

for cmd in ffmpeg ssh; do
    command -v "$cmd" >/dev/null || { echo "Missing required command: $cmd" >&2; exit 1; }
done
if ! command -v jq >/dev/null && ! command -v python3 >/dev/null; then
    echo "Need jq or python3 installed to parse the response." >&2
    exit 1
fi

echo "Relaying through $dev_vm to transcribe $input..." >&2

if ! response=$(
    ffmpeg -v error -i "$input" -ar 16000 -ac 1 -f wav - \
        | ssh "$dev_vm" "curl -sf -F 'file=@-;filename=audio.wav' http://${node_ip}:8000/transcribe"
); then
    echo "Transcription failed -- check the ffmpeg/ssh/curl output above." >&2
    exit 1
fi

if command -v jq >/dev/null; then
    text=$(jq -e -r '.text' <<<"$response") || { echo "Unexpected response from the service: $response" >&2; exit 1; }
else
    text=$(python3 -c 'import json,sys
try:
    sys.stdout.write(json.load(sys.stdin)["text"])
except Exception:
    sys.exit(1)' <<<"$response") || { echo "Unexpected response from the service: $response" >&2; exit 1; }
fi

printf '%s' "$text" > "$output"
echo "Wrote $output" >&2
