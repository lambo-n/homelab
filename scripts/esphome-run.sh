#!/usr/bin/env bash
# Run an ESPHome command against the voice satellite with its secrets present
# only for the length of the run. See VOICE.md V3.
#
#   scripts/esphome-run.sh config
#   scripts/esphome-run.sh compile
#   scripts/esphome-run.sh upload --device 192.168.50.x   (OTA)
#   scripts/esphome-run.sh logs --device 192.168.50.x
#
# secrets.sops.yaml is decrypted into a private tmpfs directory, and ESPHome's
# build tree (.esphome/, whose generated sources and firmware embed the Wi-Fi
# password and API key) is created beside it. Both go when the script exits, so
# no plaintext secret outlives the run -- AGENTS.md rule 6. The cost is a cold
# project build each time; the toolchain cache in ~/.platformio holds no secrets
# and survives, which keeps rebuilds to a few minutes.
#
# `compile` output is copied out ONLY when ESPHOME_KEEP_FIRMWARE names a
# directory, for the one-time USB flash from the workstation. That .bin embeds
# the secrets: delete it once flashed.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
cfg=voice-satellite.yaml

[ $# -ge 1 ] || { echo "usage: $0 <esphome command> [args]" >&2; exit 2; }
cmd=$1
shift

work=$(mktemp -d /dev/shm/esphome.XXXXXX)
trap 'rm -rf "$work"' EXIT
chmod 700 "$work"

cp "$repo/esphome/$cfg" "$work/$cfg"
sops decrypt "$repo/esphome/secrets.sops.yaml" > "$work/secrets.yaml"

cd "$repo"
mise exec -- esphome "$cmd" "$work/$cfg" "$@"

if [ "$cmd" = compile ] && [ -n "${ESPHOME_KEEP_FIRMWARE:-}" ]; then
  src="$work/.esphome/build/voice-satellite/.pioenvs/voice-satellite"
  install -m 600 "$src/firmware.factory.bin" "$ESPHOME_KEEP_FIRMWARE/"
  echo "kept $ESPHOME_KEEP_FIRMWARE/firmware.factory.bin -- contains secrets"
fi
