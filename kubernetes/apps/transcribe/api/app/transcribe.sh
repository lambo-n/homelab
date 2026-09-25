#!/usr/bin/env bash
# Transcribe an audio file using the homelab's transcribe service.
# LAN only, no auth. Fetch this script directly instead of copying it by hand:
#   curl -O http://192.168.50.104:8000/transcribe.sh && chmod +x transcribe.sh
#
# Usage: transcribe.sh recording.mp3 [output.txt]
# Override the target node with: TRANSCRIBE_HOST=192.168.50.105 transcribe.sh ...

set -euo pipefail

host="${TRANSCRIBE_HOST:-192.168.50.104}"
port=8000

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <audio-file> [output.txt]" >&2
    exit 1
fi

input="$1"
output="${2:-${input%.*}.txt}"

if [[ ! -f "$input" ]]; then
    echo "No such file: $input" >&2
    exit 1
fi

response=$(curl -sf -F "file=@${input}" "http://${host}:${port}/transcribe")

if command -v jq >/dev/null; then
    printf '%s' "$response" | jq -r .text > "$output"
elif command -v python3 >/dev/null; then
    printf '%s' "$response" | python3 -c 'import json,sys; sys.stdout.write(json.load(sys.stdin)["text"])' > "$output"
else
    echo "Need jq or python3 installed to parse the response. Raw response:" >&2
    printf '%s\n' "$response" >&2
    exit 1
fi

echo "Wrote $output" >&2
